# t/251-pick-compact.t
#
# Ticket #251: App::karr::Cmd::Pick composes App::karr::Role::Output, which
# declares --compact next to --json, and then never read the option. So
#
#   karr pick --claim probe1
#   karr pick --claim probe2 --compact
#
# came out character-identical, three parts each: the assignment line, the
# "Status | Priority | Class" detail line, and the body. An accepted option
# that changes nothing is the failure #225 and #226 refused to leave standing
# -- output that looks like an answer while disobeying the flag.
#
# The resolution follows the reference rather than inventing a meaning:
# kanban-md spends a flag of its own on exactly this cut (`pick --no-body`,
# "suppress full task details after pick", cmd/pick.go:104) -- confirmation
# line, then return, before the detail block. karr already had the option, so
# it needed no second flag.
#
# What --compact deliberately does NOT touch: --json (the JSON branch returns
# before the plaintext block, as noBody sits after the JSON check over there),
# and the dependency warnings, which are STDERR and answer to --quiet.
#
# Everything here runs against throwaway repositories under File::Temp; the
# developer's own board is never touched.
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use TestKarr ();
use File::Temp qw( tempdir );
use JSON::MaybeXS qw( decode_json );
use YAML::XS qw( Dump );

use App::karr::Git;
use App::karr::BoardStore;
use App::karr::Task;
use App::karr::Cmd::Pick;

sub init_board {
  my $repo = tempdir( CLEANUP => 1 );
  system( 'git', 'init', '-q', $repo ) == 0 or BAIL_OUT('git init failed');
  system( 'git', '-C', $repo, 'config', 'user.email', 'test@example.com' ) == 0
    or BAIL_OUT('git config failed');
  system( 'git', '-C', $repo, 'config', 'user.name', 'Test User' ) == 0
    or BAIL_OUT('git config failed');

  my $git = App::karr::Git->new( dir => $repo );
  $git->write_ref( 'refs/karr/config',
    Dump( { version => 1, board => { name => 'Compact' } } ) );
  $git->write_ref( 'refs/karr/meta/next-id', "2\n" );
  return ( App::karr::BoardStore->new( git => $git ), $repo );
}

sub one_card_board {
  my ($store) = @_;
  $store->save_task(
    App::karr::Task->new(
      id       => 1,
      title    => 'Open work',
      status   => 'todo',
      priority => 'high',
      class    => 'standard',
      body     => 'A body long enough to be missed when it goes away.',
    )
  );
  return $store;
}

sub run_execute {
  my ( $cmd, @args ) = @_;
  my $out = '';
  my $err = do {
    local $@;
    eval {
      local *STDOUT;
      open STDOUT, '>', \$out or die $!;
      $cmd->execute( \@args, [] );
    };
    $@;
  };
  return ( $err, $out );
}

# In-process runner (t/lib/TestKarr.pm), wrapped to keep this file's own
# NO_COLOR/KARR_NO_AUTO_FETCH env setup. KARR_TEST_SUBPROC=1 restores the old
# open3 path.
sub run_karr {
  my ( $cwd, @argv ) = @_;
  local $ENV{NO_COLOR}           = 1;
  local $ENV{KARR_NO_AUTO_FETCH} = 1;
  return TestKarr::run_karr( $cwd, @argv );
}

subtest 'the default rendering is unchanged: assignment, detail, body' => sub {
  my ($store) = init_board();
  one_card_board($store);

  my ( $err, $out ) =
    run_execute( App::karr::Cmd::Pick->new( store => $store, claim => 'bob' ) );

  is( $err, '', 'pick does not die' ) or diag("died with: $err");
  is( $out,
      "Picked task 1: Open work (claimed by bob)\n"
    . "Status: todo | Priority: high | Class: standard\n"
    . "\nA body long enough to be missed when it goes away.\n",
    'all three parts are printed without --compact' )
    or diag("got:\n$out");
};

