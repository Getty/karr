use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use TestKarr qw( run_karr );
use File::Temp qw( tempdir );

# ---------------------------------------------------------------------------
# Ticket #182: `karr init` decided whether this repository already had a board
# by looking at refs/karr/config and nothing else. `git clone` does not fetch
# refs/karr/*, so in a fresh clone of a repository whose board lives on origin
# that check answers "no board here" -- and init wrote a second board, with its
# own refs/karr/meta/board-id beside the one on the remote. The next sync then
# hit the board-identity guard (#95) with "the remote is a different board":
# correct, and by then the user was holding two boards.
#
# So init asks the remote first, through the bounded ls-remote probe #173 left
# behind (App::karr::Git/remote_has_board), before it writes any ref, and
# refuses a repository whose board is one `karr sync` away. What it must not do
# is refuse anything else, so the states that have to stay exactly as they were
# get their own subtests below:
#
#   no remote                nothing to ask; init is the answer and always was
#   remote without a board   the probe's other answer, and the common case
#   unreachable remote       fail open: a question that could not be put is not
#                            evidence of a board, and init has to work offline
#   --new-board              the deliberate opt-out, for a clone that really
#                            does want its own independent board
# ---------------------------------------------------------------------------

# In-process runner (t/lib/TestKarr.pm): same ($cwd, @argv) signature and
# { exit, stdout, stderr } return as the open3 helper this file used to carry,
# dispatched through the shared App::karr::Dispatch path. KARR_TEST_SUBPROC=1
# restores the old open3 path.
sub _run_karr { return run_karr(@_) }

sub _repo {
    my $repo = tempdir( CLEANUP => 1 );
    system( 'git', 'init', '-q', $repo ) == 0 or BAIL_OUT('git init failed');
    system( 'git', '-C', $repo, 'config', 'user.email', 'test@example.com' ) == 0
        or BAIL_OUT('git config failed');
    system( 'git', '-C', $repo, 'config', 'user.name', 'Test User' ) == 0
        or BAIL_OUT('git config failed');
    return $repo;
}

sub _karr_refs {
    my ($repo) = @_;
    my @refs = `git -C '$repo' for-each-ref --format='%(refname)' 'refs/karr/'`;
    chomp @refs;
    return @refs;
}

sub _board_id {
    my ($repo) = @_;
    my $id = `git -C '$repo' cat-file -p refs/karr/meta/board-id 2>/dev/null` // '';
    $id =~ s/\s+//g;
    return length $id ? $id : undef;
}

# A bare origin carrying a board, and nothing else -- the shape a fresh clone
# of a karr-using project meets.
sub _published_board {
    my ( $work, $name, @titles ) = @_;
    my $origin = "$work/origin.git";
    system( 'git', 'init', '-q', '--bare', $origin ) == 0
        or BAIL_OUT('git init --bare failed');

    my $source = _repo();
    _run_karr( $source, 'init', '--name', $name )->{exit} == 0
        or BAIL_OUT('karr init failed');
    _run_karr( $source, 'create', $_ )->{exit} == 0 or BAIL_OUT('karr create failed')
        for @titles;
    system( 'git', '-C', $source, 'remote', 'add', 'origin', $origin ) == 0
        or BAIL_OUT('git remote add failed');
    _run_karr( $source, 'sync' )->{exit} == 0 or BAIL_OUT('karr sync failed');
    return ( $origin, $source );
}

sub _clone {
    my ( $origin, $to ) = @_;
    system("git clone -q '$origin' '$to' 2>/dev/null") == 0 or BAIL_OUT('git clone failed');
    system( 'git', '-C', $to, 'config', 'user.email', 'test@example.com' );
    system( 'git', '-C', $to, 'config', 'user.name',  'Test User' );
    return $to;
}

subtest 'a fresh clone whose remote has a board is refused, and nothing is written' => sub {
    my $work = tempdir( CLEANUP => 1 );
    my ( $origin, $source ) =
        _published_board( $work, 'Remote Board', 'a ticket that exists' );
    my $clone = _clone( $origin, "$work/clone" );

    is( scalar _karr_refs($clone), 0, 'setup: git clone fetched none of refs/karr/*' );

    my $rv = _run_karr( $clone, 'init', '--name', 'Rival' );
    is( $rv->{exit}, 1, 'karr init refuses' );
    like( $rv->{stderr}, qr{already has a board on origin},
        'saying the board is on the remote' );
    like( $rv->{stderr}, qr{'karr sync'}, 'and how to get it' );
    like( $rv->{stderr}, qr{--new-board}, 'and how to insist on a second board' );

    # The point of the whole ticket: the probe runs in front of the first ref
    # write, so a refused init leaves the repository exactly as it found it --
    # no config, no counter, no encoding stamp and above all no second
    # board-id, which is the ref that makes the next sync unrecoverable by
    # ordinary means.
    is( scalar _karr_refs($clone), 0, 'and wrote no ref at all' );
    ok( !-e "$clone/.gitignore", 'not even the .gitignore entries' );

    # The advice has to be actionable, or the refusal is just a wall.
    my $sync = _run_karr( $clone, 'sync' );
    is( $sync->{exit}, 0, "the 'karr sync' it names succeeds" ) or diag $sync->{stderr};
    like( _run_karr( $clone, 'list', '--compact' )->{stdout}, qr{a ticket that exists},
        'and brings in the board that was there all along' );
    ok( defined _board_id($source), 'setup: the published board carries an identity' );
    is( _board_id($clone), _board_id($source),
        'and the clone now carries that one, not a second board of its own' );

    # And once the board is here, the ordinary local refusal takes over again.
    my $again = _run_karr( $clone, 'init' );
    is( $again->{exit}, 1, 'a second init still refuses' );
    like( $again->{stderr}, qr{Board already exists in refs/karr/},
        'with the local message, which needs no remote to be true' );
};

