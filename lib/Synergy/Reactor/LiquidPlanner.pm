use v5.24.0;
package Synergy::Reactor::LiquidPlanner;

use Moose;
with 'Synergy::Role::Reactor';

use experimental qw(signatures lexical_subs);
use namespace::clean;
use List::Util qw(first);
use Net::Async::HTTP;
use JSON 2 ();
use Time::Duration;
use Synergy::Logger '$Logger';
use utf8;

my $JSON = JSON->new;

my $ERR_NO_LP = "You don't seem to be a LiquidPlanner-enabled user.";
my $WKSP_ID = 14822;
my $LP_BASE = "https://app.liquidplanner.com/api/workspaces/$WKSP_ID";
my $LINK_BASE = "https://app.liquidplanner.com/space/$WKSP_ID/projects/show/";
my $CONFIG;  # XXX use real config

my %KNOWN = (
  timer     => \&_handle_timer,
  task      => \&_handle_task,
  tasks     => \&_handle_tasks,
  inbox     => \&_handle_inbox,
  urgent    => \&_handle_urgent,
  recurring => \&_handle_recurring,
  '++'      => \&_handle_plus_plus,
  good      => \&_handle_good,
  gruß      => \&_handle_good,
  expand    => \&_handle_expand,
);

has user_timers => (
  is               => 'ro',
  isa              => 'HashRef',
  traits           => [ 'Hash' ],
  lazy             => 1,
  handles          => {
    _timer_for_user     => 'get',
    _add_timer_for_user => 'set',
  },

  default => sub { {} },
);

sub timer_for_user ($self, $user) {
  return unless $user->has_lp_token;

  my $timer = $self->_timer_for_user($user->username);
  return $timer if $timer;

  $timer = Synergy::Timer->new({
    time_zone      => $user->time_zone,
    business_hours => $user->business_hours,
  });

  $self->_add_timer_for_user($user, $timer);

  return $timer;
}

has primary_nag_channel_name => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has aggressive_nag_channel_name => (
  is => 'ro',
  isa => 'Str',
  default => 'twilio',
);

sub listener_specs {
  return {
    name      => "liquid planner",
    method    => "dispatch_event",
    predicate => sub ($self, $event) {
      return unless $event->type eq 'message';
      return unless $event->was_targeted;

      my ($what) = $event->text =~ /^([^\s]+)\s?/;
      $what &&= lc $what;

      return 1 if $KNOWN{$what};
      return 1 if $what =~ /^g'day/;    # stupid, but effective
      return 1 if $what =~ /^goo+d/;    # Adrian Cronauer
      return;
    }
  };
}

has projects => (
  isa => 'HashRef',
  traits => [ 'Hash' ],
  handles => {
    project_ids   => 'values',
    projects      => 'keys',
    project_named => 'get',
    project_pairs => 'kv',
  },
  lazy => 1,
  default => sub ($self) {
    $self->get_project_nicknames;
  },
  writer    => '_set_projects',
);

sub start ($self) {
  $self->projects;

  my $timer = IO::Async::Timer::Periodic->new(
    interval => 300,
    on_tick  => sub ($timer, @arg) { $self->nag($timer); },
  );

  $self->hub->loop->add($timer);

  $timer->start;
}

