use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use TestKarr qw( run_karr );
use File::Temp qw( tempdir );

# Ticket k264: finish the working-command sweep k263 started, on the frequent
# commands it deliberately set aside. Two messages had the same disease as the
# rare ones -- they named an id or quoted the way out in prose, but never showed
# the line that would have worked:
#
#   1. "Task $id not found", shared by move, edit, delete, archive and handoff.
#      It is raised from App::karr::Role::TaskMutation/task_not_found now, one
#      spelling reached through update_task_guarded, delete_task_guarded and the
#      unguarded pre-reads in Cmd::Archive/Cmd::Delete -- so every one of the
#      five ends on `karr list --compact`. `show` (read-only) carries the same.
#   2. "Unknown command: $unknown", which quoted `karr --help` inside prose
#      where it could be a line to copy. The "Unknown command:" marker still
#      leads the first line (App::karr::Error::is_usage_error / bin/karr key the
#      exit code on it, ADR 0002), and the hint follows on its own last line.
#
# Every check is one of k263's three: the suggestion carries the REAL id, it is
# the last line (behind at most the batch summary), and the exit code is exactly
# what it was before.

# In-process runner (t/lib/TestKarr.pm): same ($cwd, @argv) signature and
# { exit, stdout, stderr } return as the open3 helper this file used to carry,
# dispatched through the shared App::karr::Dispatch path. KARR_TEST_SUBPROC=1
# restores the old open3 path.
sub _run_karr { return run_karr(@_) }

sub _bare_repo {
    my $repo = tempdir( CLEANUP => 1 );
    system( 'git', 'init', '-q', $repo ) == 0                                     or die 'git init';
    system( 'git', '-C', $repo, 'config', 'user.email', 'test@example.com' ) == 0 or die 'git config';
    system( 'git', '-C', $repo, 'config', 'user.name', 'Test User' ) == 0         or die 'git config';
    return $repo;
}

sub _board_repo {
    my (@titles) = @_;
    my $repo = _bare_repo();
    my $init = _run_karr( $repo, 'init', '--name', 'Hint Board' );
    is( $init->{exit}, 0, 'setup: karr init' ) or diag $init->{stderr};
    for my $title (@titles) {
        my $rv = _run_karr( $repo, 'create', $title, '--status', 'todo' );
        is( $rv->{exit}, 0, "setup: created '$title'" ) or diag $rv->{stderr};
    }
    return $repo;
}

# The lines a caller actually sees, trailing blanks dropped.
sub _lines {
    my ($text) = @_;
    my @lines = split /\n/, $text;
    pop @lines while @lines && $lines[-1] !~ /\S/;
    return @lines;
}

# The suggestion is the last line, except that a batch command still owes its
# "N of M ids failed" summary after the per-id output -- which is exactly why
# k263's reproduction pipes through `tail -3` rather than `tail -1`.
sub _hint_is_last {
    my ( $text, $want, $name ) = @_;
    my @lines = _lines($text);
    my $at    = $lines[-1] =~ /\A\d+ of \d+ ids failed\z/ ? -2 : -1;
    is( $lines[$at], $want, $name )
        or diag "full output was:\n$text";
    return;
}

#### Point 1: the shared not-found, one spelling, ending in the way to look

# Every command on the mutation path, plus show, gets the same last line -- and
# it is the real id every time, never a placeholder.
subtest 'move/edit/delete/archive all end on `karr list --compact`' => sub {
    my $repo = _board_repo('a card');

    for my $argv ( [qw( move 999 todo )], [ 'edit', 999, '-a', 'note' ],
        [qw( delete 999 --yes )], [qw( archive 999 )] )
    {
        my $name = join ' ', 'karr', @$argv;
        my $rv   = _run_karr( $repo, @$argv );

        is( $rv->{exit}, 1, "$name: a missing id is a runtime failure (1), unchanged" )
            or diag $rv->{stdout} . $rv->{stderr};
        like( $rv->{stderr}, qr/^Task 999 not found on this board:$/m,
            "$name: the id the caller typed is named" );
        _hint_is_last( $rv->{stderr}, '  karr list --compact',
            "$name: the way to find the ids that exist is the last line" );
        unlike( $rv->{stderr}, qr/karr list ID/, "$name: no placeholder in the suggestion" );
    }
};

