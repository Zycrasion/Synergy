use v5.24.0;
use warnings;
package Synergy::Reactor::InABox;

use Moose;
with 'Synergy::Role::Reactor';

use experimental qw(signatures);
use namespace::clean;

use Synergy::Logger '$Logger';
use JSON::MaybeXS;
use Future::Utils qw(repeat);
use Text::Template;

sub listener_specs {
  return {
    name      => 'box',
    method    => 'handle_box',
    exclusive => 1,
    predicate => sub ($self, $event) {
      $event->was_targeted && $event->text =~ /\Abox\b/i;
    },
  };
}

has digitalocean_api_base => (
  is => 'ro',
  isa => 'Str',
  default => 'https://api.digitalocean.com/v2',
);

has digitalocean_api_token => (
  is       => 'ro',
  isa      => 'Str',
  required => 1,
);

sub _do_endpoint ($self, $endpoint) {
  return $self->digitalocean_api_base . $endpoint;
}
sub _do_headers ($self) {
  return (
    'Authorization' => 'Bearer ' . $self->digitalocean_api_token,
  );
}

has vpn_config_file => (
  is       => 'ro',
  isa      => 'Str',
  required => 1,
);

has box_domain => (
  is       => 'ro',
  isa      => 'Str',
  required => 1,
);


my %command_handler = (
  status  => \&_handle_status,
  create  => \&_handle_create,
  destroy => \&_handle_destroy,
  vpn     => \&_handle_vpn,
);

sub handle_box ($self, $event) {
  $event->mark_handled;

  unless ($event->from_user) {
    $event->error_reply("Sorry, I don't know you.");
    return;
  }

  my ($box, $cmd, @args) = split /\s+/, $event->text;

  my $handler = $command_handler{$cmd};
  unless ($handler) {
    return $event->error_reply("usage: box <subcommand>");
  }

  $handler->($self, $event, @args);
}

sub _handle_status ($self, $event, @args) {
  my $droplet = $self->_get_droplet_for($event->from_user->username)->get;
  unless ($droplet) {
    $event->error_reply("You don't have a box.");
    return;
  }
  $event->reply("Your box: " . $self->_format_droplet($droplet));
}

sub _handle_create ($self, $event, @args) {
  my $droplet = $self->_get_droplet_for($event->from_user->username)->get;
  if ($droplet) {
    $event->error_reply("You already have a box: " . $self->_format_droplet($droplet));
    return;
  }

  $event->reply("Creating box, this will take a minute or two.");

  my ($snapshot_id, $ssh_key_id) = Future->wait_all(
    $self->_get_snapshot,
    $self->_get_ssh_key,
  )->then(
    sub (@futures) {
      Future->done(map { $_->get->{id} } @futures)
    }
  )->get;

  my %droplet_create_args = (
    name     => $event->from_user->username.'.fminabox',
    region   => $self->_region_for_user($event->from_user),
    size     => 's-4vcpu-8gb',
    image    => $snapshot_id,
    ssh_keys => [$ssh_key_id],
    tags     => ['fminabox'],
  );

  ($droplet, my $action_id) = $self->hub->http_post(
    $self->_do_endpoint('/droplets'),
    $self->_do_headers,
    async        => 1,
    Content_Type => 'application/json',
    Content      => encode_json(\%droplet_create_args),
  )->then(
    sub ($res) {
      unless ($res->is_success) {
        $Logger->log(["error creating droplet: %s", $res->as_string]);
        return Future->done;
      }
      my $data = decode_json($res->content);
      return Future->done($data->{droplet}, $data->{links}{actions}[0]{id});
    }
  )->get;

  my $status_f = repeat {
    $self->hub->http_get(
      $self->_do_endpoint("/actions/$action_id"),
      $self->_do_headers,
      async => 1,
    )->then(
      sub ($res) {
        unless ($res->is_success) {
          $Logger->log(["error getting action: %s", $res->as_string]);
          return Future->done;
        }
        my $data = decode_json($res->content);
        my $status = $data->{action}{status};
        return $status eq 'in-progress' ?
          $self->hub->loop->delay_future(after => 5)->then_done($status) :
          Future->done($status);
      }
    )
  } until => sub ($f) {
    $f->get ne 'in-progress';
  };
  my $status = $status_f->get;

  if ($status ne 'completed') {
    $event->error_reply("Something went wrong while creating the box, check the DigitalOcean console and maybe try again.");
    return;
  }

  $droplet = $self->_get_droplet_for($event->from_user->username)->get;
  $event->reply("Box created: ".$self->_format_droplet($droplet));

  $self->_update_dns_for_user($event->from_user, $droplet->{networks}{v4}[0]{ip_address});
}

sub _handle_destroy ($self, $event, @args) {
  my $droplet = $self->_get_droplet_for($event->from_user->username)->get;
  unless ($droplet) {
    $event->error_reply("You don't have a box.");
    return;
  }
  if ($droplet->{status} eq 'active' && !grep { m{^/force$} } @args) {
    $event->error_reply("Your box is powered on. Shut it down first, or use /force to destroy it anyway.");
    return;
  }

  $self->hub->http_delete(
    $self->_do_endpoint("/droplets/$droplet->{id}"),
    $self->_do_headers,
    async => 1,
  )->then(
    sub ($res) {
      unless ($res->is_success) {
        $Logger->log(["error deleting droplet %s", $res->as_string]);
        return Future->done;
      }
      return Future->done;
    }
  )->get;

  $event->reply("Box destroyed.");
}

