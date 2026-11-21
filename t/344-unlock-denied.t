#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use Cwd ();
use lib Cwd::abs_path('lib');
use TestGit qw( require_git_c );
require_git_c();
use TestDenied qw( new_scene run deny allow refs_dump karr_config can_deny );
use App::karr::Git;
use App::karr::Lock;

# Ticket k340 (follow-up of k333): on a denied push, `karr unlock` must not
# let the user believe the lock is still there. A lock under refs/karr-local/
# is this clone's own and never published: a denied push has nothing to do
# with it, it stays broken. The output (stdout + stderr, what the user sees)
# must name every lock that is gone afterwards as broken, and must never say
# "Nothing was changed" while a current-layout lock was in fact broken. A
# pre-#93 lock inside refs/karr/* is journaled and restored by the take-back;
# that one may be covered by "Nothing was changed" and must not be called
# broken. Exit stays 1 (ADR 0002).

plan skip_all => 'running as root: it ignores the read-only mode of the bare repository'
    unless can_deny();

sub lock_ref { "refs/karr-local/tasks/$_[0]/lock" }
sub has_ref  { my ( $s, $ref ) = @_; return scalar length `git -C '$s->{clone}' for-each-ref $ref` }
sub seen     { my ($r) = @_; return $r->{stdout} . $r->{stderr} }

# unlock itself writes nothing a push would carry (no activity log entry), so
# an unlock alone never reaches the remote. A denial needs something
# unpublished in the clone for the push to have a reason to run.
sub pending { my ($s) = @_; run( $s, 'create', 'pending', '--local-only' )->{exit} == 0 or die 'local create failed' }

sub git_of { App::karr::Git->new( dir => $_[0]{clone} ) }

# A scene with N cards, each holding a current-layout lock, then denied.
sub locked_scene {
    my ($n) = @_;
    my $s  = new_scene( seed => $n );
    my $lk = App::karr::Lock->new( git => git_of($s), ttl => 3600 );
    $lk->acquire( $_, 'a@karr.test' ) for 1 .. $n;
    ok has_ref( $s, lock_ref($_) ), "precondition: lock on task $_ exists" for 1 .. $n;
    pending($s);
    deny($s);
    return $s;
}

subtest 'karr unlock ID: the broken lock is named, nothing claims it untouched' => sub {
    my $s = locked_scene(2);
    my $log_before = refs_dump( $s->{clone}, 'refs/karr/log' );

    my $r = run( $s, 'unlock', '1' );
    is $r->{exit}, 1, 'exit 1 (ADR 0002)';
    like $r->{stderr}, qr/was denied/, 'the denial is reported';
    my $all = seen($r);
    like   $all, qr/brok/i,              'the output says broken/broke';
    like   $all, qr/lock on task 1\b/i,  'and names the lock on task 1';
    unlike $all, qr/Nothing was changed/, 'and never says "Nothing was changed"';

    ok !has_ref( $s, lock_ref(1) ), 'the lock is really gone (not restored)';
    ok  has_ref( $s, lock_ref(2) ), 'the other lock is untouched';
    is refs_dump( $s->{clone}, 'refs/karr/log' ), $log_before, 'no log entry left behind';
    is karr_config($s)->{'karr.readonly'}, 'denied', 'the clone is now read-only';

    my $r2 = run( $s, 'unlock', '2' );
    is $r2->{exit}, 1, 'second unlock refused';
    like $r2->{stderr}, qr/this clone is read-only for the board/, 'at the read-only door';
    ok has_ref( $s, lock_ref(2) ), 'lock 2 survived the refused unlock';

    my $rep = run( $s, 'unlock' );
    is $rep->{exit}, 0, 'the report still works read-only';
    unlike $rep->{stdout}, qr/Task\s+1\s+held/, 'report: no lock on task 1';
    like   $rep->{stdout}, qr/Task\s+2\s+held/, 'report: task 2 still locked';
    allow($s);
};

subtest 'karr unlock --all: both broken locks are named' => sub {
    my $s = locked_scene(2);
    my $r = run( $s, 'unlock', '--all' );
    is $r->{exit}, 1, 'exit 1';
    like $r->{stderr}, qr/was denied/, 'the denial is reported';
    my $all = seen($r);
    like   $all, qr/brok/i,              'the output says broken/broke';
    like   $all, qr/lock on task $_\b/i, "and names the lock on task $_" for 1, 2;
    unlike $all, qr/Nothing was changed/, 'and never says "Nothing was changed"';
    ok !has_ref( $s, lock_ref($_) ), "lock $_ is gone" for 1, 2;
    is karr_config($s)->{'karr.readonly'}, 'denied', 'the clone is now read-only';
    allow($s);
};

subtest 'nothing unpublished: unlock never pushes, so there is no denial (current behaviour)' => sub {
    my $s = new_scene( seed => 1 );
    App::karr::Lock->new( git => git_of($s), ttl => 3600 )->acquire( 1, 'a@karr.test' );
    deny($s);
    my $r = run( $s, 'unlock', '1' );
    is $r->{exit}, 0, 'exit 0: nothing to publish, nothing denied';
    like $r->{stdout}, qr/Broke lock on task 1/, 'the lock is reported broken';
    ok !has_ref( $s, lock_ref(1) ), 'and it is gone';
    ok !defined karr_config($s)->{'karr.readonly'}, 'the clone is not read-only';
    allow($s);
};

subtest 'a pre-#93 lock alone: restored by the take-back, never called broken' => sub {
    my $s   = new_scene( seed => 1 );
    my $git = git_of($s);
    my $leg = App::karr::Lock->new( git => $git )->legacy_ref_name(1);
    $git->write_ref( $leg, "a\@karr.test\n2026-11-21T00:00:00Z\n" );
    pending($s);
    deny($s);
    my $r = run( $s, 'unlock', '1' );
    is $r->{exit}, 1, 'exit 1';
    like $r->{stderr}, qr/was denied/, 'the denial is reported';
    ok has_ref( $s, $leg ), 'the legacy lock is back (its deletion was taken back)';
    unlike seen($r), qr/brok/i, 'so the output does not call it broken';
    is karr_config($s)->{'karr.readonly'}, 'denied', 'the clone is now read-only';
    allow($s);
};

subtest 'both kinds on one card: whatever is gone is named broken, whatever is back is not' => sub {
    my $s   = new_scene( seed => 1 );
    my $git = git_of($s);
    my $lk  = App::karr::Lock->new( git => $git, ttl => 3600 );
    my $leg = $lk->legacy_ref_name(1);
    $lk->acquire( 1, 'a@karr.test' );
    $git->write_ref( $leg, "a\@karr.test\n2026-11-21T00:00:00Z\n" );
    pending($s);
    deny($s);
    my $r   = run( $s, 'unlock', '1' );
    my $all = seen($r);
    diag "mixed lock: exit=$r->{exit} current="
        . ( has_ref( $s, lock_ref(1) ) ? 'BACK' : 'GONE' )
        . ' legacy=' . ( has_ref( $s, $leg ) ? 'BACK' : 'GONE' ) . "\n$all";
    is $r->{exit}, 1, 'exit 1';
    ok !has_ref( $s, lock_ref(1) ), 'the current-layout lock is gone (never restored)';
    like   $all, qr/brok/i,              'so the output says broken';
    like   $all, qr/lock on task 1\b/i,  'and names the lock on task 1';
    unlike $all, qr/Nothing was changed/, 'and does not say "Nothing was changed"';
    allow($s);
};

done_testing;
