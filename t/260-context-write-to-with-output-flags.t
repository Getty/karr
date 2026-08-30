use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use TestKarr qw( run_karr );
use File::Temp qw( tempdir );
use JSON::MaybeXS qw( decode_json );
use Path::Tiny;

# Regression tests for karr board ticket #260.
#
# BUG: `karr context --json --write-to FILE` answered --json and returned
#     before --write-to was looked at, so the file was never written and
#     nothing said so -- exit 0, JSON on stdout, no file. The same class as
#     #225/#226/#254: an option accepted and silently thrown away.
#
# THE RULE, decided by the maintainer with this ticket: --write-to is a SIDE
#     EFFECT and the output flags decide stdout. They were never in conflict.
#     --write-to does not redirect the output; it maintains a block delimited
#     by sentinels karr shares with kanban-md inside a host file (AGENTS.md
#     and the like), replacing it in place on a later run. What goes between
#     those sentinels is Markdown by that interop contract and is not the
#     caller's to choose -- so there is nothing for --json or --compact to
#     decide about the FILE, and no reason for either to cancel the write.
#
#     The same rule settles --compact --write-to, which until now wrote the
#     file and swallowed --compact (the shape #254 left behind). Both now do
#     what they say.
#
# THE CHANNEL: with an output flag stdout belongs to the payload, so the
#     "Context written to X" confirmation moves to stderr there -- the answer
#     #248 gave for `delete`'s prompt, for the same reason: a caller doing
#     `karr context --json --write-to AGENTS.md > ctx.json` must get a file
#     that decodes whole. Without an output flag stdout is prose anyway and
#     the line stays where it was.

# In-process runner (t/lib/TestKarr.pm): same ($cwd, @argv) signature and
# { exit, stdout, stderr } return as the open3 helper this file used to carry,
# dispatched through the shared App::karr::Dispatch path. KARR_TEST_SUBPROC=1
# restores the old open3 path.
sub _run_karr { return run_karr(@_) }

sub _setup_repo {
    my $repo = tempdir( CLEANUP => 1 );
    is( system( 'git', 'init', '-q', $repo ), 0, 'git init' );
    is( system( 'git', '-C', $repo, 'config', 'user.email', 'test@example.com' ), 0, 'git config email' );
    is( system( 'git', '-C', $repo, 'config', 'user.name', 'Test User' ), 0, 'git config name' );

    my $init = _run_karr( $repo, 'init', '--name', 'Context Board' );
    is( $init->{exit}, 0, 'karr init succeeds' ) or diag $init->{stderr};

    my $create = _run_karr( $repo, 'create', '--title', 'A card', '--status', 'todo' );
    is( $create->{exit}, 0, 'a card exists' ) or diag $create->{stderr};

    return $repo;
}

my $SENTINEL = qr/<!-- BEGIN kanban-md context -->.*<!-- END kanban-md context -->/s;

subtest '--json --write-to writes the file AND prints the payload (RED)' => sub {
    my $repo = _setup_repo();
    my $host = path($repo)->child('AGENTS.md');
    $host->spew_utf8("# AGENTS.md\n\nText of my own.\n");

    my $rv = _run_karr( $repo, 'context', '--json', '--write-to', 'AGENTS.md' );
    is( $rv->{exit}, 0, 'exit 0' ) or diag $rv->{stderr};

    my $content = $host->slurp_utf8;
    like( $content, $SENTINEL, 'the block is in the file' );
    like( $content, qr/Text of my own/, 'the surrounding text survives' );

    my $payload = eval { decode_json( $rv->{stdout} ) };
    ok( $payload, 'stdout decodes as JSON on its own' ) or diag $rv->{stdout};
    is( $payload->{board_name}, 'Context Board', 'and it is the context payload' );

    like( $rv->{stderr}, qr/Context written to AGENTS\.md/,
        'the confirmation went to stderr, so stdout stayed parseable' );
};

subtest '--compact --write-to writes the file AND prints the numbers (RED)' => sub {
    my $repo = _setup_repo();
    my $host = path($repo)->child('AGENTS.md');

    my $rv = _run_karr( $repo, 'context', '--compact', '--write-to', 'AGENTS.md' );
    is( $rv->{exit}, 0, 'exit 0' ) or diag $rv->{stderr};

    ok( $host->exists, 'the file was created' );
    like( $host->slurp_utf8, $SENTINEL, 'and carries the block' );

    like( $rv->{stdout}, qr/^board_name=Context Board$/m, 'stdout carries board_name' );
    like( $rv->{stdout}, qr/^total_tasks=1$/m,            'stdout carries total_tasks' );
    unlike( $rv->{stdout}, qr/Context written to/,
        'and not the prose line, which would not be key=value' );

    like( $rv->{stderr}, qr/Context written to AGENTS\.md/, 'the confirmation went to stderr' );
};

subtest '--write-to alone is unchanged (GREEN)' => sub {
    my $repo = _setup_repo();
    my $host = path($repo)->child('AGENTS.md');

    my $rv = _run_karr( $repo, 'context', '--write-to', 'AGENTS.md' );
    is( $rv->{exit}, 0, 'exit 0' ) or diag $rv->{stderr};

    like( $host->slurp_utf8, $SENTINEL, 'the block is in the file' );
    like( $rv->{stdout}, qr/Context written to AGENTS\.md/,
        'stdout keeps the prose line when no output flag claims it' );
    is( $rv->{stderr}, '', 'and stderr stays empty' );
};

subtest 'the block is still replaced in place, not appended (RED)' => sub {
    my $repo = _setup_repo();
    my $host = path($repo)->child('AGENTS.md');
    $host->spew_utf8("# AGENTS.md\n\nText of my own.\n");

    _run_karr( $repo, 'context', '--json',    '--write-to', 'AGENTS.md' );
    _run_karr( $repo, 'context', '--compact', '--write-to', 'AGENTS.md' );
    _run_karr( $repo, 'context', '--write-to', 'AGENTS.md' );

    my $content = $host->slurp_utf8;
    my $begins = () = $content =~ /<!-- BEGIN kanban-md context -->/g;
    is( $begins, 1, 'three runs across all three renderings leave one block' );
    like( $content, qr/Text of my own/, 'and the host text is still there' );
};

subtest '--json --write-to still refuses a file it cannot read (GREEN, #77)' => sub {
    my $repo = _setup_repo();
    my $dir  = path($repo)->child('AGENTS.md');
    $dir->mkpath;    # a directory where a file is expected

    my $rv = _run_karr( $repo, 'context', '--json', '--write-to', 'AGENTS.md' );
    isnt( $rv->{exit}, 0, 'the unwritable target is reported, not swallowed' );
    like( $rv->{stderr}, qr/AGENTS\.md/, 'and the message names the path' );
};

done_testing;