sub nag ($self, $timer, @) {
  $Logger->log("considering nagging");

  USER: for my $user ($self->hub->user_directory->users) {
    next USER unless my $sy_timer = $user->timer;

    next USER unless $user->should_nag;

    my $username = $user->username;

    my $last_nag = $sy_timer->last_relevant_nag;
    my $lp_timer = $self->lp_timer_for_user($user);

    if ($lp_timer && $lp_timer == -1) {
      warn "$username: error retrieving timer\n";
      next USER;
    }

    # Record the last time we saw a timer
    if ($lp_timer) {
      $sy_timer->last_saw_timer(time);
    }

    { # Timer running too long!
      if ($lp_timer && $lp_timer->{running_time} > 3) {
        if ($last_nag && time - $last_nag->{time} < 900) {
          $Logger->log("$username: Won't nag, nagged within the last 15min.");
          next USER;
        }

        my $msg = "Your timer has been running for "
                . concise(duration($lp_timer->{running_time} * 3600))
                . ".  Maybe you should commit your work.";

        my $friendly = $self->hub->channel_named($self->primary_nag_channel_name);
        $friendly->send_message_to_user($user, $msg);

        if ($user) {
          my $aggressive = $self->hub->channel_named($self->aggressive_nag_channel_name);
          $aggressive->send_message_to_user($user, $msg);
        }

        $sy_timer->last_nag({ time => time, level => 0 });
        next USER;
      }
    }

    if ($sy_timer->is_showtime) {
      if ($lp_timer) {
        $Logger->log("$username: We're good: there's a timer.");

        $sy_timer->clear_last_nag;
        next USER;
      }

      my $level = 0;
      if ($last_nag) {
        if (time - $last_nag->{time} < 900) {
          $Logger->log("$username: Won't nag, nagged within the last 15min.");
          next USER;
        }
        $level = $last_nag->{level} + 1;
      }

      # Have we seen a timer recently? Give them a grace period
      if (
           $sy_timer->last_saw_timer
        && $sy_timer->last_saw_timer > time - 900
      ) {
        warn("$username: Not nagging, they only recently disabled a timer");
        next USER;
      }

      my $still = $level == 0 ? '' : ' still';
      my $msg   = "Your LiquidPlanner timer$still isn't running";
      my $friendly = $self->hub->channel_named($self->primary_nag_channel_name);
      $friendly->send_message_to_user($user, $msg);
      if ($level >= 2) {
        my $aggressive = $self->hub->channel_named($self->aggressive_nag_channel_name);
        $aggressive->send_message_to_user($user, $msg);
      }
      $sy_timer->last_nag({ time => time, level => $level });
    }
  }
}

sub get_project_nicknames {
  my ($self) = @_;

  my $query = "/projects?filter[]=custom_field:Nickname is_set&filter[]=is_done is false";
  my $res = $self->http_get_for_master("$LP_BASE$query");
  return {} unless $res && $res->is_success;

  my %project_dict;

  my @projects = @{ $JSON->decode( $res->decoded_content ) };
  for my $project (@projects) {
    # Impossible, right?
    next unless my $nick = $project->{custom_field_values}{Nickname};

    # We'll deal with conflicts later. -- rjbs, 2018-01-22
    $project_dict{ lc $nick } //= [];
    push $project_dict{ lc $nick }->@*, {
      id        => $project->{id},
      nickname  => $nick,
      name      => $project->{name},
    };
  }

  return \%project_dict;
}

sub dispatch_event ($self, $event, $rch) {
  unless ($event->from_user) {
    $rch->reply("Sorry, I don't know who you are.");
    return 1;
  }

  # existing hacks for silly greetings
  my $text = $event->text;
  $text = "good day_au" if $text =~ /\A\s*g'day(?:,?\s+mate)?[1!.?]*\z/i;
  $text = "good day_de" if $text =~ /\Agruß gott[1!.]?\z/i;
  $text =~ s/\Ago{3,}d(?=\s)/good/;

  my ($what, $rest) = $text =~ /^([^\s]+)\s*(.*)/;
  $what &&= lc $what;

  # we can be polite even to non-lp-enabled users
  return $self->_handle_good($event, $rch, $rest) if $what eq 'good';

  unless ($event->from_user->lp_auth_header) {
    $rch->reply($ERR_NO_LP);
    return 1;
  }

  return $KNOWN{$what}->($self, $event, $rch, $rest)
}

sub http_get_for_user ($self, $user, @arg) {
  return $self->hub->http_get(@arg,
    Authorization => $user->lp_auth_header,
  );
}

sub http_post_for_user ($self, $user, @arg) {
  return $self->hub->http_post(@arg,
    Authorization => $user->lp_auth_header,
  );
}

sub http_get_for_master ($self, @arg) {
  my ($master) = $self->hub->user_directory->master_users;
  unless ($master) {
    warn "No master users configured\n";
    return;
  }

  $self->http_get_for_user($master, @arg);
}

