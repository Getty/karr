use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use File::Temp qw( tempdir );
use Cwd qw( abs_path getcwd );
use IPC::Open3 qw( open3 );
use Symbol qw( gensym );
use JSON::MaybeXS qw( decode_json );

# Ticket #135: board, list, show, log and context called neither sync_before
# nor require_board, so they rendered the code defaults over an empty task list
# and a repository holding no board printed exactly what a board holding no
# cards prints -- down to the byte, once the board is called "Kanban Board".
# `git clone` does not fetch refs/karr/*, so that is the normal state of every
# fresh clone, where the user's tickets are all still on the remote. A user who
# trusted the output concluded the tickets were gone.
#
# The fix keeps the reads offline (no sync round trip in front of every `karr
# show`) and makes them ask what require_board asks after its pull, through
# App::karr::Role::BoardDiscovery::require_local_board:
#
#   nothing under refs/karr/  -> refuse, exit 1, say so, and where there is a
#                                remote lead with `karr sync` rather than
#                                `karr init` -- the board is unfetched, not
#                                absent, and init would start a second one.
#   half-board (#133)         -> read it; the tasks are demonstrably there.
#                                The note that the config ref is missing goes
#                                to STDERR so --json stays parsable.
#   initialized, no tasks     -> unchanged: an empty board is a real answer.

my $ROOT = abs_path('.');
my $BIN  = "$ROOT/bin/karr";

# Every read command in the ticket, in both renderings, plus the bare `karr`
# default summary (lib/App/karr.pm), which wraps Cmd::Board.
my @READ_ARGV = (
    ['board'], [ 'board', '--json' ],
    ['list'],  [ 'list',  '--json' ],
    ['show'],  [ 'show',  '--json' ],
    ['log'],   [ 'log',   '--json' ],
    ['context'], [ 'context', '--json' ],
    [],
);

sub _run_karr {
    my ( $cwd, @argv ) = @_;
    my $old = getcwd();
    chdir $cwd or die "chdir $cwd: $!";

    my $stderr = gensym;
    my $pid = open3( undef, my $stdout_fh, $stderr, $^X, "-I$ROOT/lib", $BIN, @argv );
    my $stdout      = do { local $/; <$stdout_fh> };
    my $stderr_text = do { local $/; <$stderr> };
    waitpid( $pid, 0 );
    my $exit = $? >> 8;

    chdir $old or die "chdir $old: $!";
    return {
        exit   => $exit,
        stdout => defined $stdout      ? $stdout      : '',
        stderr => defined $stderr_text ? $stderr_text : '',
    };
}

sub _label { my @a = @_; return @a ? "karr @a" : 'karr (bare)' }

sub _repo {
    my $repo = tempdir( CLEANUP => 1 );
    system( 'git', 'init', '-q', $repo ) == 0 or BAIL_OUT('git init failed');
    system( 'git', '-C', $repo, 'config', 'user.email', 'test@example.com' ) == 0
        or BAIL_OUT('git config failed');
    system( 'git', '-C', $repo, 'config', 'user.name', 'Test User' ) == 0
        or BAIL_OUT('git config failed');
    return $repo;
}

sub _board_repo {
    my ( $name, @titles ) = @_;
    my $repo = _repo();
    _run_karr( $repo, 'init', '--name', $name )->{exit} == 0
        or BAIL_OUT('karr init failed');
    for my $title (@titles) {
        _run_karr( $repo, 'create', $title )->{exit} == 0
            or BAIL_OUT("karr create failed for $title");
    }
    return $repo;
}

subtest 'a repository with no board refuses to answer as if it were empty' => sub {
    my $repo = _repo();

    for my $argv (@READ_ARGV) {
        my $label = _label(@$argv);
        my $rv    = _run_karr( $repo, @$argv );

        is( $rv->{exit}, 1, "$label exits 1 where there is no board" );
        # Nothing on stdout at all: a --json consumer gets no payload to
        # mistake for a board, and a human gets no board-shaped output either.
        is( $rv->{stdout}, '', "$label prints nothing on stdout" );
        like( $rv->{stderr}, qr{nothing is stored under refs/karr/},
            "$label says what was actually looked at" );
        like( $rv->{stderr}, qr{not an empty board},
            "$label denies the reading that cost the tickets" );
        like( $rv->{stderr}, qr{karr init}, "$label says how to get a board" );
        # No remote here, so `karr sync` has nothing to fetch from and must not
        # be offered as the first thing to try.
        unlike( $rv->{stderr}, qr{karr sync},
            "$label does not send a remote-less repository to sync" );
    }
};