# handoff and show are single-id -- no batch summary trails the hint, so it is
# the very last line of the whole message.
subtest 'handoff and show carry the same last line, with nothing after it' => sub {
    my $repo = _board_repo('a card');

    my $name = _run_karr( $repo, 'agent-name' )->{stdout};
    chomp $name;

    my $handoff = _run_karr( $repo, 'handoff', 999, '--claim', $name );
    is( $handoff->{exit}, 1, 'handoff 999: missing id is a runtime failure (1)' )
        or diag $handoff->{stdout} . $handoff->{stderr};
    is( ( _lines( $handoff->{stderr} ) )[-1], '  karr list --compact',
        'handoff has no batch summary, so the hint is the very last line' );

    my $show = _run_karr( $repo, 'show', 999 );
    is( $show->{exit}, 1, 'show 999: missing id is a runtime failure (1)' )
        or diag $show->{stdout} . $show->{stderr};
    like( $show->{stderr}, qr/^Task 999 not found on this board:$/m, 'show names the id' );
    is( ( _lines( $show->{stderr} ) )[-1], '  karr list --compact',
        'and ends on the same working line' );
};

# The id in the suggestion is the one the caller typed, not one left over from a
# previous message. (task_not_found builds the line per call.)
subtest 'a different id gives a different message, but the same last line' => sub {
    my $repo = _board_repo('a card');

    my $rv = _run_karr( $repo, 'move', 12345, 'review' );
    like( $rv->{stderr}, qr/^Task 12345 not found on this board:$/m,
        'the id is 12345, not a placeholder or a leftover' );
    _hint_is_last( $rv->{stderr}, '  karr list --compact', 'suggestion last' );
};

# k264 rule two: the batch runner still reduces --json's `error` to one line and
# drops the colon that only introduced the (now absent) suggestion. The shell
# line never enters the payload.
subtest '--json keeps a one-line error and no suggestion in the payload' => sub {
    my $repo = _board_repo('a card');

    for my $argv ( [qw( move 999 todo --json )], [qw( delete 999 --yes --json )] ) {
        my $name = join ' ', 'karr', @$argv;
        my $rv   = _run_karr( $repo, @$argv );

        is( $rv->{exit}, 1, "$name: exit 1, unchanged" ) or diag $rv->{stderr};
        unlike( $rv->{stdout}, qr/karr list/, "$name: the shell line is not in the JSON" );
        like( $rv->{stdout},
            qr/\Q"error":"Task 999 not found on this board"\E/,
            "$name: the error field is one line, with no dangling colon" );
    }
};

# The not-found line survives the batch runner's first-line reduction: a `move`
# whose id is missing is cleaned through App::karr::Error/clean_error before it
# is warned, and the reduction used to keep the first line only. If it did not
# survive, the hint would be gone and only "Task 999 not found on this board:"
# would print -- with the colon dangling and nothing under it.
use App::karr::Error qw( clean_error command_hint );
subtest 'clean_error carries the not-found suggestion through the batch runner' => sub {
    my $msg = "Task 999 not found on this board:\n"
        . command_hint( 'list', '--compact' ) . "\n";
    is( clean_error($msg),
        "Task 999 not found on this board:\n  karr list --compact",
        'the sentence and the suggestion both survive the reduction' );
};

#### Point 2: Unknown command

subtest 'an unknown command keeps the marker first and the hint last' => sub {
    my $repo = _board_repo('a card');

    my $rv = _run_karr( $repo, 'wibble' );

    is( $rv->{exit}, 2, 'an unknown command is a usage error (2), unchanged (ADR 0002)' )
        or diag $rv->{stdout} . $rv->{stderr};
    # The marker bin/karr and is_usage_error classify on is still at the start of
    # the first line -- move it and the exit code silently drops to 1.
    like( $rv->{stderr}, qr/\AUnknown command: wibble$/m, 'the marker leads the first line' );
    is( ( _lines( $rv->{stderr} ) )[-1], '  karr --help',
        'the way out is a line to copy, and it is last' );
    # The prose it replaced is gone.
    unlike( $rv->{stderr}, qr/Run 'karr --help'/, 'no prose way-out any more' );
};

use App::karr::Error qw( is_usage_error );
subtest 'the reworded Unknown command still classifies as a usage error' => sub {
    ok( is_usage_error("Unknown command: wibble\n  karr --help\n"),
        'the marker still leads, so is_usage_error keys on it -> exit 2' );
};

done_testing;
