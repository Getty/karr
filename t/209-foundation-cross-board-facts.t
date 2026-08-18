use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use Path::Tiny qw( path tempdir );

use App::karr::Foundation;
use App::karr::Foundation::Executor;
use App::karr::Foundation::ChainStore;
use App::karr::Git;
use App::karr::BoardStore;
use App::karr::CrossBoard;
use App::karr::Task;

# Ticket #209, the open half of #192 and the last gap the epic (#194) still
# named: cross-board links existed as a tag on a card (#192) and as a hand
# command (`karr needs`), and NOTHING in the chain executor could see them. A
# step could not be made to wait for a card in another repository, because no
# precheck could ask about one.
#
# The answer is a fact, `ticket_links`, measured where every other fact is
# measured -- App::karr::Foundation::Executor::facts_for -- and modelled on
# `question_state` (#200), the fact that also comes from somewhere other than
# the step's own board.
#
# What is pinned here, and why each is a decision rather than an accident:
#
#   1. The fact is about the WHOLE card, in one word: `settled` only when every
#      link is, otherwise the first unsettled one in tag order. The precheck
#      grammar is `<fact> == <value>` and has nowhere to name a single link, so
#      a per-link fact could not be asked about at all.
#   2. A card carrying NO link is `settled`. Nothing elsewhere holds it -- the
#      same shape ticket_blocked has for a card nobody blocked -- and the other
#      reading would turn `karr needs --resolve` succeeding (it DROPS the tag)
#      into the thing that stops the step for ever.
#   3. What settles a link is one of the FAR board's own terminal statuses
#      (#67), never a hardcoded `done`.
#   4. A far card that does not exist settles NOTHING: `missing`, not
#      `settled`. Unblocking because the ticket somebody waited for cannot be
#      found is the silent wrong answer (#192, decision 5; #123 locally).
#   5. A far board this machine does not have makes the fact ABSENT, and an
#      absent fact makes a precheck not hold whichever operator it uses. #192
#      treats an unplaceable board as an answer rather than an error, and the
#      answer here is "not measurable here" -- so the step goes stale and the
#      machine that does have the board runs it.
#   6. The executor MEASURES and does not RESOLVE. The link is the fact,
#      `blocked` is the decision somebody took on purpose (#192, decision 4):
#      a settled link does not lift the block, does not touch the tag, and does
#      not write anything on either board. An executor that unblocked unasked
#      would be stricter than the board it coordinates -- the line Picker holds
#      by not filtering (#185) and pick by handing the card over (#123).
#   7. Nothing is fetched. The far board is read as it stands in that working
#      copy.
#   8. The directories come from the fleet config THIS RUN already read, handed
#      over parsed. Not a second file, and not a second read of the same file:
#      the argument #189 used for resolving the hub exactly once.
#
# Everything runs in throwaway repositories, HOME is redirected at a decoy for
# the whole file (see below), and no agent is ever started: the only command
# any step runs is an echo into a file.

my @KEEP;    # tempdirs vanish with their object

sub keepdir {
  my $dir = tempdir( CLEANUP => 1 );
  push @KEEP, $dir;
  return path($dir);
}

sub git_init {
  my ( $dir ) = @_;
  path($dir)->mkpath;
  system( 'git', 'init', '-q', "$dir" ) == 0 or die 'git init';
  system( 'git', '-C', "$dir", 'config', 'user.email', 'fleet@example.com' ) == 0 or die;
  system( 'git', '-C', "$dir", 'config', 'user.name', 'Fleet' ) == 0 or die;
  return path($dir);
}

sub store_of {
  my ( $repo ) = @_;
  return App::karr::BoardStore->new( git => App::karr::Git->new( dir => "$repo" ) );
}

# A board in a NAMED directory: a cross-board reference carries the board's
# name, which is its directory basename, so the names this test asserts on have
# to be real directory names rather than a tempdir's random syllables.
sub make_board {
  my ( $parent, $name, %opt ) = @_;
  my $repo  = git_init( path($parent)->child($name) );
  my $store = store_of($repo);
  $store->save_config( { %{ $store->effective_config },
    ( $opt{statuses} ? ( statuses => $opt{statuses} ) : () ) } );
  return $repo;
}

