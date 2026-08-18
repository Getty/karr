use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use File::Temp qw( tempdir );
use File::Spec ();
use App::karr::Git;

# Ticket #208: a push that connected to the right repository and wrote to the
# wrong one, and said it had worked.
#
# libgit2's local transport pushes by opening remote->url -- the *fetch* URL --
# instead of the URL it connected to for the push. So a remote whose push URL
# resolves to a local path other than its fetch URL published refs/karr/* into
# the fetch URL's repository and returned success. Nothing failed, so the git
# CLI fallback never ran, and the mirror update behind the push then recorded
# the remote as holding refs it had never received.
#
# Both shapes that produce a distinct push URL were measured to do this on the
# libgit2 1.9.3 Alien::Libgit2 carries -- an explicit remote.<name>.pushurl and
# url.<base>.pushInsteadOf -- while git 2.47.3 landed at the push URL in every
# one of them.
#
# The two subtests that pin the fix read back *which of the two bare
# repositories actually received the refs*, rather than trusting the return
# value: a push URL aimed at a path that does not exist fails as "unsupported
# URL protocol" or "failed to resolve path", which looks exactly like no
# rewrite having happened, and reading only the outcome of the call has led to
# the wrong conclusion twice (#203, #204). Both repositories here exist and are
# empty at the start, so exactly one of them ends up with the board.
#
# The remaining subtests are the other half of the bargain: the detection has
# to stay narrow. An ordinary board -- no push URL at all -- and a push URL
# that names the same place as the fetch URL must still go out natively, and a
# push URL on a real transport must be left to libgit2, which is correct there.

my $TMP = tempdir( CLEANUP => 1 );
my $N   = 0;

sub git_ok {
    my (@argv) = @_;
    my $rc = system( 'git', @argv );
    die "git @argv failed\n" if $rc != 0;
    return 1;
}

sub bare_repo {
    my ($name) = @_;
    my $path = File::Spec->catdir( $TMP, "$name.git" );
    git_ok( 'init', '--quiet', '--bare', $path );
    return $path;
}

sub work_repo {
    my ($origin) = @_;
    my $path = File::Spec->catdir( $TMP, 'work' . ++$N );
    git_ok( 'init', '--quiet', $path );
    git_ok( '-C', $path, 'config', 'user.name',  'karr test' );
    git_ok( '-C', $path, 'config', 'user.email', 'karr@example.com' );
    git_ok( '-C', $path, 'remote', 'add', 'origin', $origin );
    return $path;
}

