use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use TestKarr qw( run_karr );
use File::Temp qw( tempdir );

# Exit-code contract matrix for ticket #22 / ADR 0002
# (docs/adr/0002-exit-code-contract.md).
#
#   0  success (including no-op successes like re-archiving)
#   1  runtime failure: not found, board missing, not a git repo, a Git/sync
#      failure, a destructive command refused for want of --yes
#   2  usage error: unknown command, unknown option, invalid option value,
#      surplus or missing positional argument
#
# This pins the *exact* code, unlike the sibling CLI error tests (t/41, t/43,
# t/44, t/45, t/46) which mostly assert only a non-zero exit. Two mechanisms
# back the contract and both are exercised here:
#   - the central handler in bin/karr classifies uncaught command-body dies
#     into 1 (runtime) vs 2 (usage, by a stable leading marker);
#   - App::karr::Role::ExitCodes (and the root's _print_help) remap
#     MooX::Options option-parse errors from 1 to 2.

# In-process runner (t/lib/TestKarr.pm): same ($cwd, @argv) signature and
# { exit, stdout, stderr } return as the open3 helper this file used to carry,
# dispatched through the shared App::karr::Dispatch path. KARR_TEST_SUBPROC=1
# restores the old open3 path.
sub _run_karr { return run_karr(@_) }

sub _git_repo {
    my $repo = tempdir( CLEANUP => 1 );
    system( 'git', 'init', '-q', $repo ) == 0 or die "git init failed";
    system( 'git', '-C', $repo, 'config', 'user.email', 'test@example.com' );
    system( 'git', '-C', $repo, 'config', 'user.name',  'Test User' );
    return $repo;
}

# A git repo with an initialized board and one seeded task (id 1).
sub _board_repo {
    my $repo = _git_repo();
    is( _run_karr( $repo, 'init', '--name', 'Contract Board' )->{exit},
        0, 'setup: karr init exits 0' );
    is( _run_karr( $repo, 'create', '--title', 'Sentinel', '--status', 'todo' )->{exit},
        0, 'setup: karr create exits 0' );
    return $repo;
}

# ------------------------------------------------------------------ exit 0

subtest 'success paths exit 0' => sub {
    my $repo = _board_repo();

    is( _run_karr( $repo, 'board' )->{exit},   0, 'board exits 0' );
    is( _run_karr( $repo, 'list' )->{exit},    0, 'list exits 0' );
    is( _run_karr( $repo, 'show', 1 )->{exit}, 0, 'show 1 exits 0' );

    # A no-op success: re-archiving an already-archived task stays 0 (ADR 0002
    # calls this out explicitly).
    is( _run_karr( $repo, 'archive', 1 )->{exit}, 0, 'first archive exits 0' );
    my $again = _run_karr( $repo, 'archive', 1 );
    is( $again->{exit}, 0, 're-archiving an archived task is a no-op success (0)' );
    like( $again->{stdout}, qr/already archived/i, 'and says so on stdout' );
};

subtest 'help requests exit 0 (not a usage error)' => sub {
    my $repo = _board_repo();

    is( _run_karr( $repo, '--help' )->{exit}, 0, 'root --help exits 0' );
    is( _run_karr( $repo, '-h' )->{exit},     0, 'root -h exits 0' );
    is( _run_karr( $repo, 'show', '--help' )->{exit},
        0, 'subcommand --help exits 0' );
};

# ------------------------------------------------------------------ exit 1

subtest 'runtime failures exit 1' => sub {
    my $repo = _board_repo();

    my $nf = _run_karr( $repo, 'show', 99 );
    is( $nf->{exit}, 1, 'not found exits 1' );
    like( $nf->{stderr}, qr/\b99\b/, 'not-found stderr names the id' );

    # Board missing: a git repo with no refs/karr/* board.
    my $empty = _git_repo();
    my $bm = _run_karr( $empty, 'show', 1 );
    is( $bm->{exit}, 1, 'board missing exits 1' );

    # A destructive command refused for want of --yes is a runtime refusal, not
    # a usage error: the invocation was well-formed, karr just declines to act.
    my $imp = _run_karr( $repo, 'import' );
    is( $imp->{exit}, 1, 'import without --yes exits 1 (runtime refusal)' );
    like( $imp->{stderr}, qr/--yes/, 'import refusal stderr mentions --yes' );
};

subtest 'a Git/sync failure exits 1' => sub {
    my $repo = _board_repo();

    # A remote that cannot possibly be reached, offline and deterministic.
    system( 'git', '-C', $repo, 'remote', 'add', 'origin', '/nonexistent/karr-bogus.git' );

    my $rv = _run_karr( $repo, 'sync' );
    is( $rv->{exit}, 1, 'karr sync against a broken remote exits 1' );
};