sub put_card {
  my ( $repo, %spec ) = @_;
  my $store = store_of($repo);
  my $task  = App::karr::Task->new(
    id     => $spec{id},
    title  => $spec{title} // "task $spec{id}",
    status => $spec{status} // 'todo',
    ( $spec{tags} ? ( tags => $spec{tags} ) : () ),
  );
  $task->block( $spec{block} ) if defined $spec{block};
  $store->save_task($task);
  return $task;
}

sub card_on {
  my ( $repo, $id ) = @_;
  return store_of($repo)->find_task($id);
}

# The fleet config this machine has: exactly the file karr-foundation itself
# reads, named with --config so no test ever depends on the developer's own
# ~/.config (and so the decoy below stays untouched).
sub fleet_config {
  my ( %opt ) = @_;
  my $file = keepdir()->child('config.yml');
  my $body = '';
  $body .= "hub: $opt{hub}\n" if defined $opt{hub};
  for my $key ( qw( dirs scan ) ) {
    next unless $opt{$key} && @{ $opt{$key} };
    $body .= "$key:\n";
    $body .= "  - $_\n" for @{ $opt{$key} };
  }
  $file->spew_utf8($body);
  return "$file";
}

# The executor, with its foundation held for the duration of the callback: the
# executor keeps its foundation weakly, so the test has to hold the other end.
sub with_exec {
  my ( $config, $code ) = @_;
  my $f    = App::karr::Foundation->new( config => "$config" );
  my $exec = App::karr::Foundation::Executor->new( foundation => $f );
  return $code->( $exec, $f );
}

sub links_fact {
  my ( $config, $repo, $id ) = @_;
  return with_exec( $config, sub {
    my ( $exec ) = @_;
    my $facts = $exec->facts_for(
      { id => 1, kind => 'ticket', repo => "$repo", ticket => $id } );
    return exists $facts->{ticket_links} ? $facts->{ticket_links} : undef;
  } );
}

# STDOUT through a real file rather than an in-memory scalar: a shell step forks
# and dups the child's stdout onto a pipe, and a scalar filehandle has no
# descriptor to dup onto.
sub capture {
  my ( $code ) = @_;
  my $file = Path::Tiny->tempfile;
  open my $save, '>&', \*STDOUT or die "dup stdout: $!";
  open STDOUT, '>', "$file"     or die "redirect stdout: $!";
  binmode STDOUT, ':encoding(UTF-8)';
  my ( $ret, $err );
  eval { $ret = $code->(); 1 } or $err = $@;
  open STDOUT, '>&', $save or die "restore stdout: $!";
  close $save;
  die $err if defined $err;
  return ( $file->slurp_utf8, $ret );
}

# ---------------------------------------------------------------------------
# A decoy in HOME, for the whole file.
#
# Every foundation here is built with --config, so ~/.config/karr-foundation/
# must never be consulted -- and "must never" is worth measuring rather than
# assuming. The decoy names every board this test creates, including the ones
# individual subtests deliberately leave unplaceable, so a second source
# sneaking back in does not merely go unnoticed: it turns an absent fact into a
# settled one and fails the subtest that asks for the safe direction.
# ---------------------------------------------------------------------------

my $DECOY = keepdir();
$ENV{HOME} = "$DECOY";

# ---------------------------------------------------------------------------

