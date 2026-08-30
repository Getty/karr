use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use TestKarr qw( run_karr );
use File::Temp qw( tempdir );
use Path::Tiny qw( path );

# Regression for karr board ticket #243:
#   IDS=""; karr move "$IDS" todo  ->  "Task todo not found", exit 1.
#
#   MooX::Cmd copies argv with `shellwords(join ' ', map { quotemeta } @ARGV)`
#   (MooX::Cmd::Role 1.000 line 132) before it looks for the command name. That
#   round trip is the identity on every non-empty argument, but the empty
#   string contributes nothing to the joined line and shellwords never returns
#   an empty field -- so the transform is exactly `grep { length }` and the
#   token is gone before any karr code runs. Every argument after it then moves
#   one place to the left, which is why `todo` was read as the id.
#
#   #239 put `defined && length` on the id guards; this is a layer above those,
#   and nothing ever reached them. bin/karr refuses the empty argument while it
#   is still visible instead, so the caller is pointed at their variable rather
#   than at a card that does not exist.

# In-process runner (t/lib/TestKarr.pm): same ($cwd, @argv) signature and
# { exit, stdout, stderr } return as the open3 helper this file used to carry,
# dispatched through the shared App::karr::Dispatch path. KARR_TEST_SUBPROC=1
# restores the old open3 path.
sub _run_karr { return run_karr(@_) }

sub _setup_repo {
    my $repo = tempdir( CLEANUP => 1 );
    system( 'git', 'init', '-q', $repo ) == 0                                     or die 'git init';
    system( 'git', '-C', $repo, 'config', 'user.email', 'test@example.com' ) == 0 or die 'git config';
    system( 'git', '-C', $repo, 'config', 'user.name', 'Test User' ) == 0         or die 'git config';

    my $init = _run_karr( $repo, 'init', '--name', 'Empty Argument Board' );
    is( $init->{exit}, 0, 'karr init succeeds' ) or diag $init->{stderr};

    for my $title ( 'First card', 'Second card' ) {
        my $create = _run_karr( $repo, 'create', '--title', $title, '--status', 'todo' );
        is( $create->{exit}, 0, "seed card '$title' created" ) or diag $create->{stderr};
    }

    return $repo;
}

# The ticket's own reproduction. The old answer named a card ("Task todo not
# found"); the new one has to name the argument, because the mistake is in the
# caller's variable and nowhere near the board.
subtest 'move "" todo names the empty argument, not a card called todo (#243)' => sub {
    my $repo = _setup_repo();

    my $rv = _run_karr( $repo, 'move', '', 'todo' );

    is( $rv->{exit}, 2, 'exit 2 -- a usage error, not a runtime failure (ADR 0002)' )
        or diag $rv->{stdout} . $rv->{stderr};
    like( $rv->{stderr}, qr/argument 2 is empty/,
        '...saying which argument was empty' );
    like( $rv->{stderr}, qr/\Qkarr move '' todo\E/,
        '...showing the command line with the empty slot visible' );
    like( $rv->{stderr}, qr/variable/,
        '...pointing the caller at their shell variable' );
    unlike( $rv->{stderr}, qr/Task todo not found/,
        '...and never blaming a card named after the next argument' );
    is( $rv->{stdout}, '', 'nothing on stdout' );
};

# `move "$IDS" done` was the ticket's second wording: whatever word follows the
# empty variable becomes the id, so the message follows it around.
subtest 'move "" done does not blame a card called done (#243)' => sub {
    my $repo = _setup_repo();

    my $rv = _run_karr( $repo, 'move', '', 'done' );

    is( $rv->{exit}, 2, 'exit 2' ) or diag $rv->{stdout} . $rv->{stderr};
    unlike( $rv->{stderr}, qr/Task done not found/, 'no card named done in the message' );
    like( $rv->{stderr}, qr/argument 2 is empty/, 'the empty argument is named instead' );
};