subtest 'not a git repository exits 1' => sub {
    # A directory that is not inside any git repository. tempdir lives under the
    # system temp dir, whose ancestors are not git repos, so discovery fails.
    my $bare = tempdir( CLEANUP => 1 );
    my $rv = _run_karr( $bare, 'list' );
    is( $rv->{exit}, 1, 'list outside a git repo exits 1' );
    like( $rv->{stderr}, qr/not a git repository/i, 'stderr explains why' );
};

# ------------------------------------------------------------------ exit 2

subtest 'usage errors exit 2' => sub {
    my $repo = _board_repo();

    my $uc = _run_karr( $repo, 'definitely-not-a-command' );
    is( $uc->{exit}, 2, 'unknown command exits 2' );
    like( $uc->{stderr}, qr/\QUnknown command\E/, 'unknown-command stderr' );

    my $surplus = _run_karr( $repo, 'show', 1, 2, 3 );
    is( $surplus->{exit}, 2, 'surplus positional exits 2' );

    # Missing required positional: `move` with no id dies "Usage: karr move ..."
    my $missing = _run_karr( $repo, 'move' );
    is( $missing->{exit}, 2, 'missing required positional exits 2' );
    like( $missing->{stderr}, qr/^Usage:/m, 'missing-positional stderr is a Usage: line' );

    # A "Usage:" die from a board-less command too.
    my $gr = _run_karr( $repo, 'get-refs' );
    is( $gr->{exit}, 2, 'get-refs with no ref exits 2' );
};

subtest 'unknown option exits 2 on every command shape' => sub {
    my $repo = _board_repo();

    # Root option parsing.
    is( _run_karr( $repo, '--totally-bogus' )->{exit},
        2, 'unknown option on the root exits 2' );

    # A subcommand that inherits ExitCodes via BoardDiscovery.
    is( _run_karr( $repo, 'list', '--totally-bogus' )->{exit},
        2, 'unknown option on a board command exits 2' );

    # A board-less command that composes ExitCodes directly.
    is( _run_karr( $repo, 'agent-name', '--totally-bogus' )->{exit},
        2, 'unknown option on agent-name exits 2' );
    is( _run_karr( $repo, 'skill', '--totally-bogus' )->{exit},
        2, 'unknown option on skill exits 2' );
};

# ------------------------------------------------------- 1 vs 2 for the id "0"

# Ticket #239. `my $id = $pos[0] or die "Usage: ..."` in move, archive, delete,
# edit and handoff read the given-but-false id "0" as "no id was passed at all"
# and answered a usage error (2), while `show` -- which never had that guard --
# called it a missing task (1). Card numbers start at 1, so no reachable card
# was lost; what split was this contract, and ADR 0002 makes it a promise to
# agents that script the CLI. An agent whose id arithmetic produced a 0 heard
# "no such card" from one command and "you mistyped" from five others -- the
# one distinction the two codes exist to draw, landing on the wrong side. Third
# instance of the truthiness-guard root behind #153 and #230, and fixed the
# same way there: `defined && length`.
subtest 'the id 0 is a missing task (1), never a usage error (2)' => sub {
    my $repo = _board_repo();

    my @invocations = (
        [ 'show',    '0' ],
        [ 'move',    '0', 'todo' ],
        [ 'archive', '0' ],
        [ 'delete',  '0', '--yes' ],
        [ 'edit',    '0', '--title', 'x' ],
        [ 'handoff', '0', '--claim', 'some-agent' ],
    );

    for my $argv (@invocations) {
        my $label = join ' ', @$argv;
        my $rv = _run_karr( $repo, @$argv );
        is( $rv->{exit}, 1, "karr $label exits 1 (runtime: no such task)" )
            or diag $rv->{stderr};
        like( $rv->{stderr}, qr/\QTask 0 not found\E/,
            "karr $label names the id it could not find" );
        unlike( $rv->{stderr}, qr/^Usage:/m,
            "karr $label does not answer with a usage line" );
    }
};

subtest 'the single id and the comma list agree about 0' => sub {
    my $repo = _board_repo();

    # parse_ids('0') has always returned the one-element list ("0"), so the
    # emptiness guard under it (ticket #152, `die ... unless @ids`) never fired
    # for a 0 either: `karr move 0,1 todo` already reported "Task 0 not found"
    # and exited 1 while `karr move 0 todo` exited 2. Two spellings of the same
    # argument, two contradictory answers -- now one.
    my $single = _run_karr( $repo, 'move', '0',   'todo' );
    my $list   = _run_karr( $repo, 'move', '0,1', 'todo' );

    is( $single->{exit}, 1, 'karr move 0 todo exits 1' )
        or diag $single->{stderr};
    is( $list->{exit}, 1, 'karr move 0,1 todo exits 1' )
        or diag $list->{stderr};
    like( $list->{stderr}, qr/\QTask 0 not found\E/,
        'the list form still reports the 0 as missing' );
};

