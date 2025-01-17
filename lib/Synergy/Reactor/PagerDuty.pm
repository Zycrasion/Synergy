use v5.34.0;
use warnings;
use utf8;
package Synergy::Reactor::PagerDuty;

use Moose;
with 'Synergy::Role::Reactor::EasyListening',
     'Synergy::Role::HasPreferences';

use experimental qw(signatures);
use namespace::clean;

use Carp ();
use Data::Dumper::Concise;
use DateTime;
use DateTime::Format::ISO8601;
use Future;
use IO::Async::Timer::Periodic;
use JSON::MaybeXS qw(decode_json encode_json);
use Lingua::EN::Inflect qw(PL_N PL_V);
use List::Util qw(first uniq);
use Synergy::Logger '$Logger';
use Synergy::Util qw(reformat_help);
use Time::Duration qw(ago duration);
use Time::Duration::Parse qw(parse_duration);

my $ISO8601 = DateTime::Format::ISO8601->new;

has api_endpoint_uri => (
  is => 'ro',
  isa => 'Str',
  default => 'https://api.pagerduty.com',
);

has api_key => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

# the id for "Platform" or whatever. If we wind up having more than one
# "service", we'll need to tweak this
has service_id => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

# used for getting oncall names
has escalation_policy_id => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has _pd_to_slack_map => (
  is => 'ro',
  isa => 'HashRef',
  traits => ['Hash'],
  lazy => 1,
  clearer => '_clear_pd_to_slack_map',
  handles => {
    username_from_pd => 'get',
  },
  default => sub ($self) {
    my %map;

    for my $sy_username (keys $self->user_preferences->%*) {
      my $pd_id = $self->get_user_preference($sy_username, 'user-id');
      $map{$pd_id} = $sy_username;
    }

    return \%map;
  },
);

has _slack_to_pd_map => (
  is => 'ro',
  isa => 'HashRef',
  traits => ['Hash'],
  lazy => 1,
  clearer => '_clear_slack_to_pd_map',
  handles => {
    pd_id_from_username => 'get',
  },
  default => sub ($self) {
    my %map = reverse $self->_pd_to_slack_map->%*;
    return \%map;
  },
);

has oncall_channel_name => (
  is => 'ro',
  isa => 'Str',
);

has oncall_channel => (
  is => 'ro',
  lazy => 1,
  default => sub ($self) {
    return unless my $channel_name = $self->oncall_channel_name;
    return $self->hub->channel_named($channel_name);
  }
);

has oncall_group_address => (
  is => 'ro',
  isa => 'Str',
);

has maint_warning_address => (
  is  => 'ro',
  isa => 'Str',
);

has oncall_change_announce_address => (
  is  => 'ro',
  isa => 'Str',
);

has maint_timer_interval => (
  is => 'ro',
  isa => 'Int',
  default => 600,
);

has last_maint_warning_time => (
  is => 'rw',
  isa => 'Int',
  default => 0,
);

has oncall_list => (
  is => 'ro',
  isa => 'ArrayRef',
  writer => '_set_oncall_list',
  lazy => 1,
  default => sub { [] },
);

around '_set_oncall_list' => sub ($orig, $self, @rest) {
  $self->$orig(@rest);
  $self->save_state;
};

sub start ($self) {
  if ($self->oncall_channel && $self->oncall_group_address) {
    my $check_oncall_timer = IO::Async::Timer::Periodic->new(
      notifier_name  => 'pagerduty-oncall',
      first_interval => 30,   # don't start immediately
      interval       => 150,
      on_tick        => sub { $self->_check_at_oncall },
    );

    $check_oncall_timer->start;
    $self->hub->loop->add($check_oncall_timer);

    # No maint warning timer unless we can warn oncall
    if ($self->oncall_group_address && $self->maint_warning_address) {
      my $maint_warning_timer = IO::Async::Timer::Periodic->new(
        notifier_name  => 'pagerduty-maint',
        first_interval => 45,
        interval => $self->maint_timer_interval,
        on_tick  => sub {  $self->_check_long_maint },
      );
      $maint_warning_timer->start;
      $self->hub->loop->add($maint_warning_timer);
    }
  }
}

