#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
BEGIN { plan skip_all => 'karr-foundation cannot run agents on MSWin32' if $^O eq 'MSWin32' }
use lib 't/lib';
use Cwd ();
use lib Cwd::abs_path('lib');
use TestGit qw( require_git_c );
require_git_c();
use TestDenied qw( new_scene run deny allow pushes reset_log refs_dump karr_config can_deny );
use Path::Tiny qw( path );
use IPC::Open3 qw( open3 );
use Symbol qw( gensym );

# Ticket k333, part B/E: karr-foundation treats a board whose clone is
# read-only like a disabled one -- it runs nothing there, writes no ref -- and
# --status marks it.
#
# A control pass on the same board with the state off proves the marker file
# would exist if foundation had run the agent: without it "no marker" could be
# any reason at all.

my $ROOT = Cwd::abs_path('.');

sub foundation {
    my ( $cfg, @argv ) = @_;
    my $err = gensym;
    my $pid = open3( my $in, my $out, $err, $^X, "-I$ROOT/lib", "$ROOT/bin/karr-foundation", '--config', "$cfg", @argv );
    close $in;
    my $stdout = do { local $/; <$out> } // '';
    my $stderr = do { local $/; <$err> } // '';
    waitpid $pid, 0;
    return { exit => $? >> 8, stdout => $stdout, stderr => $stderr };
}

my $s      = new_scene( seed => 1 );
my $clone  = $s->{clone};
my $marker = path("$s->{work}/agent-ran");
my $cfg    = path("$s->{work}/foundation.yml");
$cfg->spew_utf8("dirs:\n  - $clone\n");
path("$clone/.karr")->spew_utf8("command: touch $marker\n");
is run( $s, 'move', '1', 'todo' )->{exit}, 0, 'a todo card gives the pass something to do';

subtest 'control: a board that may write runs the agent, and --status shows no read-only flag' => sub {
    my $r = foundation( $cfg, '--status' );
    is $r->{exit}, 0, '--status exits 0' or diag $r->{stderr};
    unlike $r->{stdout}, qr/read-only/, 'no read-only mark';
    $r = foundation($cfg);
    ok -e "$marker", 'the pass ran the agent command (so the absence below means something)'
        or diag $r->{stdout} . $r->{stderr};
    $marker->remove;
};

subtest 'karr readonly on: marked in --status, and a pass runs nothing and writes no ref' => sub {
    is run( $s, 'readonly', 'on' )->{exit}, 0, 'readonly on';
    my $r = foundation( $cfg, '--status' );
    is $r->{exit}, 0, '--status exits 0';
    like $r->{stdout}, qr/\[[^\]]*read-only: on[^\]]*\]/, 'the board is marked [read-only: on]';
    unlike $r->{stdout}, qr/read-only:\s+denied|^\s+read-only:   /m, 'no denied detail line for on';
    unlike $r->{stdout}, qr/\bagent\b[^\n]*\]/, 'and no agent flag: no agent will run here';

    reset_log($s);
    my $before = refs_dump( $clone, 'refs/karr', 'refs/karr-foundation', 'refs/karr-local' );
    $r = foundation($cfg);
    ok !-e "$marker", 'the pass did not run the agent';
    is refs_dump( $clone, 'refs/karr', 'refs/karr-foundation', 'refs/karr-local' ), $before, 'no ref was written';
    is pushes($s), 0, 'no push was attempted';
    is karr_config($s)->{'karr.readonly'}, 'on', 'and the state is unchanged';
};

SKIP: {
    skip 'running as root: it ignores the read-only mode of the bare repository', 1 unless can_deny();

    subtest 'denied: marked with a detail line, the pass writes nothing' => sub {
        run( $s, 'readonly', 'off' );
        deny($s);
        is run( $s, 'edit', '1', '-a', 'learn the denial' )->{exit}, 1, 'the clone learns denied';
        is karr_config($s)->{'karr.readonly'}, 'denied', 'state denied';

        my $r = foundation( $cfg, '--status' );
        like $r->{stdout}, qr/\[[^\]]*read-only: denied[^\]]*\]/, 'marked [read-only: denied]';
        like $r->{stdout}, qr/^\s+read-only:\s+\S/m, 'with a read-only: detail line';
        like $r->{stdout}, qr/\Q$s->{origin}\E/, 'naming the push URL';

        my $before = refs_dump( $clone, 'refs/karr', 'refs/karr-foundation', 'refs/karr-local' );
        reset_log($s);
        $r = foundation($cfg);
        ok !-e "$marker", 'the pass did not run the agent';
        is refs_dump( $clone, 'refs/karr', 'refs/karr-foundation', 'refs/karr-local' ), $before, 'no ref was written';
        is pushes($s), 0, 'no push was attempted';
        allow($s);
    };
}

done_testing;