subtest '--new-board initializes anyway, deliberately beside the remote board' => sub {
    my $work = tempdir( CLEANUP => 1 );
    my ( $origin, $source ) =
        _published_board( $work, 'Remote Board', 'a ticket that exists' );
    my $clone = _clone( $origin, "$work/clone" );

    my $rv = _run_karr( $clone, 'init', '--name', 'Independent', '--new-board' );
    is( $rv->{exit}, 0, 'karr init --new-board succeeds' ) or diag $rv->{stderr};
    like( $rv->{stdout}, qr{Initialized karr board in refs/karr/}, 'and says so' );
    unlike( $rv->{stderr}, qr{already has a board}, 'without the refusal' );
    cmp_ok( scalar _karr_refs($clone), '>', 0, 'the board is here' );

    my $mine = _board_id($clone);
    ok( defined $mine, 'and carries an identity of its own' );
    isnt( $mine, _board_id($source), 'a different one from the board on origin' );
    like( _run_karr( $clone, 'board' )->{stdout}, qr{Independent},
        'it is this clone\'s own board that answers here' );
};

subtest 'the states that must not change: no remote, no board on the remote' => sub {
    my $work = tempdir( CLEANUP => 1 );

    my $alone = _repo();
    my $rv    = _run_karr( $alone, 'init', '--name', 'Alone' );
    is( $rv->{exit}, 0, 'a repository with no remote initializes as before' )
        or diag $rv->{stderr};
    is( $rv->{stderr}, '', 'and says nothing on STDERR: nobody was asked' );
    cmp_ok( scalar _karr_refs($alone), '>', 0, 'the board is here' );

    system( 'git', 'init', '-q', '--bare', "$work/empty.git" ) == 0
        or BAIL_OUT('git init --bare failed');
    my $boardless = _repo();
    system( 'git', '-C', $boardless, 'remote', 'add', 'origin', "$work/empty.git" ) == 0
        or BAIL_OUT('git remote add failed');

    $rv = _run_karr( $boardless, 'init', '--name', 'First' );
    is( $rv->{exit}, 0, 'a remote without a board initializes as before' )
        or diag $rv->{stderr};
    is( $rv->{stderr}, '', 'the probe answered, so there is nothing to report' );
    cmp_ok( scalar _karr_refs($boardless), '>', 0, 'the board is here' );
};

subtest 'a probe that gets no answer does not block init' => sub {
    my $work = tempdir( CLEANUP => 1 );

    # A remote URL that goes nowhere: the probe fails rather than answering,
    # and init must go on. Refusing here would make init unusable offline,
    # where a configured remote says nothing about what it holds.
    my $repo = _repo();
    system( 'git', '-C', $repo, 'remote', 'add', 'origin', "$work/nowhere.git" ) == 0
        or BAIL_OUT('git remote add failed');

    my $rv = _run_karr( $repo, 'init', '--name', 'Offline' );
    is( $rv->{exit}, 0, 'init goes ahead when the remote could not be asked' )
        or diag $rv->{stderr};
    cmp_ok( scalar _karr_refs($repo), '>', 0, 'and the board is here' );
    like( $rv->{stderr}, qr{could not ask the remote whether it already has a board},
        'with one line saying what could not be established' );
    is( scalar( grep { /\S/ } split /\n/, $rv->{stderr} ), 1,
        'exactly one line, and nothing else' );
};

subtest 'a half-board in a clone is not completed into a rival board' => sub {
    my $work = tempdir( CLEANUP => 1 );
    my ( $origin, $source ) =
        _published_board( $work, 'Remote Board', 'a ticket that exists' );
    my $clone = _clone( $origin, "$work/clone" );

    # The #62 state: refs under refs/karr/ but no refs/karr/config, which a
    # stray write command leaves behind and which init otherwise completes.
    # Here the completion would stamp refs/karr/meta/board-id -- and this
    # repository's board, the one on origin, already carries one, so the very
    # next sync would be back in #95. The remote's answer therefore outranks
    # the local refs.
    my $seed = "$work/next-id";
    open my $fh, '>', $seed or BAIL_OUT("open $seed: $!");
    print {$fh} "7\n";
    close $fh;
    my $blob = `git -C '$clone' hash-object -w -- '$seed'`;
    $blob =~ s/\s+//g;
    system( 'git', '-C', $clone, 'update-ref', 'refs/karr/meta/next-id', $blob ) == 0
        or BAIL_OUT('update-ref failed');
    my @before = _karr_refs($clone);
    is( scalar @before, 1, 'setup: a half-board, with no config ref' );

    my $rv = _run_karr( $clone, 'init', '--name', 'Completed' );
    is( $rv->{exit}, 1, 'init refuses to complete it against a remote that has a board' );
    like( $rv->{stderr}, qr{already has a board on origin}, 'with the same reason' );
    is_deeply( [ _karr_refs($clone) ], \@before,
        'and the refs that were here are untouched -- no config, no board-id' );

    # --new-board is still the way through, and it completes the half-board the
    # way it always did.
    $rv = _run_karr( $clone, 'init', '--name', 'Completed', '--new-board' );
    is( $rv->{exit}, 0, '--new-board completes it' ) or diag $rv->{stderr};
    like( $rv->{stdout}, qr{Completed a half-board}, 'and says that is what it did' );
    isnt( _board_id($clone), _board_id($source), 'as a board of its own' );
};

done_testing;
