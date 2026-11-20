#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use Cwd ();
# Absolute: TestKarr chdirs into the repo under test, and a command class
# loaded after that would otherwise come from an installed App::karr.
use lib Cwd::abs_path('lib');
use TestGit qw( require_git_c );
require_git_c();
use TestKarr qw( run_karr );
use File::Temp qw( tempdir );
use App::karr::Git;
use App::karr::SyncGuard;
use App::karr::Role::SyncLifecycle;

# Ticket k333, part A: a push denied write access is tried once.
#
# Before, every failed push got three attempts a second apart, whatever the
# reason -- so a clone without credentials printed the same git error three
# times and then pointed at `karr sync`, which would be denied identically.
# A denial is as final as a per-ref rejection (#84); only an unreachable remote
# (and a failure nobody recognised) keeps the three attempts.
#
# The sync loops are driven with duck-typed gits that count the transport calls
# they are given, so "once" is a number, not a timing. The end-to-end half runs
# the real CLI against a bare origin this user cannot write.

{
    package CountingGit;
    # %arg: push_failure => hashref|undef, err => text, can_failure => bool
    sub new {
        my ( $class, %arg ) = @_;
        return bless { pushes => 0, %arg }, $class;
    }
    sub pull       { 1 }
    sub push       { $_[0]{pushes}++; return 0 }
    sub last_error { $_[0]{err} // 'SIMULATED-FAILURE' }
    sub pushes     { $_[0]{pushes} }
    sub push_rejections { [] }
    sub push_contention { 0 }
    sub push_stale      { [] }
    sub push_failure    { $_[0]{push_failure} }
}

{
    # No push_failure at all: the git doubles older tests drive the role with.
    package PlainGit;
    sub new { bless { pushes => 0 }, shift }
    sub pull       { 1 }
    sub push       { $_[0]{pushes}++; return 0 }
    sub last_error { 'PLAIN-FAILURE' }
    sub pushes     { $_[0]{pushes} }
}

{
    package DenyBoard;
    use Moo;
    use MooX::Options;
    with 'App::karr::Role::SyncLifecycle';
    has git => ( is => 'ro', required => 1 );
}

sub capture_stderr {
    my ($code) = @_;
    my ( $buf, $err ) = ( '', undef );
    {
        local *STDERR;
        open STDERR, '>', \$buf or die "cannot redirect STDERR: $!";
        $err = do { local $@; eval { $code->(); 1 } ? undef : $@ };
    }
    return ( $buf, $err );
}

sub denied {
    return { class => 'denied', remote => 'origin', reason => 'no credentials for HTTPS' };
}

# ---------------------------------------------------------------------
# sync_after
# ---------------------------------------------------------------------
subtest 'sync_after: a denied push is attempted once and says denied' => sub {
    my $git = CountingGit->new(
        push_failure => denied(),
        err => "git push failed: fatal: could not read Username for 'https://h'",
    );
    my ( $stderr, $err ) = capture_stderr( sub {
        my $board = DenyBoard->new( git => $git );
        $board->sync_after;
    } );

    is $git->pushes, 1, 'exactly one transport attempt (the old loop made three)';
    like $err, qr/denied/i, 'the command fails with a denial';
    like $err, qr/no credentials for HTTPS/, 'and names the reason';
    like $err, qr/this clone is now read-only for the board/,
        'and says what the denial did to this clone (not "tried once": one attempt is the pushes count above)';
    like $err, qr/karr readonly on/, 'and names the way out for a read-only clone';
    unlike $stderr . $err, qr/Push retry/, 'no retry banner was printed';
    unlike $err, qr/Push failed after 3 attempts/, 'and not the exhausted-retries verdict';
    my @shown = $stderr =~ /(could not read Username)/g;
    is scalar @shown, 1, 'the git error is shown once';
    unlike $stderr, qr/git push failed: git push failed:/, 'without the doubled prefix';
};

subtest 'sync_after: an unreachable remote keeps its three attempts' => sub {
    my $git = CountingGit->new(
        push_failure => { class => 'unreachable', remote => 'origin', reason => 'the connection was refused' },
        err => 'git push failed: Connection refused',
    );
    my ( $stderr, $err ) = capture_stderr( sub { DenyBoard->new( git => $git )->sync_after } );

    is $git->pushes, 3, 'all three attempts are made';
    like $stderr, qr/Push retry 2 of 3/, 'the retries are announced as before';
    like $stderr, qr/Push retry 3 of 3/, 'both of them';
    like $err, qr/Push failed after 3 attempts/, 'and the verdict is the exhausted-retries one';
    unlike $err, qr/denied/i, 'not a denial';
};

subtest 'sync_after: a failure of no recognised kind keeps three attempts' => sub {
    my $git = CountingGit->new(
        push_failure => { class => 'other', remote => 'origin', reason => 'who knows' },
    );
    my ( undef, $err ) = capture_stderr( sub { DenyBoard->new( git => $git )->sync_after } );
    is $git->pushes, 3, 'other is retried';
    unlike $err, qr/denied/i, 'and is not called a denial';
};

subtest 'sync_after: a git without push_failure behaves as before' => sub {
    my $git = PlainGit->new;
    is( ( $git->can('push_failure') ? 1 : 0 ), 0, 'the double really has no push_failure' );
    my ( $stderr, $err ) = capture_stderr( sub { DenyBoard->new( git => $git )->sync_after } );
    is $git->pushes, 3, 'three attempts';
    like $stderr, qr/Push retry 2 of 3/, 'retry banners';
    like $err, qr/Push failed after 3 attempts/, 'the old verdict';
    like $stderr, qr/PLAIN-FAILURE/, 'and the git error';
};

subtest 'sync_after: a failure with no recorded class is not a denial' => sub {
    # Without a class on the object the loop must not invent a denial: it
    # tries the ordinary three times.
    my $git = CountingGit->new( push_failure => undef );
    my ( undef, $err ) = capture_stderr( sub { DenyBoard->new( git => $git )->sync_after } );
    is $git->pushes, 3, 'no failure recorded: the ordinary three attempts';
    unlike $err, qr/denied/i, 'and no denial';
};

# ---------------------------------------------------------------------
# sync_push_foundation
# ---------------------------------------------------------------------
subtest 'sync_push_foundation: denied is tried once too' => sub {
    {
        package FoundationGit;
        our @ISA = ('CountingGit');
        sub push_foundation { $_[0]->push }
    }
    my $git = FoundationGit->new( push_failure => denied() );
    my ( undef, $err ) = capture_stderr( sub { DenyBoard->new( git => $git )->sync_push_foundation } );
    is $git->pushes, 1, 'one attempt';
    like $err, qr/denied/i, 'denied verdict';
    like $err, qr/no credentials for HTTPS/, 'with the reason';
    unlike $err, qr/was rejected by the remote/, 'not the per-ref rejection text';
};

# ---------------------------------------------------------------------
# SyncGuard insurance push
# ---------------------------------------------------------------------
sub guard_run {
    my ($git) = @_;
    my ( $stderr, $err );
    my $warned = '';
    ( $stderr, $err ) = capture_stderr( sub {
        local $SIG{__WARN__} = sub { $warned .= $_[0] };
        my $guard = App::karr::SyncGuard->new( git => $git );
        $guard->DESTROY;
        $guard->done;    # neutralise the scope-exit DESTROY
    } );
    return ( $stderr, $warned );
}

subtest 'SyncGuard: a denied insurance push is attempted once and warns denied' => sub {
    my $git = CountingGit->new( push_failure => denied() );
    my ( $stderr, $warned ) = guard_run($git);

    is $git->pushes, 1, 'one attempt (the old guard made three)';
    unlike $stderr, qr/Push retry/, 'no retry banner';
    like $warned, qr/denied/i, 'the warning says denied';
    like $warned, qr/no credentials for HTTPS/, 'with the reason';
    like $warned, qr/this clone is now read-only for the board/,
        'and that the clone is read-only now (one attempt is the pushes count above)';
    unlike $warned, qr/Push failed after 3 attempts/, 'not the exhausted-retries guidance';
};

subtest 'SyncGuard: an unreachable remote keeps its three attempts' => sub {
    my $git = CountingGit->new(
        push_failure => { class => 'unreachable', remote => 'origin', reason => 'the connection was refused' } );
    my ( $stderr, $warned ) = guard_run($git);
    is $git->pushes, 3, 'three attempts';
    like $stderr, qr/Push retry 3 of 3/, 'announced';
    like $warned, qr/Push failed after 3 attempts/, 'with the usual guidance';
    unlike $warned, qr/denied/i, 'and no denial';
};

subtest 'SyncGuard: a git without push_failure behaves as before' => sub {
    my $git = PlainGit->new;
    my ( undef, $warned ) = guard_run($git);
    is $git->pushes, 3, 'three attempts';
    like $warned, qr/Push failed after 3 attempts/, 'old guidance';
};

# ---------------------------------------------------------------------
# End to end, native route, through the CLI runner (in-process).
# The CLI route is t/329-push-denied-cli.t: its git child needs a real STDERR.
# ---------------------------------------------------------------------
SKIP: {
    skip 'running as root: it ignores the read-only mode of the bare repository', 1
        if $> == 0;

    subtest 'karr create against a read-only origin, native transport' => sub {
        local $ENV{KARR_NO_CLI_FALLBACK} = 1;
        my $work = tempdir( CLEANUP => 1 );
        system( 'git', 'init', '-q', '--bare', "$work/origin.git" );
        system("git clone -q '$work/origin.git' '$work/a' 2>/dev/null");
        system( 'git', '-C', "$work/a", 'config', 'user.email', 'a@karr.test' );
        system( 'git', '-C', "$work/a", 'config', 'user.name',  'agent-a' );
        is run_karr( "$work/a", 'init' )->{exit}, 0, 'board initialised while origin is writable';

        system( 'chmod', '-R', 'a-w', "$work/origin.git" );
        my $pushes = 0;
        my $orig   = \&App::karr::Git::push;
        my $r;
        {
            no warnings 'redefine';
            local *App::karr::Git::push = sub { $pushes++; goto &$orig };
            $r = run_karr( "$work/a", 'create', 'probe', '--body', 'x' );
        }
        system( 'chmod', '-R', 'u+w', "$work/origin.git" );

        is $r->{exit}, 1, 'exit 1';
        is $pushes, 1, 'one push attempt';
        like $r->{stderr}, qr/denied/i, 'STDERR says denied';
        like $r->{stderr}, qr/cannot write the remote repository/, 'with the reason';
        like $r->{stderr}, qr/^karr: write access to the remote 'origin' \(\Q$work\E\/origin\.git\) was denied: /m,
            'C1 names the remote and its push URL';
        like $r->{stderr}, qr/Nothing was changed: this command's change was taken back, and this clone is now read-only for the board\./,
            'and says the change was taken back';
        unlike $r->{stderr}, qr/Push retry/, 'no retry banner';
        unlike $r->{stderr}, qr/git push failed: git push failed:/, 'no doubled prefix';
        my @shown = $r->{stderr} =~ /(failed to create temporary file)/g;
        is scalar @shown, 1, 'the transport error is shown once';
    };
}

done_testing;
