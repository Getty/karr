# t/234-board-archived-and-terminal.t
#
# Ticket #234, two findings in App::karr::Cmd::Board that shared one root.
#
# 1. Archived cards were loaded, grouped, counted and rendered like any other
#    card: the footer total and the `blocked` count included them, and the
#    `archived` column showed up as soon as it was non-empty. kanban-md drops
#    them before anything happens (cmd/board.go filters with IsArchivedStatus,
#    board.Summary iterates cfg.BoardStatuses()), and karr now does too --
#    stated in the comment above the filter, because `board` is a view and not
#    the interop contract that settled the same question for `context` (#229).
#    The archive leaves all three output modes: no column, no card, no count.
#
# 2. Two places asked `$status eq 'done'` instead of the board's own terminal
#    status, so on a board imported from kanban-md whose last column is named
#    `shipped` nothing was hidden and `--done` did nothing at all.
#
# Both directions are pinned here: this file has to fail on the old code AND on
# a fix that overshoots into hiding live blocked or finished work.

use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use File::Temp qw( tempdir );
use YAML::XS qw( Dump );
use JSON::MaybeXS qw( decode_json );

use App::karr::Git;
use App::karr::BoardStore;
use App::karr::Task;
use App::karr::Cmd::Board;

sub _store {
  my ( $name, $statuses ) = @_;
  my $repo = tempdir( CLEANUP => 1 );
  system( 'git', 'init', '-q', $repo ) == 0 or BAIL_OUT('git init failed');
  system( 'git', '-C', $repo, 'config', 'user.email', 'test@example.com' ) == 0
    or BAIL_OUT('git config failed');
  system( 'git', '-C', $repo, 'config', 'user.name', 'Test User' ) == 0
    or BAIL_OUT('git config failed');
  my $git = App::karr::Git->new( dir => $repo );
  my %config = ( version => 1, board => { name => $name } );
  $config{statuses} = $statuses if $statuses;
  $git->write_ref( 'refs/karr/config', Dump( \%config ) );
  return App::karr::BoardStore->new( git => $git );
}

sub _mk {
  my ( $store, %a ) = @_;
  my $t = App::karr::Task->new(
    id       => $a{id},
    title    => $a{title},
    status   => $a{status},
    priority => $a{priority} // 'medium',
    class    => 'standard',
  );
  $t->claimed_by( $a{claimed_by} ) if $a{claimed_by};
  # Through block(), not blocked(): the boolean-plus-reason shape is the one
  # every reader relies on (ticket #58).
  $t->block( $a{blocked} )         if $a{blocked};
  $store->save_task($t);
  return $t;
}

sub _render {
  my ( $store, %opt ) = @_;
  local $ENV{NO_COLOR} = 1;
  my $cmd = App::karr::Cmd::Board->new( store => $store, %opt );
  my $buf = '';
  {
    local *STDOUT;
    open STDOUT, '>', \$buf or die $!;
    $cmd->execute( [], [] );
  }
  return $buf;
}

# A default board carrying two archived cards, one of them blocked and
# claimed, plus live work that must keep counting.
sub _default_board {
  my $store = _store('Archive Board');
  _mk( $store, id => 1, title => 'Open one',      status => 'todo' );
  _mk( $store, id => 2, title => 'Open two',      status => 'todo', blocked => 'waiting on review' );
  _mk( $store, id => 3, title => 'Under way',     status => 'in-progress', claimed_by => 'alice' );
  _mk( $store, id => 4, title => 'Shipped it',    status => 'done', claimed_by => 'bob' );
  _mk( $store, id => 5, title => 'Filed away',    status => 'archived' );
  _mk( $store, id => 6, title => 'Filed blocked', status => 'archived',
       blocked => 'stale', claimed_by => 'carol' );
  return $store;
}

subtest 'archived cards leave the default rendering and every footer count' => sub {
  my $out = _render( _default_board() );

  unlike $out, qr/^## Archived$/m,  'no Archived section even though two cards are archived';
  unlike $out, qr/Filed away/,      'archived card title is not rendered';
  unlike $out, qr/Filed blocked/,   'archived blocked card title is not rendered either';

  like $out, qr/^- 1 \| Open one$/m,   'live card still renders';
  like $out, qr/^- 2 \| Open two \| blocked:waiting on review$/m, 'live blocked card still renders';

  # 4 cards on the board (1,2,3,4), not 6: the archive is not on it.
  like $out, qr/^4 tasks \(1 done hidden\)/m,
    'footer totals the board without its archive, done still counted and announced';
  # 1 blocked, not 2 -- and not 0: a live blocked card must still count.
  like $out, qr/\b1 blocked\b/,  'blocked counts the live card only';
  # alice only: bob holds a claim on a finished card, carol on an archived one.
  like $out, qr/\b1 claimed\b/,  'claimed counts the live claim only';
};