subtest 'a card with no cross-board link is settled, like a card nobody blocked is not blocked' => sub {
  my $work = keepdir();
  my $home = make_board( $work, 'home' );
  my $lib  = make_board( $work, 'lib' );
  put_card( $home, id => 1 );
  put_card( $lib,  id => 1, status => 'done' );
  my $cfg = fleet_config( dirs => [ "$home", "$lib" ] );

  my $facts = with_exec( $cfg, sub {
    $_[0]->facts_for( { id => 1, kind => 'ticket', repo => "$home", ticket => 1 } );
  } );

  is_deeply $facts,
    { board_actionable => 'yes', ticket_status => 'todo', ticket_blocked => 'no',
      ticket_claimed => '', ticket_links => 'settled' },
    'ticket_links joins the card facts and reads settled for a card with no '
    . 'link: nothing elsewhere is holding it, which is the same thing '
    . 'ticket_blocked => no says about a card nobody blocked';

  # The load-bearing half of that choice, measured rather than argued:
  # `karr needs --resolve` DROPS the tag when a link settles, so the card it
  # leaves behind has to satisfy the very precheck that was written for the
  # link -- otherwise resolving the link successfully is the thing that strands
  # the step.
  put_card( $home, id => 2, tags => ['needs:lib#1'] );
  is links_fact( $cfg, $home, 2 ), 'settled', 'a settled link says settled';

  my $resolved = card_on( $home, 2 );
  App::karr::CrossBoard->remove_needs( $resolved, [ { board => 'lib', id => 1 } ] );
  store_of($home)->save_task($resolved);
  is_deeply $resolved->tags, [], 'the resolution drops the tag off the card';
  is links_fact( $cfg, $home, 2 ), 'settled',
    'and the fact still says settled afterwards, so a precheck written for the '
    . 'link keeps holding instead of the resolution stranding the step';

  is_deeply [ sort keys %{ with_exec( $cfg, sub {
      $_[0]->facts_for( { id => 1, kind => 'ticket', repo => "$home", ticket => 99 } ) } ) } ],
    ['board_actionable'],
    'and a ticket that is not on the board measures no links either -- there '
    . 'is no card to carry any';
};

subtest 'an open far card holds the link open; the far board says what settles it' => sub {
  my $work = keepdir();
  my $home = make_board( $work, 'home' );

  # The far board's own final column, not `done`: a fleet member imported from
  # kanban-md may name it anything (#67), and a hardcoded terminal status here
  # would report a finished card as unfinished for ever.
  my $lib = make_board( $work, 'lib', statuses => [qw( backlog todo shipped archived )] );
  put_card( $lib, id => 1, status => 'todo' );
  put_card( $lib, id => 2, status => 'shipped' );

  my $cfg = fleet_config( dirs => [ "$home", "$lib" ] );

  put_card( $home, id => 1, tags => ['needs:lib#1'] );
  is links_fact( $cfg, $home, 1 ), 'open',
    'a far card that is not finished holds the fact open';

  put_card( $home, id => 2, tags => ['needs:lib#2'] );
  is links_fact( $cfg, $home, 2 ), 'settled',
    'and one in the far board\'s own terminal status settles it -- `shipped` '
    . 'is terminal on that board and is not the word `done`';

  # What the fact is for, at the grammar it is read through.
  my $chain = App::karr::Foundation::ChainStore->new(
    git => App::karr::Git->new( dir => "$home" ) );
  ok !$chain->precheck_holds( { precheck => 'ticket_links == settled' },
    { ticket_links => 'open' } ),
    'so a step waiting on the far card does not run while it is open';
  ok $chain->precheck_holds( { precheck => 'ticket_links == settled' },
    { ticket_links => 'settled' } ),
    'and does once it is finished';
};

subtest 'a far card that does not exist settles nothing' => sub {
  my $work = keepdir();
  my $home = make_board( $work, 'home' );
  my $lib  = make_board( $work, 'lib' );
  put_card( $lib, id => 1, status => 'done' );
  put_card( $home, id => 1, tags => ['needs:lib#404'] );

  my $cfg = fleet_config( dirs => [ "$home", "$lib" ] );
  my $got = links_fact( $cfg, $home, 1 );

  isnt $got, 'settled',
    'a link naming a card the far board does not have is NOT settled: '
    . 'unblocking because the ticket somebody waited for cannot be found is '
    . 'the silent wrong answer (#192 decision 5, #123 locally)';
  is $got, 'missing',
    'it is reported as missing, which is a different thing from open -- a '
    . 'card nobody can read is not a card somebody is working on';
};

