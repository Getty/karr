use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use File::Temp qw( tempdir );
use Path::Tiny qw( path );
use YAML::XS qw( Dump );
use Time::Piece;

use App::karr::Git;
use App::karr::BoardStore;
use App::karr::Task;
use App::karr::Role::PickRules;
use App::karr::Cmd::Pick;
use App::karr::Foundation::Picker;

# Ticket #198: `karr pick` and karr-foundation's ticket mode
# (App::karr::Foundation::Picker) both answer "which card next?", and they have
# to answer it the same way -- a coordinator that names a card the agent's own
# `karr pick` would not have handed it is arguing with its own board. Until
# #198 the eligibility test and the class/priority/id ranking were written out
# in both files. They agreed because one was copied from the other; nothing
# held them there.
#
# So this file has two jobs, and neither is enough on its own:
#
#   * pin the ranking and the eligibility rule to concrete answers, so a change
#     to either -- in whichever place it now lives -- fails here. A test that
#     only compared the two selectors to each other could not fail when the
#     rule changes, since a shared definition changes for both at once, and
#     would have been worthless as a guard on the rule itself.
#
#   * prove the two callers cannot drift again: they run in lockstep on the
#     same board against the same pinned expectations, they resolve the rule
#     methods to the very same coderefs, and neither file spells a ranking or
#     an eligibility test out for itself any more.

sub _init_repo {
  my $repo = tempdir( CLEANUP => 1 );
  system( 'git', 'init', '-q', $repo ) == 0 or die "git init failed";
  system( 'git', '-C', $repo, 'config', 'user.email', 'test@example.com' );
  system( 'git', '-C', $repo, 'config', 'user.name',  'Test User' );
  return $repo;
}

# A board whose config is written straight into refs/karr/config, so every
# ordering assertion below is about the board's own priorities and classes
# rather than the built-in defaults.
sub _board {
  my ( %override ) = @_;
  my $repo = _init_repo();
  my $git  = App::karr::Git->new( dir => $repo );
  $git->write_ref( 'refs/karr/config',
    Dump( { version => 1, board => { name => 'Shared Rules Board' }, %override } ) );
  return $repo;
}

# A fresh store per question: both selectors are read paths, and a cached one
# would let an earlier answer stand in for a later board state.
sub _store {
  my ( $repo ) = @_;
  return App::karr::BoardStore->new( git => App::karr::Git->new( dir => $repo ) );
}

sub mk {
  my ( $repo, %a ) = @_;
  my $t = App::karr::Task->new(
    id       => $a{id},
    title    => $a{title} // "task $a{id}",
    status   => $a{status}   // 'todo',
    priority => $a{priority} // 'medium',
    class    => $a{class}    // 'standard',
    ( exists $a{tags}       ? ( tags       => $a{tags} )       : () ),
    ( exists $a{blocked}    ? ( blocked    => $a{blocked} )    : () ),
    ( exists $a{claimed_by} ? ( claimed_by => $a{claimed_by} ) : () ),
    ( exists $a{claimed_at} ? ( claimed_at => $a{claimed_at} ) : () ),
  );
  _store($repo)->save_task($t);
  return $t;
}

sub ago {
  my ( $secs ) = @_;
  return gmtime( time - $secs )->datetime . 'Z';
}