subtest '--compact and --json drop the archived column, not the done one' => sub {
  my $store = _default_board();

  my $compact = _render( $store, compact => 1 );
  unlike $compact, qr/^archived\(/m, 'no archived line in --compact';
  like $compact, qr/^done\(1\): 4$/m, 'done column still listed in --compact';
  like $compact, qr/^todo\(2\): 1,2$/m, 'live column unchanged';

  my $json = decode_json( _render( $store, json => 1 ) );
  is $json->{total}, 4, 'json total leaves the archive out';
  my @columns = map { $_->{status} } @{ $json->{columns} };
  is scalar( grep { $_ eq 'archived' } @columns ), 0, 'no archived column in json';
  ok scalar( grep { $_ eq 'done' } @columns ), 'done column is still there';
  unlike _render( $store, json => 1 ), qr/Filed away|Filed blocked/,
    'no archived payload anywhere in the json';

  my $json_done = decode_json( _render( $store, json => 1, done => 1 ) );
  is $json_done->{total}, 4, '--done does not bring the archive back into the total';
  is scalar( grep { $_->{status} eq 'archived' } @{ $json_done->{columns} } ), 0,
    '--done does not bring the archived column back';
};

# A board imported from kanban-md whose final column is named `shipped`.
sub _shipped_board {
  my $store = _store( 'Imported Board', [
    'backlog',
    'todo',
    { name => 'in-progress', require_claim => 1 },
    { name => 'review',      require_claim => 1 },
    'shipped',
    'archived',
  ] );
  _mk( $store, id => 1, title => 'Still open', status => 'todo' );
  _mk( $store, id => 2, title => 'Went out',   status => 'shipped', claimed_by => 'alice' );
  _mk( $store, id => 3, title => 'Old news',   status => 'archived' );
  return $store;
}

subtest 'a board ending in `shipped` hides that column and --done reveals it' => sub {
  my $store = _shipped_board();

  my $out = _render($store);
  unlike $out, qr/^## Shipped$/m, 'the board final column is hidden by default';
  unlike $out, qr/Went out/,      'its card is not rendered';
  unlike $out, qr/^## Archived$/m, 'archived stays out of an imported board too';
  like $out, qr/^- 1 \| Still open$/m, 'open work renders';
  like $out, qr/^2 tasks \(1 shipped hidden\)/m,
    'footer names the column it withheld and counts the board without its archive';

  my $done = _render( $store, done => 1 );
  like $done, qr/^## Shipped$/m,          '--done renders the final column';
  like $done, qr/^- 2 \| Went out$/m,     '--done renders its card';
  unlike $done, qr/hidden/,               '--done drops the hidden-count hint';
  unlike $done, qr/^## Archived$/m,       '--done still leaves the archive out';
};

subtest 'json on a `shipped` board hides and reveals the same column' => sub {
  my $store = _shipped_board();

  my $json = decode_json( _render( $store, json => 1 ) );
  my ($shipped) = grep { $_->{status} eq 'shipped' } @{ $json->{columns} };
  ok $shipped, 'shipped column is present';
  is $shipped->{count}, 1, 'with its real count';
  is_deeply $shipped->{tasks}, [], 'but no payload without --done';
  is $json->{total}, 2, 'total leaves the archived card out';

  my $json_done = decode_json( _render( $store, json => 1, done => 1 ) );
  my ($revealed) = grep { $_->{status} eq 'shipped' } @{ $json_done->{columns} };
  is scalar @{ $revealed->{tasks} }, 1, '--done fills the final column in';
  is $revealed->{tasks}[0]{title}, 'Went out', 'with the card that is in it';
};

subtest 'a card filed as archived counts nowhere, even with no archived column' => sub {
  # kanban-md's IsArchivedStatus also requires the board to configure the
  # column; karr answers that question once, in Config, and `archived` is
  # archived either way -- the same deliberate divergence #229 records.
  my $store = _store( 'No Archive Column', [ 'backlog', 'todo', 'done' ] );
  _mk( $store, id => 1, title => 'Live card',  status => 'todo' );
  _mk( $store, id => 2, title => 'Stray card', status => 'archived', blocked => 'why' );

  my $out = _render($store);
  unlike $out, qr/Stray card/, 'the stray archived card renders nowhere';
  like $out, qr/^1 tasks$/m,   'and is not in the total';
  unlike $out, qr/blocked/,    'nor in the blocked count';
};

done_testing;