subtest 'a far board this machine does not have takes the fact away' => sub {
  my $work = keepdir();
  my $home = make_board( $work, 'home' );

  # Both ways a board can fail to be here. `nowhere` exists as a real, settled
  # board -- but only in the decoy config in HOME, which nothing may read.
  my $nowhere = make_board( $DECOY, 'nowhere' );
  put_card( $nowhere, id => 1, status => 'done' );
  path($DECOY)->child( '.config', 'karr-foundation' )->mkpath;
  path($DECOY)->child( '.config', 'karr-foundation', 'config.yml' )
    ->spew_utf8( "dirs:\n  - $nowhere\n  - " . $work->child('empty') . "\n" );

  my $empty = git_init( $work->child('empty') );    # a repository, no board
  put_card( $home, id => 1, tags => ['needs:nowhere#1'] );
  put_card( $home, id => 2, tags => ['needs:empty#1'] );

  my $cfg = fleet_config( dirs => [ "$home", "$empty" ] );

  is links_fact( $cfg, $home, 1 ), undef,
    'a board name this machine cannot place leaves the fact ABSENT rather '
    . 'than guessing at it -- and the decoy in HOME that could place it is '
    . 'not read, because the configuration is the one this run was given';
  is links_fact( $cfg, $home, 2 ), undef,
    'a directory that is there and holds no board is the same answer';

  # Why absent is the safe direction, in the one place it is decided.
  my $chain = App::karr::Foundation::ChainStore->new(
    git => App::karr::Git->new( dir => "$home" ) );
  for my $expr ( 'ticket_links == settled', 'ticket_links != settled' ) {
    ok !$chain->precheck_holds( { precheck => $expr }, {} ),
      "an absent fact makes '$expr' not hold: there is no reading of != under "
      . 'which "I could not find out" may release a step';
  }
};

subtest 'several links: settled only when every one of them is' => sub {
  my $work = keepdir();
  my $home = make_board( $work, 'home' );
  my $lib  = make_board( $work, 'lib' );
  my $api  = make_board( $work, 'api' );
  put_card( $lib, id => 1, status => 'done' );
  put_card( $api, id => 1, status => 'todo' );
  put_card( $api, id => 2, status => 'done' );

  my $cfg = fleet_config( dirs => [ "$home", "$lib", "$api" ] );

  put_card( $home, id => 1, tags => [ 'needs:lib#1', 'needs:api#1' ] );
  is links_fact( $cfg, $home, 1 ), 'open',
    'one settled link and one open one is open: the card is still waiting on '
    . 'somebody, and the fact reports the first link in tag order that is not '
    . 'settled -- the same rule question_state follows for several questions';

  put_card( $home, id => 2, tags => [ 'needs:lib#1', 'needs:api#404' ] );
  is links_fact( $cfg, $home, 2 ), 'missing',
    'and a card whose only unsettled link is a card nobody can find says so';

  put_card( $home, id => 3, tags => [ 'needs:lib#1', 'needs:api#2' ] );
  is links_fact( $cfg, $home, 3 ), 'settled',
    'every link settled settles the card';

  put_card( $home, id => 4, tags => [ 'needs:api#1', 'needs:gone#1' ] );
  is links_fact( $cfg, $home, 4 ), undef,
    'and one link this machine cannot place takes the whole fact away, even '
    . 'beside a link it can read: "is anything elsewhere still holding this '
    . 'card" has no answer once one of the answers is missing';
};