# A trailing empty shifts nothing -- it is simply lost, and the command then
# behaves as though the argument had never been typed.
subtest 'a trailing empty argument is refused too (#243)' => sub {
    my $repo = _setup_repo();

    my $rv = _run_karr( $repo, 'move', '1', '' );

    is( $rv->{exit}, 2, 'exit 2' ) or diag $rv->{stdout} . $rv->{stderr};
    like( $rv->{stderr}, qr/argument 3 is empty/, 'the third argument is named' );
    unlike( $rv->{stderr}, qr/New status required/,
        'not the old message about a status that was in fact typed' );
};

# The worst case in the survey: `karr show ""` printed whichever card was
# touched last and exited 0, so an agent reading `karr show "$ID"` got a card
# it never asked for and a success code to go with it.
subtest 'show "" is refused instead of printing an arbitrary card (#243)' => sub {
    my $repo = _setup_repo();

    my $rv = _run_karr( $repo, 'show', '' );

    is( $rv->{exit}, 2, 'exit 2, not the old silent success' )
        or diag $rv->{stdout} . $rv->{stderr};
    is( $rv->{stdout}, '', 'no card is printed' );
    like( $rv->{stderr}, qr/argument 2 is empty/, 'the empty argument is named' );
};

# And the one with a side effect: `karr skill ""` fell through to the default
# action and installed skill files for every detected agent.
subtest 'skill "" is refused before it installs anything (#243)' => sub {
    my $repo = _setup_repo();

    my $rv = _run_karr( $repo, 'skill', '' );

    is( $rv->{exit}, 2, 'exit 2' ) or diag $rv->{stdout} . $rv->{stderr};
    ok( !path($repo)->child('.claude/skills')->exists,
        'and no skill was installed as a side effect' );
};

# An empty argument in front of the command name is dropped by the same rule,
# and left `karr "" list` running as plain `karr list`.
subtest 'an empty argument before the command name is refused (#243)' => sub {
    my $repo = _setup_repo();

    my $rv = _run_karr( $repo, '', 'list' );

    is( $rv->{exit}, 2, 'exit 2' ) or diag $rv->{stdout} . $rv->{stderr};
    like( $rv->{stderr}, qr/argument 1 is empty/, 'the first argument is named' );
    is( $rv->{stdout}, '', 'the task list is not printed' );
};

# Two empty variables are two mistakes, and the caller should learn about both
# rather than fix one and come back for the other.
subtest 'every empty argument is reported, not just the first (#243)' => sub {
    my $repo = _setup_repo();

    my $rv = _run_karr( $repo, 'move', '', '' );

    is( $rv->{exit}, 2, 'exit 2' ) or diag $rv->{stdout} . $rv->{stderr};
    like( $rv->{stderr}, qr/arguments 2, 3 are empty/, 'both positions are named' );
};

# The guard must be invisible to every invocation that has no empty argument,
# including the ones whose arguments contain spaces or look option-shaped.
subtest 'ordinary invocations are untouched (#243)' => sub {
    my $repo = _setup_repo();

    my $move = _run_karr( $repo, 'move', '1', 'in-progress', '--claim', 'test-agent' );
    is( $move->{exit}, 0, 'karr move 1 in-progress --claim test-agent still succeeds' )
        or diag $move->{stdout} . $move->{stderr};

    my $create = _run_karr( $repo, 'create', 'A title with spaces in it' );
    is( $create->{exit}, 0, 'a quoted multi-word title still succeeds' )
        or diag $create->{stdout} . $create->{stderr};

    my $escaped = _run_karr( $repo, 'create', '--', '--not-an-option' );
    is( $escaped->{exit}, 0, 'a -- escaped option-shaped title still succeeds' )
        or diag $escaped->{stdout} . $escaped->{stderr};

    my $list = _run_karr( $repo, 'list' );
    is( $list->{exit}, 0, 'karr list still succeeds' ) or diag $list->{stderr};
    like( $list->{stdout}, qr/A title with spaces in it/, 'and shows the card it created' );
};

done_testing;
