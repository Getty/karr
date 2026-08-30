use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use TestKarr qw( run_karr );
use File::Temp qw( tempdir );
use File::Path qw( make_path );
use App::karr::Encoding qw( json_decode );

# Ticket #253: `karr log` carried a local no-repository answer that printed to
# STDOUT ahead of the `if ($self->json)` branch:
#
#     unless ($git->is_repo) {
#         print "Not a git repository. No log available.\n";
#         return;
#     }
#
# It was unreachable -- $self->git is built from git_root, and git_root refuses
# a non-repository itself -- and it was removed rather than fixed. Which is
# exactly why this file pins the contract instead of the branch: the four
# situations below are every way `karr log` can answer with nothing to show,
# and in each of them a --json caller must be able to decode STDOUT in one
# piece, or find it empty because the command failed. Any future answer written
# for an empty situation has to keep that true (#248: STDOUT carries the
# result, dialogue and notes go to STDERR), and re-liveing the removed branch
# by dropping require_local_board would break the third subtest here.

# In-process runner (t/lib/TestKarr.pm): same ($cwd, @argv) signature and
# { exit, stdout, stderr } return as the open3 helper this file used to carry,
# dispatched through the shared App::karr::Dispatch path. KARR_TEST_SUBPROC=1
# restores the old open3 path.
sub _run_karr { return run_karr(@_) }

sub _git_repo {
    my $repo = tempdir( CLEANUP => 1 );
    system( 'git', 'init', '-q', $repo ) == 0 or die 'git init failed';
    system( 'git', '-C', $repo, 'config', 'user.email', 'test@example.com' ) == 0
        or die 'git config failed';
    system( 'git', '-C', $repo, 'config', 'user.name', 'Test User' ) == 0
        or die 'git config failed';
    return $repo;
}

# What a JSON consumer does: decode the stream, not a line picked out of it.
sub _decodes {
    my ( $text, $label ) = @_;
    my $data = eval { json_decode($text) };
    ok( defined $data, $label ) or diag "stdout was: $text";
    return $data;
}

subtest 'a board with no activity answers an empty JSON array (#253)' => sub {
    my $repo = _git_repo();
    is( _run_karr( $repo, 'init', '--name', 'Quiet Board' )->{exit},
        0, 'setup: karr init exits 0' );

    my $rv = _run_karr( $repo, 'log', '--json' );
    is( $rv->{exit}, 0, 'an empty log is a successful read, not a failure' )
        or diag $rv->{stderr};

    my $data = _decodes( $rv->{stdout}, 'the whole stream decodes' );
    is( ref $data, 'ARRAY', '...as an array' );
    is( scalar @$data, 0, '...with no entries in it' );

    # The plain form says it in words; --json must not borrow that sentence.
    my $plain = _run_karr( $repo, 'log' );
    like( $plain->{stdout}, qr/\ANo log entries\.\s*\z/,
        'the plain form is the one that says so in words' );
    unlike( $rv->{stdout}, qr/No log entries/,
        'and none of it leaks into the JSON stream' );
};

subtest 'a half-initialized board notes on STDERR and decodes on STDOUT (#253)' => sub {
    my $repo = _git_repo();
    is( _run_karr( $repo, 'init', '--name', 'Half Board' )->{exit},
        0, 'setup: karr init exits 0' );
    is( _run_karr( $repo, 'create', '--title', 'Seed' )->{exit},
        0, 'setup: karr create exits 0' );

    # The state #135 reads rather than refuses: task refs are there, the config
    # ref is not, so require_local_board prints a note and carries on.
    system( 'git', '-C', $repo, 'update-ref', '-d', 'refs/karr/config' ) == 0
        or die 'update-ref -d failed';

    my $rv = _run_karr( $repo, 'log', '--json' );
    is( $rv->{exit}, 0, 'the half board still reads' ) or diag $rv->{stderr};
    like( $rv->{stderr}, qr/half-initialized/,
        'the note about it is on STDERR' );

    my $data = _decodes( $rv->{stdout},
        'and STDOUT decodes as a whole, note and all kept off it' );
    is( ref $data, 'ARRAY', '...as an array' );
    ok( scalar @$data >= 1, '...carrying the activity that is there' );
};

subtest 'no board and no repository put nothing on STDOUT (#253)' => sub {
    # The two situations the removed branch was about. Both refuse before any
    # ref is read, so the honest --json answer is an empty stream and exit 1
    # (#135) -- not a sentence a decoder would choke on.
    my $no_board = _git_repo();

    my $rv = _run_karr( $no_board, 'log', '--json' );
    is( $rv->{exit}, 1, 'a repository with no board exits 1' );
    is( $rv->{stdout}, '', '...and writes nothing at all to STDOUT' );
    like( $rv->{stderr}, qr/\QNo karr board in this repository\E/,
        '...with the refusal on STDERR' );

    my $no_repo = tempdir( CLEANUP => 1 );
    make_path("$no_repo/plain");

    my $out = _run_karr( "$no_repo/plain", 'log', '--json' );
    is( $out->{exit}, 1, 'a directory that is no repository exits 1' );
    is( $out->{stdout}, '', '...and writes nothing at all to STDOUT' );
    like( $out->{stderr}, qr/\QNot a git repository. karr requires Git.\E/,
        '...with git_root\'s refusal on STDERR, which is what answers here' );
    unlike( $out->{stdout}, qr/No log available/,
        'the removed branch is gone and did not come back to STDOUT' );
};

subtest 'a filter that matches nothing decodes too (#253)' => sub {
    my $repo = _git_repo();
    is( _run_karr( $repo, 'init', '--name', 'Filter Board' )->{exit},
        0, 'setup: karr init exits 0' );
    is( _run_karr( $repo, 'create', '--title', 'Seed' )->{exit},
        0, 'setup: karr create exits 0' );

    # The fourth empty situation, and the only one reached after the refs have
    # been read: entries exist, the filter keeps none of them.
    for my $argv ( [ 'log', '--json', '--task', '999' ],
        [ 'log', '--json', '--agent', 'nobody-at-all' ] )
    {
        my $label = join ' ', @$argv;
        my $rv = _run_karr( $repo, @$argv );
        is( $rv->{exit}, 0, "karr $label exits 0" ) or diag $rv->{stderr};
        my $data = _decodes( $rv->{stdout}, "karr $label decodes as a whole" );
        is_deeply( $data, [], "karr $label answers an empty array" );
    }
};

done_testing;