subtest '--compact prints the assignment and stops' => sub {
  my ($store) = init_board();
  one_card_board($store);

  my ( $err, $out ) = run_execute(
    App::karr::Cmd::Pick->new( store => $store, claim => 'bob', compact => 1 ) );

  is( $err, '', 'pick does not die' ) or diag("died with: $err");
  is( $out, "Picked task 1: Open work (claimed by bob)\n",
    'the assignment line is the whole of the output' )
    or diag("got:\n$out");

  # Named separately from the is() above, because these two are the ticket:
  # the detail line and the body are what --compact is asked to withhold.
  unlike( $out, qr/^Status: /m, 'no Status | Priority | Class line' );
  unlike( $out, qr/A body long enough/, 'no body' );
};

subtest 'the two renderings differ -- the ticket measured them identical' => sub {
  my ($plain_store) = init_board();
  one_card_board($plain_store);
  my ( undef, $plain ) = run_execute(
    App::karr::Cmd::Pick->new( store => $plain_store, claim => 'bob' ) );

  my ($compact_store) = init_board();
  one_card_board($compact_store);
  my ( undef, $compact ) = run_execute(
    App::karr::Cmd::Pick->new(
      store => $compact_store, claim => 'bob', compact => 1 ) );

  # Same board, same card, same claim: before the fix these were equal strings.
  isnt( $compact, $plain, 'pick --compact is not pick' );
  ok( length($compact) < length($plain), 'and it is the shorter of the two' );
  like( $plain, qr/\A\Q$compact\E/,
    'compact is the head of the default rendering, not a different sentence' );
};

subtest '--compact does not reach --json' => sub {
  my ($store) = init_board();
  one_card_board($store);

  my ( $err, $out ) = run_execute(
    App::karr::Cmd::Pick->new(
      store => $store, claim => 'bob', json => 1, compact => 1 ) );

  is( $err, '', 'pick does not die' ) or diag("died with: $err");
  my $data = eval { decode_json($out) };
  ok( $data, 'stdout still decodes as JSON' )
    or diag( "decode failed: $@\ngot:\n$out" );

  # The full card, not a compacted one: --compact shapes the plaintext half.
  is( $data->{id},       1,           'the payload carries the task id' );
  is( $data->{status},   'todo',      'and the status the detail line would show' );
  is( $data->{priority}, 'high',      'and the priority' );
  is( $data->{class},    'standard',  'and the class' );
  is( $data->{body}, 'A body long enough to be missed when it goes away.',
    'and the body --compact withholds from the plaintext rendering' );
};

subtest 'the empty path is one line either way' => sub {
  my ($store) = init_board();

  my ( $err, $out ) = run_execute(
    App::karr::Cmd::Pick->new( store => $store, claim => 'bob', compact => 1 ) );

  is( $err, '', 'pick does not die' ) or diag("died with: $err");
  is( $out, "No available tasks to pick.\n",
    'nothing to compact, so nothing changes' );
};

subtest 'the flag travels from argv, not just from the constructor' => sub {
  my ( $store, $repo ) = init_board();
  $store->save_task(
    App::karr::Task->new(
      id       => $_,
      title    => "Card $_",
      status   => 'todo',
      priority => 'high',
      class    => 'standard',
      body     => "Body of card $_.",
    )
  ) for 1, 2;

  my $plain = run_karr( $repo, 'pick', '--claim', 'probe1' );
  is( $plain->{exit}, 0, 'plain pick exits 0' ) or diag $plain->{stderr};
  like( $plain->{stdout}, qr/^Picked task 1: Card 1 \(claimed by probe1\)$/m,
    'plain pick takes card 1' );
  like( $plain->{stdout}, qr/^Status: todo \| Priority: high \| Class: standard$/m,
    'and prints the detail line' );

  my $compact = run_karr( $repo, 'pick', '--claim', 'probe2', '--compact' );
  is( $compact->{exit}, 0, 'pick --compact exits 0' ) or diag $compact->{stderr};
  is( $compact->{stdout}, "Picked task 2: Card 2 (claimed by probe2)\n",
    'and prints one line only' )
    or diag( "got:\n" . $compact->{stdout} );
};

done_testing;