subtest 'the executor measures the link and does not resolve it' => sub {
  my $work = keepdir();
  my $hub  = git_init( $work->child('hub') );
  my $home = make_board( $work, 'home' );
  my $lib  = make_board( $work, 'lib', statuses => [qw( backlog todo shipped archived )] );
  put_card( $lib, id => 1, status => 'shipped' );

  # The near card as the escalation protocol leaves it: linked AND blocked,
  # because those are two different acts. The link is the fact; the block is
  # the decision an agent took on purpose.
  put_card( $home, id => 1, tags => ['needs:lib#1'],
    block => 'needs lib#1: the API has to change first' );

  my $marker = $work->child('ran');
  App::karr::Foundation::ChainStore->new(
    git => App::karr::Git->new( dir => "$hub" ) )->write_chain( [
      { id => 1, kind => 'shell', repo => "$home", ticket => 1,
        precheck => 'ticket_links == settled',
        command  => "echo ran >> '$marker'" },
    ] );

  my $cfg = fleet_config( hub => "$hub", dirs => [ "$home", "$lib" ] );
  my ( $out ) = capture( sub {
    App::karr::Foundation->new( config => $cfg )->run('chain') } );

  ok $marker->exists,
    'the settled link released the step: a precheck reached a card in another '
    . 'repository, which is the whole of what this ticket was about';
  like $out, qr/done/, 'and the step is written back done';

  my $card = card_on( $home, 1 );
  ok $card->has_blocked,
    'the card is STILL BLOCKED afterwards: the executor measured the link and '
    . 'did not lift a flag somebody set on purpose -- unblocking unasked '
    . 'would make foundation stricter than the board it coordinates';
  is_deeply $card->tags, ['needs:lib#1'],
    'and the link is still on the card: dropping it is `karr needs --resolve`, '
    . 'a decision with a command of its own';
  is card_on( $lib, 1 )->status, 'shipped',
    'the far board is untouched as well -- it was read, not written';
};

subtest 'the far board is read where it stands, and nothing is fetched' => sub {
  my $work = keepdir();
  my $home = make_board( $work, 'home' );
  my $lib  = make_board( $work, 'lib' );
  put_card( $lib,  id => 1, status => 'done' );
  put_card( $home, id => 1, tags => ['needs:lib#1'] );

  # A remote that cannot be reached at all. Anything that tried to fetch the
  # far board would have to say so; nothing may, because pulling somebody
  # else's repository from inside a tick is transport nobody asked for, and a
  # fleet run syncs each repository as it reaches it anyway.
  system( 'git', '-C', "$lib", 'remote', 'add', 'origin',
    "$work/there-is-no-such-remote" ) == 0 or die 'git remote add';

  my $cfg = fleet_config( dirs => [ "$home", "$lib" ] );
  my @warnings;
  my $got = do {
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    links_fact( $cfg, $home, 1 );
  };

  is $got, 'settled',
    'the far card is read exactly as it stands in that working copy';
  is_deeply \@warnings, [],
    'and an unreachable remote on the far board is never noticed, because '
    . 'nothing goes near it';
  ok !$lib->child('.git')->child('FETCH_HEAD')->exists,
    'no fetch happened in the far repository';
};

subtest 'the far boards come from the configuration this run already read' => sub {
  my $work = keepdir();
  my $home = make_board( $work, 'home' );

  # Reachable only as a child of a scan: parent, which is the second of the
  # two keys karr-foundation's own discovery uses. Resolving it proves the
  # executor asks the fleet config rather than a list of its own.
  my $parent = $work->child('fleet');
  $parent->mkpath;
  my $other = make_board( $parent, 'other' );
  put_card( $other, id => 1, status => 'done' );
  put_card( $home,  id => 1, tags => ['needs:other#1'] );

  is links_fact( fleet_config( dirs => ["$home"], scan => ["$parent"] ), $home, 1 ),
    'settled',
    'a board named by scan: resolves, so dirs: and scan: mean here what they '
    . 'mean everywhere else in karr-foundation';

  is links_fact( fleet_config( dirs => ["$home"] ), $home, 1 ), undef,
    'and the same card on a machine whose config does not name that board is '
    . 'absent -- the answer follows the ONE config this run was given, which '
    . 'is why --config relocates it here too';
};

done_testing;
