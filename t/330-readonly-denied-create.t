#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use Cwd ();
use lib Cwd::abs_path('lib');
use TestGit qw( require_git_c );
require_git_c();
use TestDenied qw( new_scene run deny pushes reset_log refs_dump karr_config can_deny lines_matching );

# Ticket k333, part B/E: the first write against a remote that denies write
# access is taken back and puts the clone into `denied`; every later write is
# refused before it touches anything. All of it through the real bin/karr and
# the git CLI route, against a bare origin made unwritable with chmod, and
# with a git shim counting `git push` runs.
#
# What a regression would show here: no take-back (the card, the log entry and
# the burned next-id stay in the clone, so the refs differ), no state (the next
# write pushes again instead of being refused), a retry (pushes > 1), or a
# success line above the denial.

plan skip_all => 'running as root: it ignores the read-only mode of the bare repository'
    unless can_deny();

my $s      = new_scene( seed => 1 );
my $origin = $s->{origin};
my $clone  = $s->{clone};
my $refs_before = refs_dump($clone);
my $all_before  = refs_dump( $clone, 'refs/karr', 'refs/karr-foundation', 'refs/karr-local' );
cmp_ok length($refs_before), '>', 0, 'the clone has a published board (precondition)';

deny($s);

subtest 'the first create is denied: C1, nothing printed on stdout, nothing left behind' => sub {
    reset_log($s);
    my $r = run( $s, 'create', 'probe', '--body', 'x' );

    is $r->{exit}, 1, 'exit 1';
    is $r->{stdout}, '', 'no success line: there is no card to announce';
    my $e = $r->{stderr};
    like $e, qr/^karr: write access to the remote 'origin' \(\Q$origin\E\) was denied: this user cannot write the remote repository's files\.$/m,
        'C1 line 1: the remote, its push URL and the reason';
    like $e, qr/^Nothing was changed: this command's change was taken back, and this clone is now read-only for the board\. Run the command again once this clone can write\.$/m,
        'C1 line 2: the change was taken back';
    like $e, qr/^If this clone is only for reading: karr readonly on\.$/m, 'C1 last line: the way out for a reading clone';
    my ( $i1, $i2, $i3 ) = map { index $e, $_ } 'was denied:', 'Nothing was changed', 'If this clone is only for reading';
    ok $i1 >= 0 && $i1 < $i2 && $i2 < $i3, 'in the documented order';
    like $e, qr/karr readonly off/, 'the fix lines say how to lift the state by hand';
    unlike $e, qr/Push retry|Push failed after|Local refs are intact/, 'no retry banner, no old reassurance';
    unlike $e, qr/this clone cannot write the board:/, 'and no lasting warning on top of C1, which said it all';
    is pushes($s), 1, 'one push attempt, not three';

    is refs_dump($clone), $refs_before, 'refs/karr* byte-identical to before: card, log and next-id taken back';

    my $c = karr_config($s);
    is $c->{'karr.readonly'}, 'denied', 'git config: karr.readonly = denied';
    is $c->{'karr.readonlypushurl'}, $origin, 'for the push URL that denied it';
    like $c->{'karr.readonlyreason'}, qr/cannot write/, 'with the reason';
    like $c->{'karr.readonlysince'}, qr/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/, 'and the UTC time';
};

subtest 'the card is not on the board' => sub {
    my $r = run( $s, 'list', '--json' );
    is $r->{exit}, 0, 'list works';
    unlike $r->{stdout}, qr/probe/, 'the denied card is gone';
};

subtest 'a second create is refused before it writes (C2) and pushes nothing' => sub {
    reset_log($s);
    my $r = run( $s, 'create', 'probe two' );

    is $r->{exit}, 1, 'exit 1';
    is $r->{stdout}, '', 'no stdout';
    my $e = $r->{stderr};
    like $e, qr/^karr: this clone is read-only for the board: write access to 'origin' \(\Q$origin\E\) was denied on \d{4}-\d\d-\d\dT\S+ \(this user cannot write the remote repository's files\)\. Nothing was changed\.$/m,
        'C2: states the earlier denial, its time and reason, and that nothing was changed';
    like $e, qr/^If this clone is only for reading: karr readonly on\.$/m, 'with the fix lines';
    unlike $e, qr/this clone cannot write the board:/, 'and not the lasting warning on top: it already said it';
    is lines_matching( $e, qr/^karr: / ), 1, 'one karr: line';
    is pushes($s), 0, 'zero pushes';
    is refs_dump($clone), $refs_before, 'refs untouched';
};

subtest 'every writing command is refused the same way' => sub {
    my @cmds = (
        [ 'edit', '1', '-a', 'note' ],
        [ 'move', '1', 'in-progress', '--claim', 'z' ],
        [ 'delete', '1', '--yes' ],
        [ 'archive', '1' ],
        [ 'pick', '--claim', 'z' ],
        [ 'handoff', '1', '--claim', 'z', '--note', 'n' ],
        [ 'unlock', '--all' ],
        [ 'config', 'set', 'board.name', 'x' ],
    );
    for my $cmd (@cmds) {
        reset_log($s);
        my $r = run( $s, @$cmd );
        my $name = join ' ', @$cmd;
        is $r->{exit}, 1, "$name: exit 1";
        like $r->{stderr}, qr/^karr: this clone is read-only for the board: write access to 'origin'/m, "$name: C2";
        is $r->{stdout}, '', "$name: no stdout";
        is pushes($s), 0, "$name: no push";
    }
    is refs_dump($clone), $refs_before, 'none of them changed a ref';
    is refs_dump( $clone, 'refs/karr', 'refs/karr-foundation', 'refs/karr-local' ), $all_before,
        'nor a lock or tombstone under refs/karr-local';
};

subtest '--local-only is refused too' => sub {
    reset_log($s);
    my $r = run( $s, 'create', 'only here', '--local-only' );
    is $r->{exit}, 1, 'exit 1: a local-only change in this clone could never be published';
    like $r->{stderr}, qr/^karr: this clone is read-only for the board: write access to 'origin'/m, 'C2';
    like $r->{stderr}, qr/Nothing was changed\./, 'nothing was changed';
    is $r->{stdout}, '', 'no stdout';
    is pushes($s), 0, 'no push';
    is refs_dump($clone), $refs_before, 'refs untouched';
};

subtest 'reading keeps working in the read-only clone' => sub {
    my $r = run( $s, 'show', '1' );
    is $r->{exit}, 0, 'show works';
    like $r->{stdout}, qr/seed 1/, 'and shows the card';
    $r = run( $s, 'board' );
    is $r->{exit}, 0, 'board works';
};

done_testing;
