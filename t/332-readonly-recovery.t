#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use Cwd ();
use lib Cwd::abs_path('lib');
use TestGit qw( require_git_c );
require_git_c();
use TestDenied qw( new_scene run deny allow pushes reset_log refs_dump karr_config can_deny add_mirror origin_has_refs );
use JSON::PP ();

# Ticket k333, parts B/E: how a read-only clone gets out of the state --
# a changed push URL, a `karr sync` whose push lands, a `karr readonly off` --
# and what `karr sync` does while the state holds.
#
# What a regression would show: a state that outlives a changed push URL (the
# next write refused although it could write), stale keys that are never
# dropped, a sync that cannot clear the state or clears it although the push
# was denied, or an `on` clone that pushes on sync.

plan skip_all => 'running as root: it ignores the read-only mode of the bare repository'
    unless can_deny();

my $json = JSON::PP->new;

subtest 'a changed push URL lifts the state; the next write goes through; the stale keys are dropped after that push' => sub {
    my $s = new_scene();
    my $mirror = add_mirror($s);
    deny($s);

    my $r = run( $s, 'create', 'first try' );
    is $r->{exit}, 1, 'denied';
    is karr_config($s)->{'karr.readonly'}, 'denied', 'state recorded';

    system( 'git', '-C', $s->{clone}, 'remote', 'set-url', '--push', 'origin', $mirror ) == 0 or die;

    $r = run( $s, 'readonly', '--json' );
    my $j = $json->decode( $r->{stdout} );
    ok !$j->{applies}, 'readonly: the recorded state no longer applies';
    is $j->{current_push_url}, $mirror, 'to the new push URL';
    $r = run( $s, 'list' );
    unlike $r->{stderr}, qr/cannot write the board/, 'reads no longer warn';
    is karr_config($s)->{'karr.readonly'}, 'denied', 'the stale keys are still there before the next push';

    reset_log($s);
    $r = run( $s, 'create', 'second try' );
    is $r->{exit}, 0, 'the next write goes through' or diag $r->{stderr};
    like $r->{stdout}, qr/^Created task 1: second try$/m, 'card number 1: the denied attempt did not burn it';
    unlike $r->{stdout}, qr/saved in this clone/, 'and no "not on the remote" note';
    is pushes($s), 1, 'one push';
    ok origin_has_refs( $mirror, 'refs/karr/tasks/1' ), 'the card is on the writable remote';
    is_deeply karr_config($s), {}, 'the stale state is dropped after the push that landed';
    unlike $r->{stderr}, qr/read-only|cannot write the board|not on the remote/, 'nothing to warn about';
};

subtest 'karr sync with the remote writable again: the push lands and clears the state' => sub {
    my $s = new_scene();
    deny($s);
    run( $s, 'create', 'x' );
    is karr_config($s)->{'karr.readonly'}, 'denied', 'denied';

    allow($s);
    reset_log($s);
    my $r = run( $s, 'sync' );
    is $r->{exit}, 0, 'exit 0' or diag $r->{stderr};
    like $r->{stdout} . $r->{stderr}, qr/Write access to 'origin' works again/, 'says the access works again';
    like $r->{stdout} . $r->{stderr}, qr/Pushing refs\/karr\/ to remote/, "the sync did push (or probe): the state is not cleared without asking the remote";
    is_deeply karr_config($s), {}, 'the state is cleared';

    $r = run( $s, 'create', 'after sync' );
    is $r->{exit}, 0, 'a write is accepted again';
    like $r->{stdout}, qr/^Created task 1: after sync$/m, 'with number 1';
    ok origin_has_refs( $s->{origin}, 'refs/karr/tasks/1' ), 'and lands on the remote';
};

subtest 'karr sync while still denied: pushes, is denied, the state stays' => sub {
    my $s = new_scene();
    deny($s);
    run( $s, 'create', 'x' );
    my $state = karr_config($s);
    is $state->{'karr.readonly'}, 'denied', 'denied';

    reset_log($s);
    my $before = refs_dump( $s->{clone} );
    my $r = run( $s, 'sync' );
    is $r->{exit}, 1, 'exit 1';
    like $r->{stdout} . $r->{stderr}, qr/Pushing refs\/karr\/ to remote/, "sync is the explicit retry: it did push";
    like $r->{stderr}, qr/^karr: write access to the remote 'origin' \(\Q$s->{origin}\E\) was denied: /m, 'says denied';
    like $r->{stderr}, qr/Nothing was published: this clone stays read-only for the board\./, 'and that the state stays';
    unlike $r->{stdout} . $r->{stderr}, qr/works again/, 'not the recovery line';
    is_deeply karr_config($s), $state, 'the state is exactly as it was, time included';
    is refs_dump( $s->{clone} ), $before, 'no ref changed';
};

subtest 'karr readonly off with the remote writable: the next write pushes and stays off' => sub {
    my $s = new_scene();
    deny($s);
    run( $s, 'create', 'x' );
    allow($s);

    is run( $s, 'readonly', 'off' )->{exit}, 0, 'off';
    reset_log($s);
    my $r = run( $s, 'create', 'y' );
    is $r->{exit}, 0, 'the write goes through';
    is pushes($s), 1, 'pushing again';
    is_deeply karr_config($s), {}, 'and no state comes back';
};

subtest 'karr sync in `on`: pulls only and says the push was skipped' => sub {
    my $s = new_scene();
    run( $s, 'create', 'unpublished', '--local-only' );
    ok !origin_has_refs( $s->{origin}, 'refs/karr/tasks/1' ), 'precondition: a card only in this clone';
    run( $s, 'readonly', 'on' );

    reset_log($s);
    my $r = run( $s, 'sync' );
    is $r->{exit}, 0, 'exit 0';
    like $r->{stdout} . $r->{stderr}, qr/Push skipped: this clone is read-only for the board \(karr readonly on\)\./, 'one line saying the push was skipped';
    is pushes($s), 0, 'no push was attempted';
    ok !origin_has_refs( $s->{origin}, 'refs/karr/tasks/1' ), 'the card is still not on the remote';
    is karr_config($s)->{'karr.readonly'}, 'on', 'the state stays on';
};

done_testing;
