use v5.34.0;
use warnings;
package Synergy::Reactor::Eject;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor::CommandPost';

use experimental qw(signatures);
use namespace::clean;

use Future::AsyncAwait;
use Synergy::CommandPost;

responder my_projects => {
  exclusive => 1,
  targeted  => 1,
  matcher   => sub ($text, @) { fc $text eq 'eject warp core' ? [] : () },
} => async sub ($self, $event) {
  $event->mark_handled;
  await $event->reply('Good bye.');
  kill 'INT', $$;
};

1;