# The board refs a bare repository actually holds, read with the git CLI so
# that the assertion does not depend on the library under test.
sub board_refs {
    my ($repo) = @_;
    my $out = `git -C \Q$repo\E for-each-ref --format='%(refname)' refs/karr/ 2>&1`;
    return [ sort grep { length } split /\n/, $out // '' ];
}

my $REF = 'refs/karr/tasks/1/data';

subtest 'explicit pushurl: the board lands at the push URL' => sub {
    my $fetch = bare_repo('pushurl-fetch');
    my $push  = bare_repo('pushurl-push');
    my $work  = work_repo($fetch);
    git_ok( '-C', $work, 'config', 'remote.origin.pushurl', $push );

    my $git = App::karr::Git->new( dir => $work );
    $git->write_ref( $REF, "card\n" );

    ok( $git->push('origin'), 'push reported success' );
    is_deeply( board_refs($push), [$REF],
        'the push URL repository has the board' );
    is_deeply( board_refs($fetch), [],
        'the fetch URL repository was not written to' );
};

subtest 'url.<base>.pushInsteadOf: the board lands at the push URL' => sub {
    my $fetch_base = bare_repo('rewrite-fetch');
    my $push_base  = bare_repo('rewrite-push');
    my $fetch      = File::Spec->catdir( $fetch_base, 'board.git' );
    my $push       = File::Spec->catdir( $push_base,  'board.git' );
    git_ok( 'init', '--quiet', '--bare', $_ ) for $fetch, $push;

    my $work = work_repo('karr-208-split:board.git');
    git_ok( '-C', $work, 'config',
        "url.$fetch_base/.insteadOf", 'karr-208-split:' );
    git_ok( '-C', $work, 'config',
        "url.$push_base/.pushInsteadOf", 'karr-208-split:' );

    my $git = App::karr::Git->new( dir => $work );
    $git->write_ref( $REF, "card\n" );

    ok( $git->push('origin'), 'push reported success' );
    is_deeply( board_refs($push), [$REF],
        'the push URL repository has the board' );
    is_deeply( board_refs($fetch), [],
        'the fetch URL repository was not written to' );
};

subtest 'without the CLI there is a named refusal, not a silent success' => sub {
    my $fetch = bare_repo('refuse-fetch');
    my $push  = bare_repo('refuse-push');
    my $work  = work_repo($fetch);
    git_ok( '-C', $work, 'config', 'remote.origin.pushurl', $push );

    my $git = App::karr::Git->new( dir => $work );
    $git->write_ref( $REF, "card\n" );

    local $ENV{KARR_NO_CLI_FALLBACK} = 1;
    ok( !$git->push('origin'), 'push reports failure with no route left' );
    my $why = $git->last_error // '';
    like( $why, qr/\Q$push\E/, 'the error names the push URL' );
    like( $why, qr/\Q$fetch\E/, 'the error names the fetch URL' );
    like( $why, qr/#208/,       'the error names the ticket' );
    is_deeply( board_refs($fetch), [],
        'nothing was written to the fetch URL repository' );
    is_deeply( board_refs($push), [],
        'and nothing reached the push URL either' );
};

subtest 'an ordinary local remote still pushes natively' => sub {
    my $fetch = bare_repo('plain-fetch');
    my $work  = work_repo($fetch);

    my $git = App::karr::Git->new( dir => $work );
    $git->write_ref( $REF, "card\n" );

    my @cli;
    no warnings 'redefine';
    local *App::karr::Git::_cli_transport = sub {
        push @cli, $_[1];
        return 0;
    };
    ok( $git->push('origin'), 'push reported success' );
    is_deeply( \@cli, [], 'the git CLI was not involved' );
    is_deeply( board_refs($fetch), [$REF], 'the remote has the board' );
};

subtest 'a push URL naming the fetch URL is not a split remote' => sub {
    my $fetch = bare_repo('same-fetch');
    my $work  = work_repo($fetch);
    git_ok( '-C', $work, 'config', 'remote.origin.pushurl', $fetch );

    my $git = App::karr::Git->new( dir => $work );
    $git->write_ref( $REF, "card\n" );

    my @cli;
    no warnings 'redefine';
    local *App::karr::Git::_cli_transport = sub {
        push @cli, $_[1];
        return 0;
    };
    ok( $git->push('origin'), 'push reported success' );
    is_deeply( \@cli, [], 'the git CLI was not involved' );
    is_deeply( board_refs($fetch), [$REF], 'the remote has the board' );
};

subtest 'a push URL on a real transport is left to libgit2' => sub {
    # Not pushed -- nothing here may reach a network. The question is only
    # whether the detection claims this remote, and it must not: libgit2
    # honours the push URL on every transport it actually speaks, so routing
    # an ssh or https board through the CLI would be cost with no cause.
    my $fetch = bare_repo('remote-push-url-fetch');
    my $work  = work_repo($fetch);
    git_ok( '-C', $work, 'config', 'remote.origin.pushurl',
        'ssh://git@karr-208.invalid/board.git' );

    my $git  = App::karr::Git->new( dir => $work );
    my $repo = $git->_repo;
    ok( $repo, 'repository opened' );
    my $r = $repo->remote('origin');
    is( App::karr::Git::_remote_pushurl($r),
        'ssh://git@karr-208.invalid/board.git',
        'the resolved push URL is readable' );
    is( scalar App::karr::Git::_misdirected_local_push($r), undef,
        'an ssh push URL is not treated as a misdirected local push' );
};

subtest 'which URLs count as libgit2 local-transport paths' => sub {
    my %local = (
        '/srv/git/karr.git'          => 1,
        'relative/karr.git'          => 1,
        './karr.git'                 => 1,
        'file:///srv/git/karr.git'   => 1,
        'ssh://git@example.com/x'    => 0,
        'git://example.com/x'        => 0,
        'https://example.com/x.git'  => 0,
        'http://example.com/x.git'   => 0,
        'git@example.com:karr.git'   => 0,
        'board:karr.git'             => 0,
    );
    for my $url ( sort keys %local ) {
        is( App::karr::Git::_is_local_url($url), $local{$url},
            "$url -> " . ( $local{$url} ? 'local path' : 'real transport' ) );
    }
};

done_testing;
