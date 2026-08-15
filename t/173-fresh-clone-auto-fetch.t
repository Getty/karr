use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use File::Temp qw( tempdir );
use Cwd qw( abs_path getcwd );
use IPC::Open3 qw( open3 );
use IO::Socket::INET;
use POSIX ();
use Symbol qw( gensym );
use Time::HiRes ();
use JSON::MaybeXS qw( decode_json );

# ---------------------------------------------------------------------------
# Ticket #173: `git clone` does not carry refs/karr/*, so every read command in
# a fresh checkout refused with "No karr board in this repository: nothing is
# stored under refs/karr/ ... Run 'karr sync' to fetch the board". Accurate,
# and its advice was right -- and karr had everything it needed to act on that
# advice itself: the remote is configured and `git ls-remote origin
# 'refs/karr/*'` answers in milliseconds. It hit every new checkout, and agents
# hardest: they read it as "there is no board" and moved on.
#
# So where refs/karr/ is empty, a remote exists, and that remote advertises
# refs/karr/*, the read fetches once and answers the question it was asked
# (App::karr::Role::BoardDiscovery::_autofetch_board). The refusal stays for
# the states where it is the truth, and those are the ones with the most to
# lose here, so each gets its own subtest below:
#
#   no remote                  nothing to ask; `karr init` really is the answer
#   remote without a board     same, and the probe is what establishes it
#   KARR_NO_AUTO_FETCH=1       the opt-out, for an environment where karr must
#                              not touch the network at all
#   a destroy not yet pushed   no local board and a whole board still on the
#                              remote is also what `karr destroy` looks like
#                              until its push lands -- fetching there would
#                              undo it on the next `karr list`
#   an unreachable remote      an unasked round trip has to be bounded, or a
#                              silent ssh peer parks a plain `karr list` (#174)
# ---------------------------------------------------------------------------

my $ROOT = abs_path('.');
my $BIN  = "$ROOT/bin/karr";

my @CHILDREN;
END { kill 'KILL', @CHILDREN if @CHILDREN }

sub _run_karr {
    my ( $cwd, @argv ) = @_;
    my $old = getcwd();
    chdir $cwd or die "chdir $cwd: $!";

    my $stderr = gensym;
    my $pid = open3( undef, my $stdout_fh, $stderr, $^X, "-I$ROOT/lib", $BIN, @argv );
    my $out = do { local $/; <$stdout_fh> };
    my $err = do { local $/; <$stderr> };
    waitpid( $pid, 0 );
    my $exit = $? >> 8;

    chdir $old or die "chdir $old: $!";
    return {
        exit   => $exit,
        stdout => defined $out ? $out : '',
        stderr => defined $err ? $err : '',
    };
}

# The same, but the parent enforces a deadline and kills the run that blows it.
# `exit => undef` is the signature of the hang this has to rule out: a karr
# command that waits on an unasked probe forever. Reading the pipes only after
# the child is gone is safe here -- these commands print a few lines.
sub _run_karr_bounded {
    my ( $cwd, $deadline, @argv ) = @_;
    my $old = getcwd();
    chdir $cwd or die "chdir $cwd: $!";

    my $started = Time::HiRes::time();
    my $stderr  = gensym;
    my $pid = open3( undef, my $stdout_fh, $stderr, $^X, "-I$ROOT/lib", $BIN, @argv );
    push @CHILDREN, $pid;

    my $status;
    while ( ( Time::HiRes::time() - $started ) < $deadline ) {
        if ( waitpid( $pid, POSIX::WNOHANG() ) == $pid ) { $status = $?; last }
        Time::HiRes::sleep(0.05);
    }
    my $elapsed = Time::HiRes::time() - $started;
    unless ( defined $status ) {
        kill 'KILL', $pid;
        waitpid $pid, 0;
    }
    @CHILDREN = grep { $_ != $pid } @CHILDREN;

    my $out = do { local $/; <$stdout_fh> };
    my $err = do { local $/; <$stderr> };
    chdir $old or die "chdir $old: $!";
    return {
        exit    => ( defined $status ? $status >> 8 : undef ),
        elapsed => $elapsed,
        stdout  => defined $out ? $out : '',
        stderr  => defined $err ? $err : '',
    };
}

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
    return scalar @refs;
}

sub _refs_under {
    my ( $repo, $prefix ) = @_;
    my @refs = `git -C '$repo' for-each-ref --format='%(refname)' '$prefix'`;
    chomp @refs;
    return @refs;
}

sub _drop_refs {
    my ( $repo, $prefix ) = @_;
    my @refs = _refs_under( $repo, $prefix );
    system( 'git', '-C', $repo, 'update-ref', '-d', $_ ) == 0 or BAIL_OUT("update-ref -d $_")
        for @refs;
    return scalar @refs;
}

