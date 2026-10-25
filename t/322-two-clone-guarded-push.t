use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use File::Temp qw( tempdir );
use Cwd qw( abs_path );
use IPC::Open3 qw( open3 );
use Symbol qw( gensym );
use App::karr::Git;

# Ticket k322: two clones writing in the window between a command's pull and
# its push overwrote each other without a word. The board push was a forced
# refspec carrying no expectation of what the remote held, so whichever clone
# pushed second replaced the first one's ref -- a `create` lost a card (both
# clones had allocated the same id from the same counter) and a `pick` handed
# one card to two agents. No conflict was parked on either side: the loser had
# already pushed, so its next pull adopted the winner's version as an ordinary
# remote update.
#
# The race is made deterministic with RaceBeforePush (t/lib): clone b's command
# runs its pull, writes, and right before its push the command in
# KARR_TEST_RACE runs in clone a and pushes. That is the sequence the ticket
# describes, with plain `karr create` and `karr pick` on both sides.
#
# Beside t/181-push-contention-retry.t on purpose: #181 taught the push to
# retry "a reference with that name already exists", which on a new task ref
# is exactly the signal that another clone created that id.

my $ROOT = abs_path('.');
my $BIN  = "$ROOT/bin/karr";

sub _run {
    my ( $dir, @argv ) = @_;
    my $race = ref $argv[0] eq 'HASH' ? shift @argv : undef;
    local $ENV{KARR_TEST_RACE} = $race->{race} if $race;
    my $err = gensym;
    my $pid = open3( my $in, my $out, $err,
        $^X, "-I$ROOT/lib", "-I$ROOT/t/lib",
        ( $race ? '-MRaceBeforePush' : () ),
        $BIN, '--dir', $dir, @argv );
    close $in;
    my $stdout = do { local $/; <$out> };
    my $stderr = do { local $/; <$err> };
    waitpid $pid, 0;
    return {
        exit   => $? >> 8,
        stdout => defined $stdout ? $stdout : '',
        stderr => defined $stderr ? $stderr : '',
    };
}

sub _karr_ok {
    my ( $dir, $what, @argv ) = @_;
    my $r = _run( $dir, @argv );
    is( $r->{exit}, 0, $what ) or diag "stdout: $r->{stdout}\nstderr: $r->{stderr}";
    return $r;
}

# The shell command that runs one karr command in another clone, for
# KARR_TEST_RACE.
sub _race {
    my ( $dir, @argv ) = @_;
    my $q = sub { my $s = shift; $s =~ s/'/'\\''/g; "'$s'" };
    return { race => join( ' ', map { $q->($_) }
        $^X, "-I$ROOT/lib", $BIN, '--dir', $dir, '--quiet', @argv )
        . ' >/dev/null' };
}

# A bare origin and two clones of it, each with a git identity of its own.
sub _clones {
    my $work = tempdir( CLEANUP => 1 );
    system( 'git', 'init', '-q', '--bare', "$work/origin.git" ) == 0
        or die "cannot create origin";
    for my $name (qw( a b )) {
        system("git clone -q '$work/origin.git' '$work/$name' 2>/dev/null") == 0
            or die "cannot clone $name";
        system( 'git', '-C', "$work/$name", 'config', 'user.email',
            "$name\@karr.test" ) == 0 or die;
        system( 'git', '-C', "$work/$name", 'config', 'user.name',
            "agent-$name" ) == 0 or die;
    }
    return ( $work, "$work/a", "$work/b" );
}

# id => title for every card on the board in $dir.
sub _cards {
    my ($dir) = @_;
    my $git = App::karr::Git->new( dir => $dir );
    return { map { $_ => $git->load_task_ref($_)->title } $git->list_task_refs };
}

sub _task {
    my ( $dir, $id ) = @_;
    return App::karr::Git->new( dir => $dir )->load_task_ref($id);
}

sub _parked {
    my ($dir) = @_;
    return [ App::karr::Git->new( dir => $dir )->list_refs('refs/karr-conflict/') ];
}

subtest 'two clones creating at once keep both cards' => sub {
    my ( $work, $a, $b ) = _clones();
    my $origin = "$work/origin.git";

    _karr_ok( $a, 'init in clone a', 'init', '--name', 'Raced' );
    _karr_ok( $a, 'seed card', 'create', 'seed' );
    _karr_ok( $b, 'clone b adopts the board', 'sync', '--quiet' );

    # b pulls (counter 2), a creates and pushes id 2, then b writes and pushes.
    my $r = _run( $b, _race( $a, 'create', 'card from A' ), 'create', 'card from B' );
    is( $r->{exit}, 0, 'the create in clone b succeeds' )
        or diag "stdout: $r->{stdout}\nstderr: $r->{stderr}";

    is_deeply( _cards($origin),
        { 1 => 'seed', 2 => 'card from A', 3 => 'card from B' },
        'the remote holds both cards, each under an id of its own' );
    like( $r->{stdout}, qr/^Created task 3: card from B$/m,
        'clone b reports the id its card ended up with' );

    _karr_ok( $a, 'clone a syncs', 'sync', '--quiet' );
    is_deeply( _cards($a),
        { 1 => 'seed', 2 => 'card from A', 3 => 'card from B' },
        "clone a still has its card and now b's too" );
    is_deeply( _cards($b),
        { 1 => 'seed', 2 => 'card from A', 3 => 'card from B' },
        'clone b agrees' );
    # Only the cards: when both clones moved the id counter, the pull parks
    # the local counter commit even though it keeps the further value, which
    # is older behaviour and no card.
    is_deeply( [ grep { m{/tasks/} } @{ _parked($b) } ], [],
        'and no card had to be parked as a conflict' );
};