sub listener_specs {
  return (
    {
      name      => 'maint-query',
      method    => 'handle_maint_query',
      targeted  => 1,
      predicate => sub ($, $e) { $e->text =~ /^maint(\s+status)?\s*$/in },
      help_entries => [
        # start /force is not documented here because it will mention itself to
        # the user when needed -- rjbs, 2020-06-15
        { title => 'maint', text => <<'EOH' =~ s/(\S)\n([^\s•])/$1 $2/rg },
Conveniences for managing PagerDuty's "maintenance mode", aka "silence all the
alerts because everything is on fire."

• *maint status*: show current maintenance state
• *maint start*: enter maintenance mode. All alerts are now silenced! Also acks
• *maint end*, *demaint*, *unmaint*, *stop*: leave maintenance mode. Alerts are noisy again!

When you leave maintenance mode, any alerts that happened during it, or even
shortly before it, will be marked resolved.  If you don't want that, say *maint
end /noresolve*
EOH
      ],
    },
    {
      name      => 'maint-start',
      method    => 'handle_maint_start',
      targeted  => 1,
      predicate => sub ($, $e) {
        $e->text =~ m{^maint\s+start\s*(/force)?\s*$}i
      },
      allow_empty_help => 1,  # provided by maint-query
    },
    {
      name      => 'maint-end',
      method    => 'handle_maint_end',
      targeted  => 1,
      predicate => sub ($self, $e) {
        return 1 if $e->text =~ /^maint\s+(end|stop)\b/i;
        return 1 if $e->text =~ /^unmaint\b/i;
        return 1 if $e->text =~ /^demaint\b/i;
      },
      allow_empty_help => 1,  # provided by maint-query
    },
    {
      name      => 'oncall',
      method    => 'handle_oncall',
      targeted  => 1,
      predicate => sub ($self, $e) { $e->text =~ /^oncall\s*(override)?/in },
      help_entries => [
        { title => 'oncall', text => '*oncall*: show a list of who is on call in PagerDuty right now' },
      ],
    },
    {
      name      => 'give-oncall',
      method    => 'handle_give_oncall',
      targeted  => 1,
      predicate => sub ($self, $e) { $e->text =~ /^give\s+oncall/i },
      help_entries => [{
        title => 'give oncall',
        text => reformat_help(<<'EOH'),
Give the oncall conch to someone for a while.

• `give oncall to WHO for DURATION`
• `oncall override WHO DURATION`

`WHO` is the person you want to take the conch, and `DURATION` is how long
they should keep it. The duration is parsed, so you can say something like
"30m" or "2h".

This command is (for now?) very limited, and intended for the case where
you're oncall and need to step away to for a while. It won't let you give
oncall to someone for more than 8 hours, and won't work if there is already
more than one person oncall. To set up extended overrides, you should use the
PagerDuty website.
EOH
      }],
    },
    {
      name      => 'ack-all',
      method    => 'handle_ack_all',
      targeted  => 1,
      predicate => sub ($self, $e) { $e->text =~ /^ack all\s*$/i },
      help_entries => [
        { title => 'ack', text => '*ack all*: acknowledge all triggered alerts in PagerDuty' },
      ],
    },
    {
      name      => 'incident-summary',
      method    => '_handle_incidents',
      targeted  => 1,
      predicate => sub ($self, $e) { $e->text =~ /^(incidents|alerts)\s*$/in },
      help_entries => [
        { title => 'incidents', text => '*incidents*: list current active incidents' },
      ],
    },
    {
      name      => 'resolve-all',
      method    => 'handle_resolve_all',
      targeted  => 1,
      predicate => sub ($self, $e) { $e->text =~ m{^resolve\s+all\s*$}i },
      help_entries => [
        { title => 'resolve', text => <<'EOH' =~ s/(\S)\n([^\s•])/$1 $2/rg },
*resolve*: manage resolving alerts in PagerDuty

You can run this in one of several ways:

• *resolve all*: resolve all triggered and acknowledged alerts in PagerDuty
• *resolve acked*: resolve the acknowledged alerts in PagerDuty
• *resolve mine*: resolve the acknowledged alerts assigned to you in PagerDuty
EOH
      ],
    },
    {
      name      => 'resolve-acked',
      method    => 'handle_resolve_acked',
      targeted  => 1,
      predicate => sub ($self, $e) { $e->text =~ m{^resolve\s+acked\s*$}i },
      allow_empty_help => 1,  # provided by resolve-all
    },
    {
      name      => 'resolve-mine',
      method    => 'handle_resolve_mine',
      targeted  => 1,
      predicate => sub ($self, $e) { $e->text =~ m{^resolve\s+mine\s*$}i },
      allow_empty_help => 1,  # provided by resolve-all
    },
    {
      name      => 'snooze',
      method    => 'handle_snooze',
      targeted  => 1,
      predicate => sub ($self, $e) { $e->text =~ m{^snooze\s}i },
      help_entries => [
        { title => 'snooze', text => <<'EOH' },
Snooze a single PagerDuty incident. Usage: snooze ALERT-NUMBER for DURATION
EOH
      ],
    },
  );
}