sub _handle_timer ($self, $event, $rch, $text) {
  my $user = $event->from_user;

  return $rch->reply($ERR_NO_LP)
    unless $user && $user->lp_auth_header;

  my $res = $self->http_get_for_user($user, "$LP_BASE/my_timers");

  unless ($res->is_success) {
    warn "failed to get timer: " . $res->as_string . "\n";

    return $rch->reply("I couldn't get your timer. Sorry!");
  }

  my @timers = grep {; $_->{running} }
               @{ $JSON->decode( $res->decoded_content ) };

  my $sy_timer = $user->timer;

  unless (@timers) {
    my $nag = $sy_timer->last_relevant_nag;
    my $msg;
    if (! $nag) {
      $msg = "You don't have a running timer.";
    } elsif ($nag->{level} == 0) {
      $msg = "Like I said, you don't have a running timer.";
    } else {
      $msg = "Like I keep telling you, you don't have a running timer!";
    }

    return $rch->reply($msg);
  }

  if (@timers > 1) {
    $rch->reply(
      "Woah.  LiquidPlanner says you have more than one active timer!",
    );
  }

  my $timer = $timers[0];
  my $time = concise( duration( $timer->{running_time} * 3600 ) );
  my $task_res = $self->http_get_for_user($user, "$LP_BASE/tasks/$timer->{item_id}");

  my $name = $task_res->is_success
           ? $JSON->decode($task_res->decoded_content)->{name}
           : '??';

  my $url = sprintf "$LINK_BASE/%s", $timer->{item_id};

  return $rch->reply(
    "Your timer has been running for $time, work on: $name <$url>",
  );
}