sub _handle_vpn ($self, $event, @args) {
  my $droplet = $self->_get_droplet_for($event->from_user->username)->get;
  unless ($droplet) {
    $event->error_reply("You don't have a box.");
    return;
  }

  my $template = Text::Template->new(
    TYPE       => 'FILE',
    SOURCE     => $self->vpn_config_file,
    DELIMITERS => [ '{{', '}}' ],
  );

  my $config = $template->fill_in(HASH => {
    droplet_ip => $droplet->{networks}{v4}[0]{ip_address},
  });

  $event->from_channel->send_file_to_user($event->from_user, 'fminabox.conf', $config);

  $event->reply("I sent you a VPN config in a direct message. Download it and import it into your OpenVPN client.");
}

sub _get_droplet_for ($self, $who) {
  $self->hub->http_get(
    $self->_do_endpoint('/droplets?per_page=200'),
    $self->_do_headers,
    async => 1,
  )->then(
    sub ($res) {
      unless ($res->is_success) {
        $Logger->log(["error getting droplet list: %s", $res->as_string]);
        return Future->done;
      }
      my $data = decode_json($res->content);
      #my ($droplet) = $data->{droplets}->@*;
      my ($droplet) = grep { $_->{name} eq "$who.fminabox" } $data->{droplets}->@*;
      Future->done($droplet);
    }
  );
}

sub _format_droplet ($self, $droplet) {
  return sprintf
    "name: %s  image: %s  ip: %s  region: %s  status: %s",
    $droplet->{name},
    $droplet->{image}{name},
    $droplet->{networks}{v4}[0]{ip_address},
    "$droplet->{region}{name} ($droplet->{region}{slug})",
    $droplet->{status};
}

sub _get_snapshot ($self) {
  $self->hub->http_get(
    $self->_do_endpoint('/snapshots?per_page=200'),
    $self->_do_headers,
    async => 1,
  )->then(
    sub ($res) {
      unless ($res->is_success) {
        $Logger->log(["error getting snapshot list: %s", $res->as_string]);
        return Future->done;
      }
      my $data = decode_json($res->content);
      my ($snapshot) =
        sort { $b->{name} cmp $a->{name} }
        grep { $_->{name} =~ m/^fminabox-/ }
          $data->{snapshots}->@*;
      Future->done($snapshot);
    }
  );
}

sub _get_ssh_key ($self) {
  $self->hub->http_get(
    $self->_do_endpoint('/account/keys?per_page=200'),
    $self->_do_headers,
    async => 1,
  )->then(
    sub ($res) {
      unless ($res->is_success) {
        $Logger->log(["error getting ssh key list: %s", $res->as_string]);
        return Future->done;
      }
      my $data = decode_json($res->content);
      my ($ssh_key) =
        grep { $_->{name} eq 'fminabox' }
          $data->{ssh_keys}->@*;
      Future->done($ssh_key);
    }
  );
}

sub _region_for_user ($self, $user) {
  # this is incredibly stupid, but will do the right thing for the home
  # location of FM plumbing staff
  my $tz = $user->time_zone;
  my ($area) = split '/', $tz;
  return
    $area eq 'Australia' ? 'sfo2' :
    $area eq 'Europe'    ? 'ams3' :
                           'nyc3';
}

sub _update_dns_for_user ($self, $user, $ip) {
  my $username = $user->username;

  my $record = $self->hub->http_get(
    $self->_do_endpoint('/domains/' . $self->box_domain . '/records?per_page=200'),
    $self->_do_headers,
    async => 1,
  )->then(
    sub ($res) {
      unless ($res->is_success) {
        $Logger->log(["error getting DNS record list: %s", $res->as_string]);
        return Future->done;
      }
      my $data = decode_json($res->content);
      my ($record) =
        grep { $_->{name} eq "$username.box" }
          $data->{domain_records}->@*;
      Future->done($record);
    }
  )->get;

  my $update_f;
  if ($record) {
    $update_f = $self->hub->http_put(
      $self->_do_endpoint('/domains/' . $self->box_domain . "/records/$record->{id}"),
      $self->_do_headers,
      async        => 1,
      Content_Type => 'application/json',
      Content      => encode_json({ data => $ip }),
    );
  }
  else {
    my $record = {
      type => 'A',
      name => "$username.box",
      data => $ip,
      ttl  => 30,
    };
    $update_f = $self->hub->http_post(
      $self->_do_endpoint('/domains/' . $self->box_domain . '/records'),
      $self->_do_headers,
      async        => 1,
      Content_Type => 'application/json',
      Content      => encode_json($record),
    );
  }

  $update_f->then(
    sub ($res) {
      unless ($res->is_success) {
        $Logger->log(["error creating/update DNS record: %s", $res->as_string]);
      }
      return Future->done;
    }
  )->get;
}

1;