subtest 'two clones picking at once: exactly one holds the claim' => sub {
    my ( $work, $a, $b ) = _clones();
    my $origin = "$work/origin.git";

    _karr_ok( $a, 'init in clone a', 'init', '--name', 'Raced' );
    _karr_ok( $a, 'first card',  'create', 'first',  '--priority', 'high' );
    _karr_ok( $a, 'second card', 'create', 'second', '--priority', 'low' );
    _karr_ok( $a, 'release both', 'move', '1,2', 'todo' );
    _karr_ok( $b, 'clone b adopts the board', 'sync', '--quiet' );

    # Both rank card 1 first. a picks it and pushes inside b's window.
    my $r = _run( $b, _race( $a, 'pick', '--claim', 'agentA' ),
        'pick', '--claim', 'agentB' );
    is( $r->{exit}, 0, 'the pick in clone b succeeds' )
        or diag "stdout: $r->{stdout}\nstderr: $r->{stderr}";
    like( $r->{stdout}, qr/^Picked task 2: second \(claimed by agentB\)$/m,
        'clone b moved on to the next candidate' );

    is( _task( $origin, 1 )->claimed_by, 'agentA',
        'card 1 is held by the agent that got there first' );
    is( _task( $origin, 2 )->claimed_by, 'agentB',
        'card 2 by the other one' );

    _karr_ok( $a, 'clone a syncs', 'sync', '--quiet' );
    is( _task( $a, 1 )->claimed_by, 'agentA', 'clone a still says agentA holds card 1' );
    is( _task( $b, 1 )->claimed_by, 'agentA', 'and so does clone b' );
};

subtest 'an edit whose card changed underneath it fails and says so' => sub {
    my ( $work, $a, $b ) = _clones();
    my $origin = "$work/origin.git";

    _karr_ok( $a, 'init in clone a', 'init', '--name', 'Raced' );
    _karr_ok( $a, 'a card', 'create', 'original' );
    _karr_ok( $b, 'clone b adopts the board', 'sync', '--quiet' );

    my $r = _run( $b, _race( $a, 'edit', '1', '--title', 'from A' ),
        'edit', '1', '--title', 'from B' );
    is( $r->{exit}, 1, 'the edit in clone b fails' )
        or diag "stdout: $r->{stdout}\nstderr: $r->{stderr}";
    like( $r->{stderr}, qr/task 1 changed on the remote/,
        'and names the card that changed underneath it' );

    is( _task( $origin, 1 )->title, 'from A', "the remote keeps a's edit" );
    is( _task( $b, 1 )->title, 'from A',
        "clone b now holds the remote's version, not its own" );
    is_deeply( _parked($b), [], 'nothing of the failed edit is left behind' );
};

subtest 'a push from a clone that has not seen the change does not overwrite it' => sub {
    my ( $work, $a, $b ) = _clones();
    my $origin = "$work/origin.git";

    _karr_ok( $a, 'init in clone a', 'init', '--name', 'Raced' );
    _karr_ok( $a, 'a card', 'create', 'original' );
    _karr_ok( $b, 'clone b adopts the board', 'sync', '--quiet' );

    _karr_ok( $b, 'clone b edits locally', 'edit', '1', '--title', 'from B', '--local-only' );
    _karr_ok( $a, 'clone a edits and pushes', 'edit', '1', '--title', 'from A' );

    my $r = _run( $b, 'sync', '--push', '--quiet' );
    is( $r->{exit}, 0, 'the push converges' )
        or diag "stdout: $r->{stdout}\nstderr: $r->{stderr}";
    is( _task( $origin, 1 )->title, 'from A', 'the remote kept the version b had not seen' );
    like( $r->{stderr}, qr/both changed tasks\/1\/data/,
        'clone b is told its version lost' );
    is_deeply( _parked($b), ['refs/karr-conflict/origin/tasks/1/data'],
        'and keeps it parked rather than losing it' );
};

subtest "a pull's writes are not the command's own" => sub {
    my ( $work, $a, $b ) = _clones();

    _karr_ok( $a, 'init in clone a', 'init', '--name', 'Raced' );
    _karr_ok( $a, 'a card', 'create', 'original' );
    _karr_ok( $b, 'clone b adopts the board', 'sync', '--quiet' );
    _karr_ok( $a, 'clone a edits and pushes', 'edit', '1', '--title', 'from A' );

    # The pull a stale push makes before pushing again adopts the other
    # clone's card. Were that recorded as the command's write, a later stale
    # round would take the remote's version back out of this clone. The pull
    # writes through the untracked path, which the journal never sees.
    my $git = App::karr::Git->new( dir => $b );
    $git->start_journal;
    ok( $git->pull('origin'), 'clone b pulls' );
    is( _task( $b, 1 )->title, 'from A', "and took clone a's edit" );
    is_deeply( [ $git->journal_refs ], [], 'which its journal does not count' );
};

done_testing;
