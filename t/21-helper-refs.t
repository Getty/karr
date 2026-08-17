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

use App::karr::Git;

my $ROOT = abs_path('.');
my $BIN  = "$ROOT/bin/karr";

sub _git_ok {
    my (@cmd) = @_;
    my $rc = system(@cmd);
    is($rc, 0, "@cmd");
}

sub _init_bare_remote {
    my $bare = tempdir( CLEANUP => 1 );
    _git_ok( 'git', 'init', '--bare', $bare );
    return $bare;
}

sub _init_repo {
    my ( $repo, $email, $name ) = @_;
    _git_ok( 'git', 'init', $repo );
    _git_ok( 'git', '-C', $repo, 'config', 'user.email', $email );
    _git_ok( 'git', '-C', $repo, 'config', 'user.name', $name );
    _git_ok( 'git', '-C', $repo, 'commit', '--allow-empty', '-m', 'init' );
}

sub _default_branch {
    my ($repo) = @_;
    my $branch = `git -C '$repo' rev-parse --abbrev-ref HEAD 2>/dev/null`;
    chomp $branch;
    return $branch;
}

sub _run_karr {
    my ( $cwd, @argv ) = @_;
    my $old = getcwd();
    chdir $cwd or die "chdir $cwd: $!";

    my $stderr = gensym;
    my $pid = open3(
        undef,
        my $stdout_fh,
        $stderr,
        $^X,
        "-I$ROOT/lib",
        $BIN,
        @argv,
    );

    my $stdout = do { local $/; <$stdout_fh> };
    my $stderr_text = do { local $/; <$stderr> };
    waitpid( $pid, 0 );
    my $exit = $? >> 8;

    chdir $old or die "chdir $old: $!";

    return {
        exit   => $exit,
        stdout => defined $stdout ? $stdout : '',
        stderr => defined $stderr_text ? $stderr_text : '',
    };
}

subtest 'git helper API normalizes refs and blocks protected namespaces' => sub {
    my $repo = tempdir( CLEANUP => 1 );
    _init_repo( $repo, 'test@example.com', 'Test User' );

    my $git = App::karr::Git->new( dir => $repo );

    can_ok( $git, qw( normalize_ref_name validate_helper_ref push_ref pull_ref ) );
    is(
        $git->normalize_ref_name('superpowers/spec/1234.md'),
        'refs/superpowers/spec/1234.md',
        'bare ref is normalized below refs/'
    );
    is(
        $git->normalize_ref_name('refs/superpowers/spec/1234.md'),
        'refs/superpowers/spec/1234.md',
        'full ref remains unchanged'
    );

    ok(
        eval { $git->validate_helper_ref('refs/superpowers/spec/1234.md'); 1 },
        'non-reserved helper ref is accepted'
    ) or diag $@;

    # Ticket #63: only refs/heads/ was covered here, so deleting any other
    # entry from validate_helper_ref's blocklist -- refs/karr/ included, which
    # would let `karr set-refs` overwrite board state -- left the suite green.
    # Every entry gets its own case.
    for my $blocked (
        'refs/heads/main',
        'refs/tags/v1.0',
        'refs/remotes/origin/main',
        'refs/bisect/bad',
        'refs/replace/abc123',
        'refs/karr/tasks/1/data',
        'refs/karr/config',
        'refs/karr-local/tasks/1/lock',
        'refs/karr-local/deleted/tasks/1/data',
        # Ticket #199: the mirror every pull reconciles against, and the
        # parking lot for the local side of a conflict. A hand-written mirror
        # entry does not corrupt a payload -- it makes the next pull decide
        # the wrong one of its four cases and delete or force-push a card.
        'refs/karr-remote/origin/tasks/1/data',
        'refs/karr-conflict/tasks/1/data',
        'refs/stash',
        'refs/stash/mine',
      )
    {
        ok(
            !eval { $git->validate_helper_ref($blocked); 1 },
            "$blocked is rejected"
        );
        like( $@, qr/protected|blocked/i, "$blocked error is descriptive" );
    }

    # The bare form normalizes to the same protected namespace, so it must be
    # rejected too -- the blocklist is checked after normalize_ref_name.
    ok(
        !eval { $git->validate_helper_ref('karr/tasks/1/data'); 1 },
        'the bare form of a protected ref is rejected as well'
    );

    # Not blocked: a name that merely starts with the same letters.
    ok(
        eval { $git->validate_helper_ref('refs/karrots/notes'); 1 },
        'a namespace that only shares a prefix is still allowed'
    ) or diag $@;
};

subtest 'set-refs and get-refs roundtrip over a remote' => sub {
    my $bare = _init_bare_remote();

    my $repo_a = tempdir( CLEANUP => 1 );
    _init_repo( $repo_a, 'a@test.com', 'Agent A' );
    _git_ok( 'git', '-C', $repo_a, 'remote', 'add', 'origin', $bare );
    my $branch = _default_branch($repo_a);
    _git_ok( 'git', '-C', $repo_a, 'push', 'origin', $branch );

    my $repo_b = tempdir( CLEANUP => 1 );
    _git_ok( 'git', 'clone', $bare, $repo_b );
    _git_ok( 'git', '-C', $repo_b, 'config', 'user.email', 'b@test.com' );
    _git_ok( 'git', '-C', $repo_b, 'config', 'user.name', 'Agent B' );

    my $set = _run_karr( $repo_a, 'set-refs', 'superpowers/spec/1234.md', 'hello', 'world' );
    is( $set->{exit}, 0, 'set-refs exits successfully' );
    is( $set->{stdout}, '', 'set-refs keeps payload off stdout' );
    like( $set->{stderr}, qr{refs/superpowers/spec/1234\.md}, 'set-refs reports target ref on stderr' );

    my $get = _run_karr( $repo_b, 'get-refs', 'superpowers/spec/1234.md' );
    is( $get->{exit}, 0, 'get-refs exits successfully' );
    is( $get->{stdout}, "hello world\n", 'get-refs prints payload to stdout' );
    like( $get->{stderr}, qr{refs/superpowers/spec/1234\.md}, 'get-refs reports fetch/read status on stderr' );
};

subtest 'protected namespaces are rejected from the CLI' => sub {
    my $repo = tempdir( CLEANUP => 1 );
    _init_repo( $repo, 'test@example.com', 'Test User' );

    my $rv = _run_karr( $repo, 'set-refs', 'heads/main', 'nope' );
    isnt( $rv->{exit}, 0, 'set-refs fails for protected namespaces' );
    is( $rv->{stdout}, '', 'error path keeps stdout empty' );
    like( $rv->{stderr}, qr/protected|blocked/i, 'stderr explains why the ref is rejected' );

    # Ticket #199: the sync machinery's own namespaces went through. Asserted
    # end to end rather than only on validate_helper_ref, because the damage is
    # done by the ref existing afterwards -- the next pull reads it as "the OID
    # the remote had at the last sync" and reconciles against a lie.
    for my $ref (
        'refs/karr-remote/origin/tasks/1/data',
        'refs/karr-conflict/tasks/1/data',
      )
    {
        my $sync = _run_karr( $repo, 'set-refs', $ref, 'junk' );
        isnt( $sync->{exit}, 0, "set-refs fails for $ref" );
        like( $sync->{stderr}, qr/protected|blocked/i,
            "stderr explains why $ref is rejected" );
        my $exists = `git -C '$repo' rev-parse --verify --quiet $ref`;
        is( $exists, '', "$ref was not created" );
    }
};

done_testing;