# A bare origin carrying a board, and nothing else -- the shape a fresh clone
# meets. Returns ( $origin, $source ).
sub _published_board {
    my ( $work, $name, @titles ) = @_;
    my $origin = "$work/origin.git";
    system( 'git', 'init', '-q', '--bare', $origin ) == 0
        or BAIL_OUT('git init --bare failed');

    my $source = _repo();
    _run_karr( $source, 'init', '--name', $name )->{exit} == 0
        or BAIL_OUT('karr init failed');
    for my $title (@titles) {
        _run_karr( $source, 'create', $title )->{exit} == 0
            or BAIL_OUT("karr create failed for $title");
    }
    system( 'git', '-C', $source, 'remote', 'add', 'origin', $origin ) == 0
        or BAIL_OUT('git remote add failed');
    _run_karr( $source, 'sync' )->{exit} == 0 or BAIL_OUT('karr sync failed');
    return ( $origin, $source );
}

sub _clone {
    my ( $origin, $to ) = @_;
    system("git clone -q '$origin' '$to' 2>/dev/null");
    system( 'git', '-C', $to, 'config', 'user.email', 'test@example.com' );
    system( 'git', '-C', $to, 'config', 'user.name',  'Test User' );
    return $to;
}

subtest 'a fresh clone reads the board instead of refusing' => sub {
    my $work = tempdir( CLEANUP => 1 );
    my ($origin) = _published_board( $work, 'Remote Board', 'a ticket that exists' );
    my $clone = _clone( $origin, "$work/clone" );

    is( _karr_refs($clone), 0, 'setup: git clone fetched none of refs/karr/*' );

    my $list = _run_karr( $clone, 'list' );
    is( $list->{exit}, 0, 'karr list answers in a fresh clone' )
        or diag $list->{stderr};
    like( $list->{stdout}, qr{a ticket that exists},
        'with the ticket that was never missing, only unfetched' );
    cmp_ok( _karr_refs($clone), '>', 0, 'and the board is here now' );

    # The whole point of the one line being on STDERR: agents parse the other
    # stream, and this fires on a command they did not ask to sync.
    like( $list->{stderr}, qr{^karr: fetched the board from the remote},
        'one line says what it did' );
    is( scalar( grep { /\S/ } split /\n/, $list->{stderr} ), 1,
        'exactly one line, and nothing else' );

    my $json = _run_karr( $clone, 'list', '--json' );
    is( $json->{exit}, 0, 'a second read needs no fetch' );
    is( $json->{stderr}, '', 'and says nothing at all: the note is not a banner' );
    my $data = eval { decode_json( $json->{stdout} ) };
    is( scalar @{ $data || [] }, 1, '--json stdout stays parsable' )
        or diag $json->{stdout};
};

subtest '--json in the fresh clone itself is still parsable' => sub {
    # The fetch and the payload happen in one command here, which is the run
    # that would break a --json consumer if the note ever went to STDOUT.
    my $work = tempdir( CLEANUP => 1 );
    my ($origin) = _published_board( $work, 'Remote Board', 'unfetched ticket' );
    my $clone = _clone( $origin, "$work/clone" );

    my $rv = _run_karr( $clone, 'board', '--json' );
    is( $rv->{exit}, 0, 'karr board --json answers in a fresh clone' )
        or diag $rv->{stderr};
    my $data = eval { decode_json( $rv->{stdout} ) };
    is( $data->{name}, 'Remote Board', 'stdout is JSON and nothing but JSON' )
        or diag $rv->{stdout};
    is( $data->{total}, 1, 'with the remote board\'s card in it' );
    like( $rv->{stderr}, qr{fetched the board}, 'the note went to STDERR' );
};

subtest 'the states where the refusal is the truth still refuse' => sub {
    my $work = tempdir( CLEANUP => 1 );

    my $alone = _repo();                      # no remote at all
    my $rv    = _run_karr( $alone, 'list' );
    is( $rv->{exit}, 1, 'a repository with no remote still refuses' );
    like( $rv->{stderr}, qr{nothing is stored under refs/karr/}, 'with the old message' );
    unlike( $rv->{stderr}, qr{fetched the board}, 'having fetched nothing' );
    unlike( $rv->{stderr}, qr{could not ask}, 'and having asked nobody' );

    # A remote that answers and has no board: the probe's other answer, and the
    # one state where `karr init` is right even though there is a remote.
    system( 'git', 'init', '-q', '--bare', "$work/empty.git" ) == 0
        or BAIL_OUT('git init --bare failed');
    my $boardless = _repo();
    system( 'git', '-C', $boardless, 'remote', 'add', 'origin', "$work/empty.git" ) == 0
        or BAIL_OUT('git remote add failed');

    $rv = _run_karr( $boardless, 'list' );
    is( $rv->{exit}, 1, 'a remote without a board still refuses' );
    like( $rv->{stderr}, qr{nothing is stored under refs/karr/}, 'with the same message' );
    unlike( $rv->{stderr}, qr{fetched the board}, 'and nothing was fetched' );
    is( _karr_refs($boardless), 0, 'the repository is as empty as it was' );
};

