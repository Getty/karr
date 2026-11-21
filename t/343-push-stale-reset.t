#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use Cwd ();
use lib Cwd::abs_path('lib');
use TestGit qw( require_git_c );
require_git_c();
use File::Temp qw( tempdir );
use App::karr::Git;
use Git::Native::Remote;

# push_stale is documented as "empty after any push that is not the board's",
# reset at the start of every push. The board push resets it; push_ref and
# push_foundation must not leave the earlier board push's stale list standing.
# push_rejections is documented as reset at the start of every push attempt;
# that is pinned separately below, on the early returns, because a push that
# reaches _push_refspecs resets it there anyway and so cannot show the gap.
#
# Scene: one App::karr::Git object (clone a). Clone b publishes the board ref
# after a's last pull, so a's next board push comes back stale.

sub sh {
    my $rc = system( 'git', @_ );
    die "git @_ failed\n" if $rc;
}

sub scene {
    my $d = tempdir( CLEANUP => 1 );
    sh( 'init', '-q', '--bare', "$d/origin.git" );
    for my $c (qw( a b )) {
        sh( 'clone', '-q', "$d/origin.git", "$d/$c" );
        sh( '-C', "$d/$c", 'config', 'user.email', "$c\@karr.test" );
        sh( '-C', "$d/$c", 'config', 'user.name',  "agent-$c" );
    }
    my $a = App::karr::Git->new( dir => "$d/a" );
    my $b = App::karr::Git->new( dir => "$d/b" );
    my $card = 'refs/karr/tasks/1/data';
    $a->write_ref( $card, "v1\n" );
    ok( $a->push, 'seed: a publishes the card' ) or diag $a->last_error;
    ok( $b->pull, 'seed: b pulls it' ) or diag $b->last_error;
    $b->write_ref( $card, "from b\n" );
    ok( $b->push, 'seed: b publishes its version' ) or diag $b->last_error;
    $a->write_ref( $card, "from a\n" );
    ok( !$a->push, 'a board push after b raced it does not land' );
    is_deeply( $a->push_stale, [$card], 'precondition: that board push came back stale' );
    return ( $a, $d );
}

subtest 'push_ref after a stale board push' => sub {
    my ( $a, $d ) = scene();
    my $helper = 'refs/karr-helper/note';
    $a->write_ref( $helper, "hello\n" );
    ok( $a->push_ref($helper), 'the helper ref push lands' ) or diag $a->last_error;
    is_deeply( $a->push_stale, [], 'push_stale is empty after a push_ref' );
};

subtest 'push_foundation after a stale board push' => sub {
    my ( $a, $d ) = scene();
    $a->write_ref( 'refs/karr-foundation/chains/x', "{}\n" );
    ok( $a->push_foundation, 'the foundation push lands' ) or diag $a->last_error;
    is_deeply( $a->push_stale, [], 'push_stale is empty after a push_foundation' );
};

# A bare origin whose pre-receive hook declines everything, plus a clone of it.
sub declining_scene {
    my $d = tempdir( CLEANUP => 1 );
    sh( 'init', '-q', '--bare', "$d/origin.git" );
    my $hook = "$d/origin.git/hooks/pre-receive";
    open my $fh, '>', $hook or die "$hook: $!";
    print {$fh} "#!/bin/sh\necho 'protected' >&2\nexit 1\n";
    close $fh;
    chmod 0755, $hook;
    sh( 'clone', '-q', "$d/origin.git", "$d/a" ) ;
    sh( '-C', "$d/a", 'config', 'user.email', 'a@karr.test' );
    sh( '-C', "$d/a", 'config', 'user.name',  'agent-a' );
    my $git = App::karr::Git->new( dir => "$d/a" );
    $git->write_ref( 'refs/karr-helper/note', "hello\n" );
    # libgit2's local transport skips a bare repo's hooks (see t/78), so the
    # native push is made to fail and the git CLI fallback, which runs them, sends it.
    my $ok = do {
        no warnings 'redefine';
        local *Git::Native::Remote::push = sub { die "forced libgit2 push failure\n" };
        $git->push_ref('refs/karr-helper/note');
    };
    ok( !$ok, 'precondition: the hook declines the helper ref push' );
    ok( scalar @{ $git->push_rejections }, 'precondition: push_rejections is non-empty' )
        or diag $git->last_error;
    return ( $git, $d );
}

# The early returns that report success without sending anything used to leave
# the earlier push's rejections standing.
subtest 'push_ref to an unconfigured remote clears earlier rejections' => sub {
    my ($git) = declining_scene();
    ok( $git->push_ref( 'refs/karr-helper/note', 'nowhere' ), 'no remote: a no-op success' );
    is_deeply( $git->push_rejections, [], 'push_rejections is empty' );
};

subtest 'push_foundation to an unconfigured remote clears earlier rejections' => sub {
    my ($git) = declining_scene();
    ok( $git->push_foundation('nowhere'), 'no remote: a no-op success' );
    is_deeply( $git->push_rejections, [], 'push_rejections is empty' );
};

subtest 'push_foundation with nothing to push clears earlier rejections' => sub {
    my ($git) = declining_scene();
    ok( $git->push_foundation, 'nothing under refs/karr-foundation/: a no-op success' )
        or diag $git->last_error;
    is_deeply( $git->push_rejections, [], 'push_rejections is empty' );
};

done_testing;