subtest 'an initialized board with no tasks still reads as an empty board' => sub {
    # The other half of the distinction, and the assertion that fails if anyone
    # ever "fixes" #135 by refusing whenever the task list comes back empty.
    my $repo = _board_repo('Empty Board');

    my $board = _run_karr( $repo, 'board' );
    is( $board->{exit}, 0, 'karr board still renders an empty board' );
    like( $board->{stdout}, qr{# Empty Board}, 'with the board name it was given' );
    like( $board->{stdout}, qr{^0 tasks}m, 'and its honest zero' );

    my $json = _run_karr( $repo, 'board', '--json' );
    is( $json->{exit}, 0, 'karr board --json too' );
    my $data = eval { decode_json( $json->{stdout} ) };
    is( $data->{total}, 0, 'reporting a total of 0' ) or diag $json->{stderr};
    is( $data->{name}, 'Empty Board', 'under the real board name' );

    is( _run_karr( $repo, 'list' )->{exit},    0, 'karr list works' );
    is( _run_karr( $repo, 'list', '--json' )->{stdout}, "[]\n", 'and answers []' );
    like( _run_karr( $repo, 'show' )->{stdout}, qr{No tasks found}, 'karr show works' );
    like( _run_karr( $repo, 'log' )->{stdout},  qr{No log entries}, 'karr log works' );
    like( _run_karr( $repo, 'context' )->{stdout}, qr{BEGIN kanban-md context},
        'karr context works' );
};

subtest 'a fresh clone is told the board is unfetched, not missing' => sub {
    my $work   = tempdir( CLEANUP => 1 );
    my $origin = "$work/origin.git";
    system( 'git', 'init', '-q', '--bare', $origin ) == 0
        or BAIL_OUT('git init --bare failed');

    my $source = _board_repo( 'Remote Board', 'a ticket that exists' );
    system( 'git', '-C', $source, 'remote', 'add', 'origin', $origin ) == 0
        or BAIL_OUT('git remote add failed');
    is( _run_karr( $source, 'sync' )->{exit}, 0, 'setup: the board reaches the remote' );

    my $clone = "$work/clone";
    system("git clone -q '$origin' '$clone' 2>/dev/null");
    system( 'git', '-C', $clone, 'config', 'user.email', 'test@example.com' );
    system( 'git', '-C', $clone, 'config', 'user.name',  'Test User' );

    my @refs = `git -C '$clone' for-each-ref --format='%(refname)' 'refs/karr/'`;
    is( scalar @refs, 0, 'setup: git clone fetched none of refs/karr/*' );

    for my $argv (@READ_ARGV) {
        my $label = _label(@$argv);
        my $rv    = _run_karr( $clone, @$argv );

        is( $rv->{exit}, 1, "$label refuses in a fresh clone" );
        is( $rv->{stdout}, '', "$label prints nothing on stdout" );
        like( $rv->{stderr}, qr{git clone.*does not fetch}s,
            "$label explains why a clone starts out board-less" );
        like( $rv->{stderr}, qr{karr sync}, "$label offers the fetch first" );
        # init stays in the message, but after sync: it is the answer for a
        # repository that never had a board, not for one whose board is on the
        # remote -- running it here would start a second, empty board.
        like( $rv->{stderr}, qr{karr sync.*karr init}s,
            "$label puts sync before init, not the other way round" );
    }

    is( _run_karr( $clone, 'sync' )->{exit}, 0, 'the advice runs' );
    my $after = _run_karr( $clone, 'board' );
    is( $after->{exit}, 0, 'and the board reads afterwards' ) or diag $after->{stderr};
    like( $after->{stdout}, qr{# Remote Board}, 'as the board it always was' );
    like( $after->{stdout}, qr{a ticket that exists}, 'with the ticket that was never gone' );
};

subtest 'a half-board is read, not refused' => sub {
    # #133's state: task refs present, refs/karr/config gone. require_board
    # refuses a write here; a read must not, because refusing would hide tasks
    # that are demonstrably there -- the exact mistake that ticket was about.
    my $repo = _board_repo( 'Doomed', 'seeded 1', 'seeded 2' );
    system( 'git', '-C', $repo, 'update-ref', '-d', 'refs/karr/config' ) == 0
        or BAIL_OUT('update-ref -d failed');
    system( 'git', '-C', $repo, 'update-ref', '-d', 'refs/karr/meta/encoding' ) == 0
        or BAIL_OUT('update-ref -d failed');

    my $list = _run_karr( $repo, 'list' );
    is( $list->{exit}, 0, 'karr list still reads a half-board' ) or diag $list->{stderr};
    like( $list->{stdout}, qr{seeded 1}, 'and shows the tasks that are there' );
    like( $list->{stdout}, qr{seeded 2}, 'both of them' );
    like( $list->{stderr}, qr{half-initialized}, 'while naming the state on STDERR' );
    like( $list->{stderr}, qr{refs/karr/config is missing}, 'and which ref is gone' );
    like( $list->{stderr}, qr{karr init}, 'and how to complete it' );

    my $json = _run_karr( $repo, 'board', '--json' );
    is( $json->{exit}, 0, 'karr board --json too' );
    # The note is on STDERR precisely so this still decodes.
    my $data = eval { decode_json( $json->{stdout} ) };
    is( $data->{total}, 2, 'stdout stays parsable JSON, with both tasks in it' )
        or diag $json->{stdout};
    like( $json->{stderr}, qr{half-initialized}, 'and the note reaches STDERR under --json' );
};

subtest 'reads stay offline: an unreachable remote does not stop them' => sub {
    # The other constraint #135 has to respect. Refusing to render a board that
    # is not there must not turn into pulling before every read: `karr show` is
    # on the hot path for agents, and a stale read is recoverable where a stale
    # write is not. A remote that cannot be reached is the cheapest proof that
    # no read command touches the network.
    my $work = tempdir( CLEANUP => 1 );
    my $repo = _board_repo( 'Offline Board', 'local only' );
    system( 'git', '-C', $repo, 'remote', 'add', 'origin', "$work/nowhere.git" ) == 0
        or BAIL_OUT('git remote add failed');

    for my $argv ( ['board'], ['list'], ['show'], ['log'], ['context'], [] ) {
        my $rv = _run_karr( $repo, @$argv );
        is( $rv->{exit}, 0, _label(@$argv) . ' reads without reaching the remote' )
            or diag $rv->{stderr};
    }
    like( _run_karr( $repo, 'list' )->{stdout}, qr{local only},
        'and answers from the local refs' );
};

done_testing;