sub state ($self) {
  return {
    oncall_list => $self->oncall_list,
    last_maint_warning_time => $self->last_maint_warning_time,
  };
}

sub _url_for ($self, $endpoint) {
  return $self->api_endpoint_uri . $endpoint;
}

sub is_known_user ($self, $event) {
  my $user = $event->from_user;

  return 1 if $user && $self->get_user_preference($user, 'api-token');

  if (! $user) {
    $event->reply("Sorry, I don't even know who you are!");
    return 0;
  }

  my $name = $user->username;
  my $ns = $self->preference_namespace;
  $event->reply(
    "You look like my old friend $name, but you haven't set your "
    . "$ns.api-token yet, so I can't help you here, sorry."
  );

  return 0;
}

# this is way too many positional args, but...meh.
sub _pd_request_for_user ($self, $user, $method, $endpoint, $data = undef) {
  my $token = $self->get_user_preference($user, 'api-token');
  return $self->_pd_request($method => $endpoint, $data, $token);
}

sub _pd_request ($self, $method, $endpoint, $data = undef, $token = undef) {
  my %content;

  if ($data) {
    %content = (
      Content_Type => 'application/json',
      Content      => encode_json($data),
    );
  }

  return $self->hub->http_request(
    $method,
    $self->_url_for($endpoint),
    Authorization => 'Token token=' . ($token // $self->api_key),
    Accept        => 'application/vnd.pagerduty+json;version=2',
    %content,
  )->then(sub ($res) {
    unless ($res->is_success) {
      my $code = $res->code;
      $Logger->log([ "error talking to PagerDuty: %s", $res->as_string ]);
      return Future->fail('http', { http_res => $res });
    }

    my $data = decode_json($res->content);
    return Future->done($data);
  });
}

after register_with_hub => sub ($self, @) {
  my $state = $self->fetch_state // {};   # load prefs
  if (my $list = $state->{oncall_list}) {
    $self->_set_oncall_list($list);
  }

  if (my $when = $state->{last_maint_warning_time}) {
    $self->last_maint_warning_time($when);
  }
};

sub _relevant_maint_windows ($self) {
  return $self->_pd_request('GET' => '/maintenance_windows?filter=ongoing')
    ->then(sub ($data) {
      my $maint = $data->{maintenance_windows} // [];

      # We only care if maint window covers a service we care about.
      my @relevant;
      for my $window (@$maint) {
        next unless grep {; $_->{id} eq $self->service_id } $window->{services}->@*;
        push @relevant, $window;
      }

      return Future->done(@relevant);
    });
}

sub _format_maints ($self, @maints) {
  return join q{; }, map {; $self->_format_maint_window($_) } @maints;
}

sub _format_maint_window ($self, $window) {
  my $services = join q{, }, map {; $_->{summary} } $window->{services}->@*;
  my $start = $ISO8601->parse_datetime($window->{start_time});
  my $ago = ago(time - $start->epoch);
  my $who = $window->{created_by}->{summary};   # XXX map to our usernames

  return "$services ($ago, started by $who)";
}

sub handle_maint_query ($self, $event) {
  $event->mark_handled;

  my $f = $self->_relevant_maint_windows
    ->then(sub (@maints) {
      unless (@maints) {
        return $event->reply("PD not in maint right now. Everything is fine maybe!");
      }

      my $maint_text = $self->_format_maints(@maints);
      return $event->reply("🚨 PD in maint: $maint_text");
    })
    ->else(sub (@fails) {
      $Logger->log("PD handle_maint_query failed: @fails");
      return $event->reply("Something went wrong while getting maint state from PD. Sorry!");
    });

  $f->retain;
}

sub _check_long_maint ($self) {
  my $current_time = time();

  # No warning if we've warned in last 25 minutes
  return unless ($current_time - $self->last_maint_warning_time) > (60 * 25);

  $self->_relevant_maint_windows
    ->then(sub (@maint) {
      unless (@maint) {
        return Future->fail('not in maint');
      }

      $self->last_maint_warning_time($current_time);
      $self->save_state;

      my $oldest;
      for my $window (@maint) {
        my $start = $ISO8601->parse_datetime($window->{start_time});
        my $epoch = $start->epoch;
        $oldest = $epoch if ! $oldest || $epoch < $oldest;
      }

      my $maint_duration_s = $current_time - $oldest;
      return Future->fail('maint duration less than 30m')
        unless $maint_duration_s > (60 * 30);

      my $group_address = $self->oncall_group_address;
      my $maint_duration_m = int($maint_duration_s / 60);

      my $maint_text = $self->_format_maints(@maint);
      my $text =  "Hey, by the way, PagerDuty is in maintenance mode: $maint_text";

      $self->oncall_channel->send_message(
        $self->maint_warning_address,
        "\@oncall $text",
        { slack => "<!subteam^$group_address> $text" }
      );
    })
    ->else(sub ($message, $extra = {}) {
      return if $message eq 'not in maint';
      return if $message eq 'maint duration less than 30m';
      $Logger->log("PD error _check_long_maint():  $message");
    })->retain;
}

sub _relevant_oncalls ($self) {
  return $self->_pd_request(GET => '/oncalls')
    ->then(sub ($data) {
      my $policy_id = $self->escalation_policy_id;
      my @oncalls = grep {; $_->{escalation_policy}{id} eq $policy_id }
                    grep {; $_->{escalation_level} == 1}
                    $data->{oncalls}->@*;

      return Future->done(\@oncalls);
    });
}

sub _current_oncall_ids ($self) {
  $self->_relevant_oncalls->then(sub ($oncalls) {
    my @ids = map  {; $_->{user}{id} } @$oncalls;
    return Future->done(@ids);
  });
}

# This returns a Future that, when done, gives a boolean as to whether or not
# $who is oncall right now.
sub _user_is_oncall ($self, $who) {
  return $self->_current_oncall_ids
    ->then(sub (@ids) {
      my $want_id = $self->get_user_preference($who->username, 'user-id');
      return Future->done(!! first { $_ eq $want_id } @ids)
    });
}

sub handle_oncall ($self, $event) {
  $event->mark_handled;

  if ($event->text =~ /^oncall\s+override/i) {
    return $self->handle_give_oncall($event);
  }

  $self->_current_oncall_ids
    ->then(sub (@ids) {
        my @users = uniq map {; $self->username_from_pd($_) // $_ } @ids;
        return $event->reply('current oncall: ' . join(', ', sort @users));
    })
    ->else(sub { $event->reply("I couldn't look up who's on call. Sorry!") })
    ->retain;
}

# For now, this will work in *extremely* limited situations, so we do a bunch
# of error checking up front here.
sub handle_give_oncall ($self, $event) {
  $event->mark_handled;

  my ($who, $dur);
  if ($event->text =~ /^oncall\s+override/in) {
    # oncall override syntax
    ($who, $dur) = $event->text =~ /^oncall\s+override\s+(\S+)\s+(.*)/i;
  } else {
    # give oncall syntax
    ($who, $dur) = $event->text =~ /^give\s+oncall\s+to\s+(\S+)\s+for\s+(.*)\s*$/i;
  }

  warn "who: $who, dur: $dur";

  unless ($who && $dur) {
    return $event->error_reply(
      "Hmm, I didn't catch that, sorry: it's *give oncall to WHO for DURATION*"
    );
  }

  my $target = $self->resolve_name($who, $event->from_user);
  unless ($target) {
    return $event->error_reply("Sorry, I can't figure out who '$who' is.");
  }

  my $target_id = $self->get_user_preference($target, 'user-id');
  unless ($target_id) {
    my $they = $target->username;
    return $event->error_reply("Hmm, $they doesn't seem to be a PagerDuty user.");
  }

  my $seconds = eval { parse_duration($dur) };
  unless ($seconds) {
    return $event->error_reply("Hmm, I can't figure out how long you mean by '$dur'.");
  }

  if ($seconds > 60 * 60 * 8) {
    return $event->error_reply("Sorry, I can only give oncall for 8 hours max.");
  }

  if ($seconds < 60 ) {
    return $event->error_reply("That's less than a minute; did you forget a unit?");
  }

  $self->_relevant_oncalls->then(sub ($oncalls) {
    # More early bail-outs
    if (@$oncalls > 1) {
      $event->error_reply(
        "Sorry; there's more than one person oncall right now, so I can't help you!"
      );

      return Future->fail('bail-out');
    }

    my $schedule = $oncalls->[0]{schedule};
    unless ($schedule) {
      $event->error_reply(
        "Sorry; I couldn't figure out the oncall schedule from PagerDuty."
      );

      return Future->fail('bail-out');
    }

    my $sched_id = $schedule->{id};
    my $start    = DateTime->now->add(seconds => 15);
    my $end      = $start->clone->add(seconds => $seconds);

    return $self->_pd_request_for_user(
      $event->from_user,
      POST => "/schedules/$sched_id/overrides",
      {
        overrides => [{
          start => $ISO8601->format_datetime($start),
          end   => $ISO8601->format_datetime($end),
          user  => {
            type => 'user_reference',
            id   => $target_id,
          },
        }],
      }
    );
  })->then(sub ($overrides) {
    unless (@$overrides == 1 && $overrides->[0]{status} == 201) {
      $Logger->log([ "got weird data back from override call: %s", $overrides ]);
      return $event->reply(
        "Sorry, something went wrong talking to PagerDuty. \N{DISAPPOINTED FACE}"
      );
    }

    my $duration = duration($seconds);
    $event->reply(sprintf("Okay! %s is now oncall for %s.",
      $target->username,
      duration($seconds),
    ));
  })->else(sub ($type, @rest) {
    return if $type eq 'bail-out';

    if ($type eq 'http') {
      my $res = shift @rest;
      my $data = eval { decode_json($res->decoded_content) };
      $Logger->log([
        "got http error, status %s, when setting overrides: %s",
        $res->code,
        $data // '<no json>',
      ]);
    } else {
      $Logger->log([
        "unknown error setting overrides: type=%s, err=%s",
        $type,
        \@rest,
      ]);
    }

    return $event->reply(
      "Sorry, something went wrong talking to PagerDuty. \N{DISAPPOINTED FACE}"
    );
  })->retain;
}

sub handle_maint_start ($self, $event) {
  $event->mark_handled;
  return unless $self->is_known_user($event);

  my $force = $event->text =~ m{/force\s*$};
  my $f;

  if ($force) {
    # don't bother checking
    $f = Future->done;
  } else {
    $f = $self->_user_is_oncall($event->from_user)->then(sub ($is_oncall) {
      return Future->done if $is_oncall;

      $event->error_reply(join(q{ },
        "You don't seem to be on call right now.",
        "Usually, the person oncall is getting the alerts, so they should be",
        "the one to decide whether or not to shut them up.",
        "If you really want to do this, try again with /force."
      ));
      return Future->fail('not-oncall');
    });
  }

  $f->then(sub {
    $self->_relevant_maint_windows
  })
  ->then(sub (@maints) {
    return Future->done unless @maints;

    my $desc = $self->_format_maints(@maints);
    $event->reply("PD already in maint: $desc");

    return Future->fail('already-maint');
  })
  ->then(sub {
    # XXX add reason here?
    return $self->_pd_request_for_user(
      $event->from_user,
      POST => '/maintenance_windows',
      {
        maintenance_window => {
          type => 'maintenance_window',
          start_time => $ISO8601->format_datetime(DateTime->now),
          end_time   =>  $ISO8601->format_datetime(DateTime->now->add(hours => 1)),
          services => [{
            id => $self->service_id,
            type => 'service_reference',
          }],
        },
      }
    );
  })
  ->then(sub ($data) {
    $self->_ack_all($event);
  })
  ->then(sub ($nacked) {
    my $ack_text = ' ';
    $ack_text = " 🚑 $nacked alert".($nacked > 1 ? 's' : '')." acked!"
      if $nacked;

    return $event->reply("🚨 PD now in maint for an hour!$ack_text Good luck!");
  })
  ->else(sub ($category, $extra = {}) {
    return if $category eq 'not-oncall';
    return if $category eq 'already-maint';

    $Logger->log("PD handle_maint_start failed: $category");
    return $event->reply("Something went wrong while fiddling with PD maint state. Sorry!");
  })
  ->retain;

  return;
}

sub handle_maint_end ($self, $event) {
  $event->mark_handled;
  return unless $self->is_known_user($event);

  my (@args) = split /\s+/, $event->text;

  $self->_relevant_maint_windows
    ->then(sub (@maints) {
      unless (@maints) {
        $event->reply("PD not in maint right now. Everything is fine maybe!");
        return Future->fail('no-maint');
      }

      # add 5s to allow for clock skew, otherwise PD gives you "end cannot be
      # before now"
      my $now = $ISO8601->format_datetime(DateTime->now->add(seconds => 5));
      my @futures;
      for my $window (@maints) {
        my $id = $window->{id};
        push @futures, $self->_pd_request_for_user(
          $event->from_user,
          PUT => "/maintenance_windows/$id",
          {
            maintenance_window => {
              type       => $window->{type},
              end_time   => $now,
            },
          }
        );
      }

      return Future->wait_all(@futures);
    })
    ->then(sub (@futures) {
      my @failed = grep {; $_->is_failed } @futures;

      if (@failed) {
        $Logger->log([ "PD demaint failed: %s", [ map {; $_->failure } @failed ] ]);
        $event->reply(
          "Something went wrong fiddling PD maint state; "
          . "you'll probably want to sort it out on the web. Sorry about that!"
        );
      } else {
        $event->reply("🚨 PD maint cleared. Good job everyone!");
      }
    })
    ->retain;
}

sub handle_ack_all ($self, $event) {
  $event->mark_handled;
  return unless $self->is_known_user($event);

  $self->_ack_all($event)
    ->then(sub ($n_acked) {
      my $noun = $n_acked == 1 ? 'incident' : 'incidents';
      $event->reply("Successfully acked $n_acked $noun. Good luck!");
    })
    ->else(sub {
      $event->reply("Something went wrong acking incidents. Sorry!");
    })
    ->retain;
}

# returns a future that yields a list of incidents
sub _get_incidents ($self, @statuses) {
  Carp::confess("no statuses found to get!") unless @statuses;

  # url params
  my $offset   = 0;
  my $limit    = 100;
  my $sid      = $self->service_id;
  my $statuses = join q{&}, map {; "statuses[]=$_" } @statuses;

  # iteration variables
  my $is_done = 0;
  my $i = 0;
  my @results;

  while (! $is_done) {
    my $url = "/incidents?service_ids[]=$sid&$statuses&limit=$limit&offset=$offset";

    $self->_pd_request(GET => $url)
      ->then(sub ($data) {
        push @results, $data->{incidents}->@*;

        $is_done = ! $data->{more};
        $offset += $limit;

        if (++$i > 20) {
          $Logger->log("did more than 20 requests getting incidents from PD; aborting to avoid infinite loop!");
          $is_done = 1;
        }
      })
      ->await;
  }

  return Future->done(@results);
}

sub _update_status_for_incidents ($self, $who, $status, $incident_ids) {
  # This just prevents some special-casing elsewhere
  return Future->done unless @$incident_ids;

  my @todo = @$incident_ids;
  my @incidents;

  # *Surely* we won't have more than 500 at a time, right? Right?! Anyway,
  # 500 is the PagerDuty max for this endpoint.
  while (my @ids = splice @todo, 0, 500) {
    my @put = map {;
      +{
        id => $_,
        type => 'incident_reference',
        status => $status,
      },
    } @ids;

    $self->_pd_request_for_user(
      $who,
      PUT => '/incidents',
      { incidents => \@put }
    )->then(sub ($data) {
      push @incidents, $data->{incidents}->@*;
    })
    ->await;
  }

  return Future->done(@incidents);
}

sub _ack_all ($self, $event) {
  my $sid = $self->service_id;

  return $self->_get_incidents(qw(triggered))
    ->then(sub (@incidents) {
      my @unacked = map  {; $_->{id} } @incidents;
      $Logger->log([ "PD: acking incidents: %s", \@unacked ]);

      return $self->_update_status_for_incidents(
        $event->from_user,
        'acknowledged',
        \@unacked,
      );
    })->then(sub (@incidents) {
      return Future->done(scalar @incidents);
    });
}

sub handle_resolve_mine ($self, $event) {
  $event->mark_handled;
  return unless $self->is_known_user($event);

  $self->_resolve_incidents($event, {
    whose => 'own',
  })->retain;
}

sub handle_resolve_all ($self, $event) {
  $event->mark_handled;
  return unless $self->is_known_user($event);

  $self->_resolve_incidents($event, {
    whose => 'all',
  })->retain;
}

sub handle_resolve_acked ($self, $event) {
  $event->mark_handled;
  return unless $self->is_known_user($event);

  $self->_resolve_incidents($event, {
    whose => 'all',
    only_acked => 1,
  })->retain;
}

sub _resolve_incidents($self, $event, $arg) {
  my $sid = $self->service_id;

  my $whose = $arg->{whose};
  Carp::confess("_resolve_incidents called with bogus args")
    unless $whose && ($whose eq 'all' || $whose eq 'own');

  my $only_acked = $arg->{only_acked} // ($whose eq 'own' ? 1 : 0);

  # XXX pagination?
  return $self->_get_incidents(qw(triggered acknowledged))
    ->then(sub (@incidents) {
      my $pd_id = $self->pd_id_from_username($event->from_user->username);
      my @unresolved;

      for my $incident (@incidents) {
        # skip unacked incidents unless we've asked for all
        next if $only_acked && $incident->{status} eq 'triggered';

        # 'resolve own' is 'resolve all the alerts I have acked'
        if ($whose eq 'own') {
          next unless grep {; $_->{acknowledger}{id} eq $pd_id }
                      $incident->{acknowledgements}->@*;
        }

        push @unresolved, $incident->{id};
      }

      unless (@unresolved) {
        $event->reply("Looks like there's no incidents to resolve. Lucky!");
        return Future->done;
      }

      $Logger->log([ "PD: acking incidents: %s", \@unresolved ]);

      return $self->_update_status_for_incidents(
        $event->from_user,
        'resolved',
        \@unresolved,
      );
    })->then(sub (@incidents) {
      return Future->done if ! @incidents;

      my $n = @incidents;
      my $noun = $n == 1 ? 'incident' : 'incidents';

      my $exclamation = $whose eq 'all' ? "The board is clear!" : "Phew!";

      $event->reply("Successfully resolved $n $noun. $exclamation");
      return Future->done;
    })->else(sub (@failure) {
      $Logger->log(["PD error resolving incidents: %s", \@failure ]);
      $event->reply("Something went wrong resolving incidents. Sorry!");
    });
}

sub _check_at_oncall ($self) {
  my $channel = $self->oncall_channel;
  return unless $channel && $channel->isa('Synergy::Channel::Slack');

  $Logger->log("checking PagerDuty for oncall updates");

  return $self->_current_oncall_ids
    ->then(sub (@ids) {
      my @new = sort @ids;
      my @have = sort $self->oncall_list->@*;

      if (join(',', @have) eq join(',', @new)) {
        $Logger->log("no changes in oncall list detected");
        return Future->done;
      }

      $Logger->log([ "will update oncall list; is now %s", join(', ', @new) ]);

      my @userids = map  {; $_->identity_for($channel->name) }
                    map  {; $self->hub->user_directory->user_named($_) }
                    grep {; defined }
                    map  {; $self->username_from_pd($_) }
                    @new;

      unless (@userids) {
        $Logger->log("could not convert PD oncall list into slack userids; ignoring");
        return Future->done;
      }

      my $f = $channel->slack->api_call(
        'usergroups.users.update',
        {
          usergroup => $self->oncall_group_address,
          users => join(q{,}, @userids),
        },
        privileged => 1,
      );

      $f->on_done(sub ($http_res) {
        my $data = decode_json($http_res->decoded_content);
        unless ($data->{ok}) {
          $Logger->log(["error updating oncall slack group: %s", $data]);
          return;
        }

        # Don't set our local cache until we're sure we've actually updated
        # the slack group; this way, if something goes wrong setting the group
        # the first time, we'll actually try again the next time around,
        # rather than just saying "oh, nothing changed, great!"
        $self->_set_oncall_list(\@new);
        $self->_announce_oncall_change(\@have, \@new);
      });

      return $f;
    })->retain;
}

sub _announce_oncall_change ($self, $before, $after) {
  return unless $self->oncall_change_announce_address;

  my %before = map {; ($self->username_from_pd($_) // $_) => 1 } $before->@*;
  my %after  = map {; ($self->username_from_pd($_) // $_) => 1 } $after->@*;

  my @leaving = grep { ! $after{$_} } keys %before;
  my @joining = grep { ! $before{$_} } keys %after;

  my @lines;

  if (@leaving) {
    my $verb = @leaving > 1 ? 'have' : 'has';
    my $removed = join ', ', sort @leaving;
    push @lines, "$removed $verb been removed from the oncall group";
  }

  if (@joining) {
    my $verb = @joining > 1 ? 'have' : 'has';
    my $added = join ', ', sort @joining;
    push @lines, "$added $verb been added to the oncall group";
  }

  my $oncall = join ', ', sort keys %after;
  push @lines, "Now oncall: $oncall";

  my $text = join qq{\n}, @lines;

  my $blocks = [
    {
      type => "section",
      text => {
        type => "mrkdwn",
        text => "$text",
      }
    },
  ];

  $self->_active_incidents_summary->then(sub ($summary = {}) {
    if (my $summary_text = delete $summary->{text}) {
      $text .= "\n$summary_text";
    }

    if (my $slack = delete $summary->{slack}) {
      push @$blocks, { type => 'divider' };
      push @$blocks, $slack->{blocks}->@*;
    }

    $self->oncall_channel->send_message(
      $self->oncall_change_announce_address,
      $text,
      {
        slack => {
          blocks => $blocks,
          text => $text,
        }
      }
    );
  })->retain;
}

sub _handle_incidents ($self, $event) {
  $event->mark_handled;
  $self->_active_incidents_summary->then(sub ($summary = undef) {
    my $text = delete $summary->{text} // "The board is clear!";
    $event->reply($text, $summary);
  })->retain;
}

sub _active_incidents_summary ($self) {
  return $self->_get_incidents(qw(triggered acknowledged))
    ->then(sub (@incidents) {
      return Future->done() unless @incidents;

      my $count = @incidents;
      my $title = sprintf("🚨 There %s %d %s on the board: 🚨",
        PL_V('is', $count),
        $count,
        PL_N('incident', $count)
      );

      my (@text, @slack);

      for my $incident (@incidents) {
        my $created = $ISO8601->parse_datetime($incident->{created_at});
        my $ago = ago(time - $created->epoch);

        push @text, "  - $incident->{description} (fired $ago)";
        push @slack, sprintf("• <%s|#%s> (fired %s): %s",
          $incident->{html_url},
          $incident->{incident_number},
          $ago,
          $incident->{description},
        );
      }

      my $text = join qq{\n}, $title, @text;

      my $blocks = [
        {
          type => "section",
          text => {
            type => "mrkdwn",
            text => "*$title*",
          }
        },
        {
          type => "section",
          text => {
            type => "mrkdwn",
            text => join qq{\n}, @slack,
          }
        },
      ];

      my $slack = {
        blocks => $blocks,
        text => $text,
      };

      return Future->done({ text => $text, slack => $slack });
  });
}

sub handle_snooze ($self, $event) {
  $event->mark_handled;

  my ($num, $dur) = $event->text =~ /^snooze\s+#?(\d+)\s+for\s+(.*)/i;

  unless ($num && $dur) {
    return $event->error_reply(
      "Sorry, I don't understand. Say 'snooze INCIDENT-NUM for DURATION'."
    );
  }

  my $seconds = eval { parse_duration($dur) };

  unless ($seconds) {
    return $event->error_reply("Sorry, I couldn't parse '$dur' into a duration!");
  }

  return $self->_get_incidents(qw(triggered acknowledged))
    ->then(sub (@incidents) {
      my ($relevant) = grep {; $_->{incident_number} == $num } @incidents;
      unless ($relevant) {
        $event->error_reply("I couldn't find an active incident for #$num");
        return Future->fail('no-incident');
      }

      my $id = $relevant->{id};

      return $self->_pd_request_for_user(
        $event->from_user,
        POST => "/incidents/$id/snooze",
        { duration => $seconds }
      );
    })->then(sub ($res) {
      if (my $incident = $res->{incident}) {
        my $title = $incident->{title};
        my $duration = duration($seconds);
        return $event->reply(
          "#$num ($title) snoozed for $duration; enjoy the peace and quiet!"
        );
      }

      my $msg = $res->{message};
      return $event->reply(
        "Something went wrong talking to PagerDuty; they said: $msg"
      );
    })->else(sub ($type, @extra) {
      return Future->done if $type eq 'no-incident';

      $Logger->log([ "PD snooze failed: %s, %s", $type, \@extra ]);
      return $event->reply("Sorry, something went wrong talking to PagerDuty");
    })->retain;
}

sub _get_pd_account ($self, $token) {
  return $self->hub->http_get(
    $self->_url_for('/users/me'),
    Authorization => "Token token=$token",
    Accept        => 'application/vnd.pagerduty+json;version=2',
  )->then(sub ($res) {
    my $rc = $res->code;

    return Future->fail('That token seems invalid.')
      if $rc == 401;

    return Future->fail("Encountered error talking to LP: got HTTP $rc")
      unless $res->is_success;

    return Future->done(decode_json($res->decoded_content));
  })->retain;
}

__PACKAGE__->add_preference(
  name      => 'user-id',
  after_set => sub ($self, $username, $val) {
    $self->_clear_pd_to_slack_map,
    $self->_clear_slack_to_pd_map,
  },
  validator => sub ($self, $value, @) {
    return (undef, 'user id cannot contain spaces') if $value =~ /\s/;
    return $value;
  },
);

__PACKAGE__->add_preference(
  name      => 'api-token',
  describer => sub ($value) { return defined $value ? "<redacted>" : '<undef>' },
  default   => undef,
  validator => sub ($self, $token, $event) {
    $token =~ s/^\s*|\s*$//g;

    my ($actual_val, $ret_err);

    $self->_get_pd_account($token)
      ->then(sub ($account) {
        $actual_val = $token;

        my $id = $account->{user}{id};
        my $email = $account->{user}{email};
        $event->reply(
          "Great! I found the PagerDuty user for $email, and will also set your PD user id to $id."
        );
        $self->set_user_preference($event->from_user, 'user-id', $id);

        return Future->done;
      })
      ->else(sub ($err) {
        $ret_err = $err;
        return Future->fail('bad auth');
      })
      ->block_until_ready;

    return ($actual_val, $ret_err);
  },
);

__PACKAGE__->meta->make_immutable;

1;