# `karr pick` end to end, returning the id it handed out (or undef). It claims
# what it picks, which is what advances the board between lockstep rounds.
sub pick_id {
  my ( $repo, %opt ) = @_;
  my $cmd = App::karr::Cmd::Pick->new( store => _store($repo), %opt );
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

# karr-foundation's ticket mode, asked about the same board. Claims nothing.
sub ticket_id {
  my ( $repo ) = @_;
  return App::karr::Foundation::Picker->new( store => _store($repo) )->next_ticket;
}

# Ask both selectors about the same board, in the same state, and hold both
# against the pinned expectation. Foundation goes first, because pick writes.
sub both_choose {
  my ( $repo, $expected, $why ) = @_;
  is( ticket_id($repo), $expected, "foundation ticket mode: $why" );
  is( pick_id( $repo, claim => "agent-" . ( $expected // 'none' ) ),
    $expected, "karr pick: $why" );
  return;
}

subtest 'both callers resolve the rules to one definition' => sub {
  ok( App::karr::Cmd::Pick->does('App::karr::Role::PickRules'),
    'karr pick composes the shared pick rules' );
  ok( App::karr::Foundation::Picker->does('App::karr::Role::PickRules'),
    'foundation ticket mode composes the shared pick rules' );

  # Same name is not enough -- two copies would answer ->can too. The installed
  # coderef has to be the role's own, in both packages, or one of them is
  # running something else under the shared name.
  for my $method ( qw( pickable pick_rank pick_candidates ) ) {
    my $rule = App::karr::Role::PickRules->can($method);
    ok( $rule, "the role defines $method" ) or next;
    is( App::karr::Cmd::Pick->can($method), $rule,
      "karr pick's $method is the role's own coderef" );
    is( App::karr::Foundation::Picker->can($method), $rule,
      "foundation's $method is the role's own coderef" );
  }
};

subtest 'neither caller keeps a rule of its own to drift with' => sub {
  # The re-fork guard. Composing the role does not stop anyone from adding a
  # second sort or a second eligibility test next to it -- that is exactly how
  # this ticket happened -- so read both files and insist the rule is not
  # spelled out in either. POD and comments are stripped: both files talk about
  # the rules at length, and #198's own comments name them.
  my %file = (
    'karr pick'          => 'lib/App/karr/Cmd/Pick.pm',
    'foundation ticket'  => 'lib/App/karr/Foundation/Picker.pm',
  );

  # Each fragment is a piece of the rule that used to be written out locally:
  # the three-way comparison chain of the ranking, the two config lists it
  # ranks from, and the three predicates eligibility is made of.
  my @forbidden = (
    [ qr/<=>/,                 'a comparison of its own' ],
    [ qr/\bpriorities\b/,      'the board priorities list' ],
    [ qr/\bclasses\b/,         'the board classes list' ],
    [ qr/is_terminal_status/,  'the terminal-status test' ],
    [ qr/has_blocked/,         'the blocked test' ],
    [ qr/has_claimed_by/,      'the claim test' ],
    [ qr/_claim_expired/,      'the claim-expiry test' ],
  );

  for my $who ( sort keys %file ) {
    my $src = path( $file{$who} )->slurp_utf8;
    $src =~ s/^=\w+.*?^=cut\b.*?$//msg;
    $src =~ s/^\s*#.*$//mg;
    for my $rule ( @forbidden ) {
      my ( $re, $what ) = @$rule;
      unlike( $src, $re,
        "$file{$who} ($who) does not carry $what -- it asks the role" );
    }
  }
};

subtest 'the ranking itself, pinned card by card' => sub {
  # A board whose priorities and classes are its own, so nothing here can be
  # satisfied by a hardcoded table (#149), and every rung of the rule is
  # load-bearing: class before priority, priority most-urgent-last in the
  # config list, id as the tie-break, an unknown class ranking where
  # `standard` would and an unknown priority ranking below every known one.
  my $repo = _board(
    priorities => [qw( p0 p1 p2 p3 )],
    classes    => [qw( alpha beta gamma )],
  );
  mk( $repo, id => 1, class => 'beta',  priority => 'p3' );
  mk( $repo, id => 2, class => 'alpha', priority => 'p0' );
  mk( $repo, id => 3, class => 'beta',  priority => 'p3' );
  mk( $repo, id => 4, class => 'gamma', priority => 'p3' );
  mk( $repo, id => 5, class => 'beta',  priority => 'p1' );
  mk( $repo, id => 6, class => 'alpha', priority => 'p1' );
  mk( $repo, id => 7, class => 'quux',  priority => 'p2' );
  mk( $repo, id => 8, class => 'beta',  priority => 'nonesuch' );

  # 7 and 6 and 2 first: class index 0 (`quux` is not in the list, so it ranks
  # where `standard` would, and `standard` is not in this list either -- index
  # 0), most urgent priority first. Then beta: p3 with the id tie-break, then
  # p1, then the priority the board never heard of. gamma last.
  #
  # What this order does NOT pin is that last step, the fallback for a class
  # the board does not list on a board that lists no `standard` either: 7 has
  # the most urgent priority of the three class-0 cards, so it comes out first
  # whether that fallback is karr's 0 or kanban-md's -1 (ticket #240). The
  # subtest below is the one that can tell those apart -- do not read this
  # `@expected` as cover for it.
  my @expected = ( 7, 6, 2, 1, 3, 5, 8, 4 );

  for my $i ( 0 .. $#expected ) {
    both_choose( $repo, $expected[$i], "round " . ( $i + 1 ) . " is task $expected[$i]" );
  }

  both_choose( $repo, undef, 'nothing left once every card is claimed' );
};

subtest 'an unknown class on a board without `standard`' => sub {
  # A deliberate divergence from kanban-md in this ranking (ticket #240,
  # documented in App::karr::Role::PickRules/pick_rank): a class
  # the board does not list takes `standard`'s index, and index 0 where the
  # board's `classes` does not name `standard` either. kanban-md's classOrder
  # passes ClassIndex("standard") straight through, and that is -1 on such a
  # board, which would put the unknown class ahead of every configured one.
  #
  # The decision is to stay gentle -- a card with a typo in its class behaves
  # like an ordinary card instead of jumping the queue -- and this is the only
  # assertion that holds it. Card 2 is given the board's least urgent priority
  # and the higher id, so nothing but the class rung can put it in front: with
  # the fallback at 0 it ranks level with `alpha` and loses on priority; with
  # -1 it would be handed out first and round 1 here would fail.
  my $repo = _board(
    priorities => [qw( p0 p1 p2 p3 )],
    classes    => [qw( alpha beta gamma )],
  );
  mk( $repo, id => 1, class => 'alpha', priority => 'p3' );
  mk( $repo, id => 2, class => 'quux',  priority => 'p0' );

  both_choose( $repo, 1, 'the listed class with the urgent priority goes first' );
  both_choose( $repo, 2, 'the unknown class waits its turn instead of leading' );
};

subtest 'eligibility itself, pinned reason by reason' => sub {
  my $repo = _board();
  mk( $repo, id => 1, blocked => 'waiting on the vendor' );
  mk( $repo, id => 2, status  => 'done' );
  mk( $repo, id => 3, status  => 'archived' );
  mk( $repo, id => 4, claimed_by => 'agent-busy', claimed_at => ago(60) );
  mk( $repo, id => 5, claimed_by => 'agent-gone', claimed_at => ago(3 * 3600) );
  mk( $repo, id => 6 );

  # Every card below 5 is out for a different reason, and both selectors have
  # to be out for the same reasons: blocked, the board's two terminal
  # statuses, and a claim that is still inside the board's 1h claim_timeout.
  # 5's claim is three hours old, which is what expiry is for -- and what
  # foundation must see too, or one crashed agent silences a board for good.
  both_choose( $repo, 5, 'the expired claim is taken over, ahead of 6 by id' );
  both_choose( $repo, 6, 'then the plain unclaimed card' );
  both_choose( $repo, undef,
    'blocked, done, archived and live-claimed cards are nobody\'s' );
};

subtest "pick's filters narrow the shared rule rather than replace it" => sub {
  # The one difference that is meant to exist: --status and --tags are the
  # command's options and foundation has neither. They select within the same
  # rule -- a live claim and a blocked card stay out under a filter too.
  my $repo = _board();
  mk( $repo, id => 1, status => 'todo' );
  mk( $repo, id => 2, status => 'done', tags => ['release'] );
  mk( $repo, id => 3, status => 'todo', tags => ['release'], blocked => 'nope' );
  mk( $repo, id => 4, status => 'done', tags => ['release'],
    claimed_by => 'agent-busy', claimed_at => ago(60) );

  is( ticket_id($repo), 1,
    'foundation, with no filters, sees only the non-terminal unblocked card' );

  is( pick_id( $repo, claim => 'agent-a', status => 'done' ), 2,
    '--status reaches a terminal card foundation will never name' );
  is( pick_id( $repo, claim => 'agent-b', status => 'done' ), undef,
    'but 4 stays out under the filter: a live claim is still a live claim' );
  is( pick_id( $repo, claim => 'agent-c', tags => 'release' ), undef,
    'and --tags does not reach 3 either, because blocked is still blocked' );
  is( pick_id( $repo, claim => 'agent-d', tags => 'nosuchtag' ), undef,
    'a tag no card carries picks nothing' );
  is( pick_id( $repo, claim => 'agent-e' ), 1,
    'unfiltered, pick agrees with foundation on the same board' );
};

done_testing;