subtest 'what stays a usage error: no id at all, and an id list that is empty' => sub {
    my $repo = _board_repo();

    # The branch the "0" was wrongly falling into is for a genuinely absent id.
    for my $argv (
        ['move'], ['archive'], [ 'edit', '--title', 'x' ],
        [ 'delete', '--yes' ], [ 'handoff', '--claim', 'some-agent' ],
    ) {
        my $label = join ' ', @$argv;
        my $rv = _run_karr( $repo, @$argv );
        is( $rv->{exit}, 2, "karr $label (no id) still exits 2" )
            or diag $rv->{stderr};
        like( $rv->{stderr}, qr/^Usage:/m, "karr $label answers a Usage: line" );
    }

    # And, via the #152 guard below it, for an id argument that is present but
    # splits to no ids -- the shell-built list that came out empty.
    for my $argv (
        [ 'move', ',', 'todo' ], ['archive', ','],
        [ 'edit', ',', '--title', 'x' ], [ 'delete', ',', '--yes' ],
    ) {
        my $label = join ' ', @$argv;
        my $rv = _run_karr( $repo, @$argv );
        is( $rv->{exit}, 2, "karr $label (empty id list) still exits 2" )
            or diag $rv->{stderr};
    }

    # A non-numeric id is NOT that branch and never was: "abc" is truthy, so it
    # passed the old guard too, reached find_task and came back as a missing
    # task (1). Pinned because #239 asked whether the conversion could tip it
    # into a usage error -- it cannot. These guards only ever see the argument
    # that is absent and the one that names no ids; deciding whether a present
    # id exists is find_task's job, and its answer is a runtime failure.
    my $abc = _run_karr( $repo, 'move', 'abc', 'todo' );
    is( $abc->{exit}, 1, 'karr move abc todo exits 1: a bad id is not a typo' )
        or diag $abc->{stderr};
    like( $abc->{stderr}, qr/\QTask abc not found\E/,
        'and reports it as a task that does not exist' );
    unlike( $abc->{stderr}, qr/^Usage:/m, 'not as a usage error' );
};

# ------------------------------------------ 1 vs 2 for the config key "0"

# Ticket #244, the last site of the shape above: `my $key = $pos[1] or die
# "Usage: ..."` in Cmd::Config, once for `get` and once for `set`. Same split
# as the ids -- `karr config get 0` answered a usage error (2) where every
# other unknown key answers "Unknown key" (1) -- but a key, not an id, which is
# why #239 left it standing rather than taking it along.
#
# Pinned here even though the class is already pinned three times, because
# nothing else can fail when these two lines change: the ids above are a
# different command surface with a different message pair, and the second of
# the two sites (set) is exactly the kind that gets fixed halfway. The last
# assertion is the reason the value below it is guarded with // and not with
# `or`: "0" is a legal value for foundation.enabled, so a falsy value must
# still be written.
subtest 'the config key 0 is an unknown key (1), never a usage error (2)' => sub {
    my $repo = _board_repo();

    my $get = _run_karr( $repo, 'config', 'get', '0' );
    is( $get->{exit}, 1, 'karr config get 0 exits 1 (runtime: no such key)' )
        or diag $get->{stderr};
    like( $get->{stderr}, qr/\QUnknown key: 0\E/,
        'and names the key it could not resolve' );
    unlike( $get->{stderr}, qr/^Usage:/m, 'not a usage line' );

    my $set = _run_karr( $repo, 'config', 'set', '0', 'x' );
    is( $set->{exit}, 1, 'karr config set 0 x exits 1 (runtime: not writable)' )
        or diag $set->{stderr};
    unlike( $set->{stderr}, qr/^Usage:/m, 'not a usage line either' );

    # The branch those two were wrongly falling into is for a key that is
    # genuinely absent, and it stays a usage error.
    for my $argv ( [ 'config', 'get' ], [ 'config', 'set' ],
        [ 'config', 'set', 'claim_timeout' ] )
    {
        my $label = join ' ', @$argv;
        my $rv = _run_karr( $repo, @$argv );
        is( $rv->{exit}, 2, "karr $label (nothing to act on) still exits 2" )
            or diag $rv->{stderr};
        like( $rv->{stderr}, qr/^Usage:/m, "karr $label answers a Usage: line" );
    }

    # A falsy *value* is a value, and always was: the guard on $pos[2] is //.
    is( _run_karr( $repo, 'config', 'set', 'foundation.enabled', '0' )->{exit},
        0, 'karr config set foundation.enabled 0 still writes the falsy value' );
    my $read = _run_karr( $repo, 'config', 'get', 'foundation.enabled' );
    is( $read->{exit},   0,     'and reading it back exits 0' );
    like( $read->{stdout}, qr/\A0\s*\z/, 'with the 0 that was written' );
};

done_testing;