subtest 'KARR_NO_AUTO_FETCH=1 turns it off' => sub {
    my $work = tempdir( CLEANUP => 1 );
    my ($origin) = _published_board( $work, 'Remote Board', 'a ticket that exists' );
    my $clone = _clone( $origin, "$work/clone" );

    local $ENV{KARR_NO_AUTO_FETCH} = 1;
    my $rv = _run_karr( $clone, 'list' );
    is( $rv->{exit}, 1, 'the opt-out puts the refusal back' );
    like( $rv->{stderr}, qr{Run 'karr sync' to fetch the board},
        'advice included -- it is the answer again' );
    is( _karr_refs($clone), 0, 'and nothing was fetched' );
};

subtest 'a destroy whose push has not landed is not undone by a read' => sub {
    my $work = tempdir( CLEANUP => 1 );
    my ($origin) = _published_board( $work, 'Doomed Board', 'about to go' );
    my $clone = _clone( $origin, "$work/clone" );
    _run_karr( $clone, 'sync' )->{exit} == 0 or BAIL_OUT('karr sync failed');
    cmp_ok( _karr_refs($clone), '>', 0, 'setup: the clone holds the board' );

    # A destroy that deletes locally and cannot publish it: the push URL goes
    # nowhere, the fetch URL still works. That is the state a rejected or
    # interrupted push leaves behind, and from the outside it is exactly a
    # fresh clone -- no refs/karr/*, a whole board on the remote.
    system( 'git', '-C', $clone, 'remote', 'set-url', '--push', 'origin',
        "$work/nowhere.git" ) == 0 or BAIL_OUT('git remote set-url failed');
    my $destroy = _run_karr( $clone, 'destroy', '--yes' );
    is( $destroy->{exit}, 1, 'setup: the destroy could not publish itself' );
    is( _karr_refs($clone), 0, 'setup: and deleted the board locally' );
    cmp_ok( scalar _refs_under( $clone, 'refs/karr-local/deleted/' ), '>', 0,
        'setup: leaving tombstones for the deletions it owes the remote' );

    my $rv = _run_karr( $clone, 'list' );
    is( $rv->{exit}, 1, 'the read refuses rather than fetching the board back' );
    is( _karr_refs($clone), 0, 'and the destroyed board stays destroyed' );
    unlike( $rv->{stderr}, qr{fetched the board}, 'nothing was adopted' );

    # Two things stand in the way here and they are not the same thing. The
    # refs/karr-remote mirror is one: a ref it holds that the board no longer
    # does reads as this clone's own deletion, so reconciliation keeps it
    # deleted. Take the mirror away -- the state of a board fetched into
    # refs/karr by hand -- and the tombstones are the only guard left.
    _drop_refs( $clone, 'refs/karr-remote/' );
    $rv = _run_karr( $clone, 'list' );
    is( $rv->{exit}, 1, 'with the mirror gone the tombstones alone still refuse' );
    is( _karr_refs($clone), 0, 'and the board is still gone' );

    # The counter-proof: without either record this clone is indistinguishable
    # from a fresh clone, and then it does fetch. So the refusals above are the
    # guards, not some other accident of this setup.
    _drop_refs( $clone, 'refs/karr-local/deleted/' );
    $rv = _run_karr( $clone, 'list' );
    is( $rv->{exit}, 0, 'with no record of the deletion left, the read fetches' )
        or diag $rv->{stderr};
    cmp_ok( _karr_refs($clone), '>', 0, 'which is what makes the guards load-bearing' );
};

subtest 'the probe is bounded: a silent remote costs seconds, not the command' => sub {
    # #174: libgit2's server timeout does not reach libssh2, so a peer that
    # accepts the connection and then says nothing can park a native transport
    # indefinitely. That is survivable for a command someone typed; it is not
    # survivable for a round trip taken unasked in front of `karr list`, which
    # is why the probe runs through the git CLI, where the deadline holds.
    #
    # The silent peer is a socket that listens and never accepts: the kernel
    # completes the handshake from the backlog, so the client connects and then
    # waits for an answer that never comes.
    my $server = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 50, ReuseAddr => 1,
    ) or plan skip_all => "cannot listen on 127.0.0.1: $!";
    my $port = $server->sockport;

    my $repo = _repo();
    system( 'git', '-C', $repo, 'remote', 'add', 'origin',
        "git://127.0.0.1:$port/silent.git" ) == 0 or BAIL_OUT('git remote add failed');

    local $ENV{KARR_TRANSPORT_TIMEOUT} = 3;   # the probe takes the lower of this and 10s
    my $rv = _run_karr_bounded( $repo, 30, 'list' );

    ok( defined $rv->{exit}, 'the read came back on its own' )
        or diag sprintf 'still running after %.1fs; killed', $rv->{elapsed};

    SKIP: {
        skip 'the read never returned', 4 unless defined $rv->{exit};
        is( $rv->{exit}, 1, 'refusing, because the board could not be found' );
        like( $rv->{stderr}, qr{could not ask the remote whether it has the board},
            'saying in one line that it tried and could not' );
        like( $rv->{stderr}, qr{no answer within 3s},
            'and that it was the deadline that ended it' );
        cmp_ok( $rv->{elapsed}, '>=', 1.5, sprintf
            'it did wait for that deadline (%.2fs), so the bound measured here '
            . 'is the configured one and not an instant connection error',
            $rv->{elapsed} );
    }
};

done_testing;
