use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use File::Temp qw( tempdir );
use YAML::XS qw( Dump );

use App::karr::Git;
use App::karr::BoardStore;
use App::karr::Task;
use App::karr::Cmd::Pick;

# Ticket #233: kanban-md's sortPickCandidates (internal/board/pick.go) has one
# exception to "class of service, then priority": when *both* candidates carry
# the `fixed-date` class -- the class whose whole point is the date -- the
# earlier due date decides before priority is asked at all. karr's pick_rank
# went class -> priority -> id and never read `due`, so on the ticket's board
#
#     #1  todo  class=fixed-date  priority=high  due=2026-03-15
#     #2  todo  class=fixed-date  priority=low   due=2026-02-15
#
# kanban-md picked 2 and karr picked 1.
#
# Three things are pinned here, because the exception is easy to over-apply:
# the positive case, the fallbacks kanban-md's compareDue leaves to priority
# (no due at all on either card, or the same due on both), and -- the part a
# naive fix breaks -- that a card without a due date sorts *last* among
# fixed-date cards rather than first, and that a comparison involving any
# other class never consults `due` at all.

sub _init_repo {
  my $repo = tempdir( CLEANUP => 1 );
  system( 'git', 'init', '-q', $repo ) == 0 or die "git init failed";
  system( 'git', '-C', $repo, 'config', 'user.email', 'test@example.com' );
  system( 'git', '-C', $repo, 'config', 'user.name',  'Test User' );
  return $repo;
}

# The default board, so `classes` is kanban-md's own list -- expedite,
# fixed-date, standard, intangible -- and the class indexes the exception has
# to stay out of the way of are the ones the reference test uses.
sub _board {
  my (%override) = @_;
  my $repo = _init_repo();
  my $git  = App::karr::Git->new( dir => $repo );
  $git->write_ref( 'refs/karr/config',
    Dump( { version => 1, board => { name => 'Due Board' }, %override } ) );
  return App::karr::BoardStore->new( git => $git );
}

sub mk {
  my ( $store, %a ) = @_;
  my $t = App::karr::Task->new(
    id       => $a{id},
    title    => $a{title} // "task $a{id}",
    status   => $a{status}   // 'todo',
    priority => $a{priority} // 'medium',
    class    => $a{class}    // 'fixed-date',
    ( exists $a{due} ? ( due => $a{due} ) : () ),
  );
  $store->save_task($t);
  return $t;
}

# `karr pick --claim AGENT` end to end, returning the id it handed out.
sub pick_id {
  my ( $store, %opt ) = @_;
  my $cmd = App::karr::Cmd::Pick->new( store => $store, %opt );
  my $buf = '';
  my $err = do {
    local $@;
    eval {
      local *STDOUT;
      open STDOUT, '>', \$buf or die $!;
      $cmd->execute( [], [] );
    };
    $@;
  };
  die "pick died: $err" if $err;
  return $buf =~ /^Picked task (\d+):/m ? $1 : undef;
}

subtest 'two fixed-date cards: the sooner due one wins over the more urgent one' => sub {
  # The ticket's board, card for card (kanban-md's TestPickFixedDateByDueDate).
  my $store = _board();
  mk( $store, id => 1, priority => 'high', due => '2026-03-15' );
  mk( $store, id => 2, priority => 'low',  due => '2026-02-15' );

  is pick_id( $store, claim => 'agent-a' ), 2,
    'pick hands out the card due in February, not the high-priority one due in March'
    or diag 'pre-#233 pick_rank never read `due` and priority decided';
  is pick_id( $store, claim => 'agent-b' ), 1,
    'the later-due card is next, not skipped';
};

subtest 'a fixed-date card without a due date sorts last, not first' => sub {
  # compareDue (internal/board/sort.go): a nil due is not "due now", it loses
  # to any card that has one -- even a card at the lowest priority on the
  # board. A fix that treats a missing date as the empty string, or as
  # infinitely early, picks 1 here.
  my $store = _board();
  mk( $store, id => 1, priority => 'critical' );
  mk( $store, id => 2, priority => 'low', due => '2026-03-01' );

  is pick_id( $store, claim => 'agent-a' ), 2,
    'the dated card goes first even though the undated one is critical';
};

subtest 'fixed-date cards the due date cannot separate fall through to priority' => sub {
  # Both of compareDue's "neither is before the other" cases: no due dates at
  # all, and the same due date on both. kanban-md then asks priority, which is
  # what karr did all along -- the exception must not swallow that.
  my $none = _board();
  mk( $none, id => 1, priority => 'low' );
  mk( $none, id => 2, priority => 'high' );
  is pick_id( $none, claim => 'agent-a' ), 2,
    'neither card is dated, so the higher priority wins';

  my $same = _board();
  mk( $same, id => 1, priority => 'low',  due => '2026-03-01' );
  mk( $same, id => 2, priority => 'high', due => '2026-03-01' );
  is pick_id( $same, claim => 'agent-b' ), 2,
    'both are due the same day, so the higher priority wins';
};

subtest 'the exception needs fixed-date on BOTH cards' => sub {
  # kanban-md guards the due comparison with
  # `candidates[i].Class == "fixed-date" && candidates[j].Class == "fixed-date"`.
  # Against any other class the class index alone decides, in both directions:
  # expedite outranks fixed-date however soon the fixed-date card is due, and
  # fixed-date outranks standard however soon the standard card is due.
  my $vs_expedite = _board();
  mk( $vs_expedite, id => 1, class => 'expedite', priority => 'low' );
  mk( $vs_expedite, id => 2, class => 'fixed-date',
    priority => 'critical', due => '2026-01-01' );
  is pick_id( $vs_expedite, claim => 'agent-a' ), 1,
    'expedite (class index 0) wins, and the fixed-date due date never enters it';

  my $vs_standard = _board();
  mk( $vs_standard, id => 1, class => 'standard',
    priority => 'medium', due => '2026-01-01' );
  mk( $vs_standard, id => 2, class => 'fixed-date', priority => 'medium' );
  is pick_id( $vs_standard, claim => 'agent-b' ), 2,
    'fixed-date (class index 1) wins over standard, undated against a January date';
};

subtest 'cards of another class are still ranked by priority, never by due' => sub {
  # The same-class case for a class that is not fixed-date: two standard
  # cards, the low-priority one due tomorrow. A due comparison applied to
  # every class -- rather than gated on fixed-date -- would pick 1.
  my $store = _board();
  mk( $store, id => 1, class => 'standard', priority => 'low',  due => '2026-01-01' );
  mk( $store, id => 2, class => 'standard', priority => 'high', due => '2030-12-31' );

  is pick_id( $store, claim => 'agent-a' ), 2,
    'priority decides between two standard cards, whatever their due dates say';
};

done_testing;
