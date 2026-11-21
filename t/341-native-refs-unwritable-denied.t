#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use Cwd ();
use lib Cwd::abs_path('lib');
use TestGit qw( require_git_c );
require_git_c();
use TestDenied qw( new_scene run allow karr_config can_deny );

# Ticket k343 (follow-up of k333): a local bare remote whose refs/ this user
# cannot write (objects/ stays writable) is "denied" over the native route as
# it is over the CLI route. Natively libgit2 reports per-ref failures such as
# "failed to create locked file '<remote>/refs/...lock': Permission denied"
# (or "unable to create directory for ./refs/karr/x"); those are about the
# remote's own files, not the remote's answer about the ref, so they must end
# in the same verdict: the denial message (exit 1), the change taken back, the
# clone read-only for the board, and no pull-and-retry as if the push were
# merely stale.
#
# Two shapes of "refs/ unwritable":
#   locked - refs/karr/ exists on the remote and is unwritable (lock file)
#   mkdir  - refs/ is unwritable and refs/karr/ does not exist (directory)
# plus the objects/-unwritable remote, pinned on both routes.

plan skip_all => 'running as root: it ignores the read-only mode of the bare repository'
    unless can_deny();

my $DENIED = qr/^karr: write access to the remote 'origin' \(.*\) was denied: /m;
my $STALE  = qr/pulling that in first|changed on the remote/;

sub make_scene {
    my ($shape) = @_;
    my $s = new_scene( seed => 1 );
    my $o = $s->{origin};
    if ( $shape eq 'locked' ) {
        system( 'chmod', '-R', 'a-w', "$o/refs" );
    }
    elsif ( $shape eq 'mkdir' ) {
        system( 'git', '-C', $o, 'pack-refs', '--all' ) == 0 or die 'pack-refs';
        system( 'rm', '-rf', "$o/refs/karr" );
        system( 'chmod', 'a-w', "$o/refs" );
    }
    elsif ( $shape eq 'objects' ) {
        system( 'chmod', '-R', 'a-w', "$o/objects" );
    }
    else { die "shape $shape" }
    return $s;
}

sub check_denied {
    my ( $s, $r ) = @_;
    is $r->{exit}, 1, 'exit 1 (the exit code does not change)';
    like $r->{stderr}, $DENIED, 'ends on the denial message naming the remote';
    like $r->{stderr}, qr/cannot write the remote repository/, 'with the reason';
    like $r->{stderr}, qr/this command's change was taken back/, 'the change was taken back';
    unlike $r->{stderr}, $STALE, 'not the stale "pull that in first" path';
    my $c = karr_config($s);
    ok scalar( grep { /^karr\.readonly/ } keys %$c ), 'karr.readonly is set in git config'
        or diag explain $c;
    my $ro = run( $s, 'readonly' );
    like $ro->{stdout} . $ro->{stderr}, qr/read-only|denied/i, '`karr readonly` reports it';
    my $again = run( $s, 'create', 'second' );
    is $again->{exit}, 1, 'a second write exits 1';
    like $again->{stderr}, qr/this clone is read-only for the board/, 'and is refused at the read-only door';
}

for my $case (
    [ 'native', 'locked',  1 ],
    [ 'native', 'mkdir',   1 ],
    [ 'cli',    'locked',  0 ],
    [ 'native', 'objects', 1 ],
    [ 'cli',    'objects', 0 ],
) {
    my ( $route, $shape, $native ) = @$case;
    subtest "$route route, remote with unwritable $shape" => sub {
        my $s = make_scene($shape);
        local $ENV{KARR_NO_CLI_FALLBACK} = $native ? 1 : 0;
        my $r = run( $s, 'create', 'probe' );
        diag "stderr: $r->{stderr}" if $ENV{KARR_TEST_DIAG};
        check_denied( $s, $r );
        allow($s);
    };
}

# Partial landing: only refs/karr/tasks/ is unwritable, so next-id and the log
# land and the new card ref does not. The clone could write part of the push:
# that is a rejection of one ref, not a denial, and the clone stays writable.
subtest 'native route, only refs/karr/tasks unwritable: partial landing is not a denial' => sub {
    my $s = new_scene( seed => 1 );
    my $o = $s->{origin};
    my $before = `git -C '$o' rev-parse refs/karr/meta/next-id`;
    system( 'chmod', '-R', 'a-w', "$o/refs/karr/tasks" );
    local $ENV{KARR_NO_CLI_FALLBACK} = 1;
    my $r = run( $s, 'create', 'probe' );
    diag "stderr: $r->{stderr}" if $ENV{KARR_TEST_DIAG};

    my $after  = `git -C '$o' rev-parse refs/karr/meta/next-id`;
    my $clones = `git -C '$s->{clone}' rev-parse refs/karr/meta/next-id`;
    isnt $after, $before, 'next-id reached the origin (the scenario is the partial one)';
    is $after, $clones, 'and equals the clone\'s';

    is $r->{exit}, 1, 'exit 1 as for a rejected push';
    unlike $r->{stderr}, qr/Nothing was changed/, 'does not say nothing was changed';
    unlike $r->{stderr}, qr/was denied/, 'does not say denied';
    like $r->{stderr}, qr{tasks/2|#2}, 'the refused card ref is named';
    my $c = karr_config($s);
    ok !scalar( grep { /^karr\.readonly/ } keys %$c ), 'no karr.readonly* in git config'
        or diag explain $c;
    my $ro = run( $s, 'readonly' );
    like $ro->{stdout}, qr/Read-only: off/, '`karr readonly` prints Read-only: off';
    allow($s);
};

done_testing;