sub _handle_task ($self, $event, $rch, $text) {
  # because of "new task for...";
  my $what = $text =~ s/\Atask\s+//r;

  my ($target, $name) = $what =~ /\s*for\s+@?(.+?)\s*:\s+(.+)\z/;

  return -1 unless $target and $name;

  my @target_names = split /(?:\s*,\s*|\s+and\s+)/, $target;
  my (@owners, @no_lp, @unknown);
  my %seen;

  my %project_id;
  for my $name (@target_names) {
    my $target = $self->resolve_name($name, $event->from_user->username);

    next if $target && $seen{ $target->username }++;

    my $owner_id = $target ? $target->lp_id : undef;

    # Sadly, the following line is not valid:
    # push(($owner_id ? @owner_ids : @unknown), $owner_id);
    if ($owner_id) {
      push @owners, $target;

      # XXX - From real config! --alh, 2018-03-14
      my $config;
      my $project_id = $CONFIG->{liquidplanner}{project}{$target->username};
      warn sprintf "Looking for project for %s found %s\n",
        $target->username, $project_id // '(undef)';

      $project_id{ $project_id }++ if $project_id;
    } elsif ($target) {
      push @no_lp, $target->username;
    } else {
      push @unknown, $name;
    }
  }

  if (@unknown or @no_lp) {
    my @fail;

    if (@unknown) {
      my $str = @unknown == 1 ? "$unknown[0] is"
              : @unknown == 2 ? "$unknown[0] or $unknown[1] are"
              : join(q{, }, @unknown[0 .. $#unknown-1], "or $unknown[-1] are");
      push @fail, "I don't know who $str.";
    }

    if (@no_lp) {
      my $str = @no_lp == 1 ? $no_lp[0]
              : @no_lp == 2 ? "$no_lp[0] or $no_lp[1]"
              : join(q{, }, @no_lp[0 .. $#no_lp-1], "or $no_lp[-1]");
      push @fail, "There's no LiquidPlanner user for $str.";
    }

    return $rch->reply(join(q{  }, @fail));
  }

  my $flags = $self->_strip_name_flags($name);
  my $urgent = $flags->{urgent};
  my $start  = $flags->{running};

  my $via = $rch->channel->describe_event($event);
  my $user = $event->from_user;
  $user = undef unless $user && $user->lp_auth_header;

  my $description = sprintf 'created by %s in response to %s',
    'pizzazz', # XXX -- alh, 2018-03-14
    $via;

  my $project_id = (keys %project_id)[0] if 1 == keys %project_id;

  my $arg = {};

  my $task = $self->_create_lp_task($rch, {
    name   => $name,
    urgent => $urgent,
    user   => $user,
    owners => \@owners,
    description => $description,
    project_id  => $project_id,
  }, $arg);

  unless ($task) {
    if ($arg->{already_notified}) {
      return;
    } else {
      return $rch->reply(
        "Sorry, something went wrong when I tried to make that task.",
        $arg,
      );
    }
  }

  my $rcpt = join q{ and }, map {; $_->username } @owners;

  my $reply = sprintf
    "Task for $rcpt created: https://app.liquidplanner.com/space/%s/projects/show/%s",
    $WKSP_ID,
    $task->{id};

  if ($start) {
    if ($user) {
      my $res = $self->http_post_for_user($user, "$LP_BASE/tasks/$task->{id}/timer/start");
      my $timer = eval { $JSON->decode( $res->decoded_content ); };
      if ($res->is_success && $timer->{running}) {
        $user->last_lp_timer_id($timer->{id});

        $reply =~ s/created:/created, timer running:/;
      } else {
        $reply =~ s/created:/created, timer couldn't be started:/;
      }
    } else {
      $reply =~ s/created:/created, timer couldn't be started:/;
    }
  }

  $rch->reply($reply);
}

sub lp_tasks_for_user ($self, $user, $count, $which='tasks') {
  my $res = $self->http_get_for_user(
    $user,
    "$LP_BASE/upcoming_tasks?limit=200&flat=true&member_id=" . $user->lp_id,
  );

  unless ($res->is_success) {
    $Logger->log("failed to get tasks from LiquidPlanner: " . $res->as_string);
    return;
  }

  my $tasks = $JSON->decode( $res->decoded_content );

  @$tasks = grep {; $_->{type} eq 'Task' } @$tasks;

  if ($which eq 'tasks') {
    @$tasks = grep {;
      (! grep { $CONFIG->{liquidplanner}{package}{inbox} == $_ } $_->{parent_ids}->@*)
      &&
      (! grep { $CONFIG->{liquidplanner}{package}{inbox} == $_ } $_->{package_ids}->@*)
    } @$tasks;
  } else {
    my $package_id = $CONFIG->{liquidplanner}{package}{ $which };
    unless ($package_id) {
      warn "can't find package_id for '$which'";
      return;
    }

    @$tasks = grep {;
      (grep { $package_id == $_ } $_->{parent_ids}->@*)
      ||
      (grep { $package_id == $_ } $_->{package_ids}->@*)
    } @$tasks;
  }

  splice @$tasks, $count;

  my $urgent = $CONFIG->{liquidplanner}{package}{urgent};
  for (@$tasks) {
    $_->{name} = "[URGENT] $_->{name}"
      if (grep { $urgent == $_ } $_->{parent_ids}->@*)
      || (grep { $urgent == $_ } $_->{package_ids}->@*);
  }

  return $tasks;
}

sub _handle_tasks ($self, $event, $rch, $text) {
  my $user = $event->from_user;
  my ($how_many) = $text =~ /\Atasks\s+([0-9]+)\z/;

  my $per_page = 5;
  my $page = $how_many && $how_many > 0 ? $how_many : 1;

  unless ($page <= 10) {
    return $rch->reply(
      "If it's not in your first ten pages, better go to the web.",
    );
  }

  my $count = $per_page * $page;
  my $start = $per_page * ($page - 1);

  my $lp_tasks = $self->lp_tasks_for_user($user, $count, 'tasks');

  for my $task (splice @$lp_tasks, $start, $per_page) {
    $rch->private_reply("$task->{name} ($LINK_BASE$task->{id})");
  }

  $rch->reply("responses to <tasks> are sent privately") if $event->is_public;
}

sub _handle_task_like ($self, $event, $rch, $command, $count) {
  my $user = $event->from_user;
  my $lp_tasks = $self->lp_tasks_for_user($user, $count, $command);

  unless (@$lp_tasks) {
    my $suffix = $command =~ /(inbox|urgent)/n
               ? ' \o/'
               : '';
    $rch->reply("you don't have any open $command tasks right now.$suffix");
    return;
  }

  for my $task (@$lp_tasks) {
    $rch->private_reply("$task->{name} ($LINK_BASE$task->{id})");
  }

  $rch->reply("responses to <$command> are sent privately") if $event->is_public;
}


sub _handle_inbox ($self, $event, $rch, $text) {
  return $self->_handle_task_like($event, $rch, 'inbox', 200);
}

sub _handle_urgent ($self, $event, $rch, $text) {
  return $self->_handle_task_like($event, $rch, 'urgent', 100);
}

sub _handle_recurring ($self, $event, $rch, $text) {
  return $self->_handle_task_like($event, $rch, 'recurring', 100);
}

sub _handle_plus_plus ($self, $event, $rch, $text) {
  my $user = $event->from_user;

  return $rch->reply($ERR_NO_LP)
    unless $user && $user->lp_auth_header;

  if (! length $text) {
    return $rch->reply("Thanks, but I'm only as awesome as my creators.");
  }

  my $who = $event->from_user->username;

  return $self->_handle_task($event, $rch, "task for $who: $text");
}

my @BYE = (
  "See you later, alligator.",
  "After a while, crocodile.",
  "Time to scoot, little newt.",
  "See you soon, raccoon.",
  "Auf wiedertippen!",
  "Later.",
  "Peace.",
  "¡Adios!",
  "Au revoir.",
  "221 2.0.0 Bye",
  "+++ATH0",
  "Later, gator!",
  "Pip pip.",
  "Aloha.",
  "Farewell, %n.",
);

sub _handle_good ($self, $event, $rch, $text) {
  my $user = $event->from_user;

  my ($what) = $text =~ /^([a-z_]+)/i;
  my ($reply, $expand, $stop, $end_of_day);

  if    ($what eq 'morning')    { $reply  = "Good morning!";
                                  $expand = 'morning'; }

  elsif ($what eq 'day_au')     { $reply  = "How ya goin'?";
                                  $expand = 'morning'; }

  elsif ($what eq 'day_de')     { $reply  = "Doch, wenn du ihn siehst!";
                                  $expand = 'morning'; }

  elsif ($what eq 'day')        { $reply  = "Long days and pleasant nights!";
                                  $expand = 'morning'; }

  elsif ($what eq 'afternoon')  { $reply  = "You, too!";
                                  $expand = 'afternoon' }

  elsif ($what eq 'evening')    { $reply  = "I'll be here when you get back!";
                                  $stop   = 1; }

  elsif ($what eq 'night')      { $reply  = "Sleep tight!";
                                  $stop   = 1;
                                  $end_of_day = 1; }

  elsif ($what eq 'riddance')   { $reply  = "I'll outlive you all.";
                                  $stop   = 1;
                                  $end_of_day = 1; }

  elsif ($what eq 'bye')        { $reply  = pick_one(\@BYE);
                                  $stop   = 1;
                                  $end_of_day = 1; }

  if ($reply) {
    $reply =~ s/%n/$user->username/ge;
  }

  return $rch->reply($reply) if $reply and not $user->lp_auth_header;

  # TODO: implement expandos
  if ($expand && $user->tasks_for_expando($expand)) {
    $self->expand_tasks($rch, $event, $expand, "$reply  ");
    $reply = '';
  }

  if ($stop) {
    my $res = $self->http_get_for_user($user, "$LP_BASE/my_timers");

    if ($res->is_success) {
      my @timers = grep {; $_->{running} }
                   @{ $JSON->decode( $res->decoded_content ) };

      if (@timers) {
        return $rch->reply("You've got a running timer!  You should commit it.");
      }
    }
  }

  # XXX: Waiting on chill
  if ($end_of_day && (my $sy_timer = $user->timer)) {
    my $time = parse_time_hunk('until tomorrow', $user);
    # $sy_timer->chilltill($time);
  }

  return $rch->reply($reply) if $reply;
}

sub _handle_expand ($self, $event, $rch, $text) {
  my $user = $event->from_user;
  my ($what) = $text =~ /^([a-z_]+)/i;
  $self->expand_tasks($rch, $event, $what);
}

sub expand_tasks ($self, $rch, $event, $expand_target, $prefix='') {
  my $user = $event->from_user;

  unless ($expand_target && $expand_target =~ /\S/) {
    my @names = sort $user->defined_expandoes;
    return $rch->reply($prefix . "You don't have any expandoes") unless @names;
    return $rch->reply($prefix . "Your expandoes: " . (join q{, }, @names));
  }

  my @tasks = $user->tasks_for_expando($expand_target);
  return $rch->reply($prefix . "You don't have an expando for <$expand_target>")
    unless @tasks;

  my $parent = $CONFIG->{liquidplanner}{package}{recurring};
  my $desc = $rch->channel->describe_event($event);

  my (@ok, @fail);
  for my $task (@tasks) {
    my $payload = { task => {
      name        => $task,
      parent_id   => $parent,
      assignments => [ { person_id => $user->lp_id } ],
      description => $desc,
    } };

    $Logger->log([ "creating LP task: %s", $payload ]);

    my $res = $self->http_post_for_user($user,
      "$LP_BASE/tasks",
      Content_Type => 'application/json',
      Content => $JSON->encode($payload),
    );
    if ($res->is_success) {
      push @ok, $task;
    } else {
      $Logger->log([ "error creating LP task: %s", $res->decoded_content ]);
      push @fail, $task;
    }
  }
  my $reply;
  if (@ok) {
    $reply = "I created your $expand_target tasks: " . join(q{; }, @ok);
    $reply .= "  Some tasks failed to create: " . join(q{; }, @fail) if @fail;
  } elsif (@fail) {
    $reply = "Your $expand_target tasks couldn't be created.  Sorry!";
  } else {
    $reply = "Something impossible happened.  How exciting!";
  }
  $rch->reply($prefix . $reply);
}


sub resolve_name ($self, $name, $who) {
  return unless $name;

  $name = lc $name;
  $name = $who if $name eq 'me' || $name eq 'my' || $name eq 'myself' || $name eq 'i';

  my $user = $self->hub->user_directory->user_by_name($name);
  $user ||= $self->hub->user_directory->user_by_nickname($name);

  return $user;
}

sub _create_lp_task ($self, $rch, $my_arg, $arg) {
  my $config; # XXX REAL CONFIG
  my %container = (
    package_id  => $my_arg->{urgent}
                ? $CONFIG->{liquidplanner}{package}{urgent}
                : $CONFIG->{liquidplanner}{package}{inbox},
    parent_id   => $my_arg->{project_id}
                ?  $my_arg->{project_id}
                :  undef,
  );

  if ($my_arg->{name} =~ s/#(.*)$//) {
    my $project = lc $1;

    my $projects = $self->project_named($project);

    unless ($projects && @$projects) {
      $arg->{already_notified} = 1;

      return $rch->reply(
          "I am not aware of a project named '$project'. (Try 'projects' "
        . "to see what projects I know about.)",
      );
    }

    if (@$projects > 1) {
      return $rch->reply(
          "More than one LiquidPlanner project has the nickname '$project'. "
        . "Their ids are: "
        . join(q{, }, map {; $_->{id} } @$projects),
      );
    }

    $container{parent_id} = $projects->[0]{id};
  }

  $container{parent_id} = delete $container{package_id}
    unless $container{parent_id};

  my $payload = { task => {
    name        => $my_arg->{name},
    assignments => [ map {; { person_id => $_->lp_id } } @{ $my_arg->{owners} } ],
    description => $my_arg->{description},

    %container,
  } };

  my $as_user = $my_arg->{user} // $self->master_lp_user;

  my $res = $self->http_post_for_user(
    $as_user,
    "$LP_BASE/tasks",
    Content_Type => 'application/json',
    Content => $JSON->encode($payload),
  );

  unless ($res->is_success) {
    warn ">>" . $res->decoded_content . "<<";
    warn $res->as_string;
    return;
  }

  my $task = $JSON->decode($res->decoded_content);

  return $task;
}

sub _strip_name_flags ($self, $name) {
  my ($urgent, $running);
  if ($name =~ s/\s*\(([!>]+)\)\s*\z//) {
    my ($code) = $1;
    $urgent   = $code =~ /!/;
    $running  = $code =~ />/;
  } elsif ($name =~ s/\s*((?::timer_clock:|:hourglass(?:_flowing_sand)?:|:exclamation:)+)\s*\z//) {
    my ($code) = $1;
    $urgent   = $code =~ /exclamation/;
    $running  = $code =~ /timer_clock|hourglass/;
  }

  $_[1] = $name;

  return { urgent => $urgent, running => $running };
}

sub lp_timer_for_user ($self, $user) {
  return unless $user->lp_auth_header;

  my $res = $self->http_get_for_user($user, "$LP_BASE/my_timers");
  return -1 unless $res->is_success; # XXX WARN

  my ($timer) = grep {; $_->{running} }
                @{ $JSON->decode( $res->decoded_content ) };

  if ($timer) {
    $user->last_lp_timer_id($timer->{id});
  }

  return $timer;
}


1;
