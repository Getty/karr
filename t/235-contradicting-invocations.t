use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use TestKarr qw( run_karr );
use File::Temp qw( tempdir );

use App::karr::Git;
use App::karr::ActivityLog;

# Ticket #235: four invocations in which the caller contradicts themselves were
# accepted, and karr silently decided for one side.
#
#   edit ID --block "why" --unblock      -> exit 0, card ends up unblocked
#   edit ID --body neu --append-body x   -> body becomes "neu\nx"
#   create TITLE --title OTHER           -> --title wins, positional dropped
#   move ID STATUS --next                -> --next wins, positional dropped
#   move ID --next --prev                -> --next wins, --prev dropped
#
# karr already answered one such pair -- `--claim` with `--release` -- with a
# usage error (Cmd/Edit.pm, "kanban-md rejects the pair at the flag layer too").
# All five now take that same answer: exit 2 per ADR 0002, and nothing written.
#
# The last two deviate from kanban-md, which picks a winner silently for both
# (resolveTargetStatus, cmd/move.go) -- and picks the opposite winner from the
# karr this test replaces. The reasoning lives in Cmd/Move.pm at the guard.

# In-process runner (t/lib/TestKarr.pm): same ($cwd, @argv) signature and
# { exit, stdout, stderr } return as the open3 helper this file used to carry,
# dispatched through the shared App::karr::Dispatch path. KARR_TEST_SUBPROC=1
# restores the old open3 path.
sub _run_karr { return run_karr(@_) }

# Fresh isolated temp repo per subtest, never the developer's real board.
sub _setup_repo {
    my $repo = tempdir( CLEANUP => 1 );
    system( 'git', 'init', '-q', $repo )                                     == 0 or die 'git init';
    system( 'git', '-C', $repo, 'config', 'user.email', 'test@example.com' ) == 0 or die 'git config';
    system( 'git', '-C', $repo, 'config', 'user.name', 'Test User' )         == 0 or die 'git config';

    my $init = _run_karr( $repo, 'init', '--name', 'Contradiction Board' );
    is( $init->{exit}, 0, 'karr init succeeds' ) or diag $init->{stderr};

    my $create = _run_karr( $repo, 'create', '--title', 'Card A', '--status', 'backlog' );
    is( $create->{exit}, 0, 'seed task created' ) or diag $create->{stderr};

    return $repo;
}

sub _task {
    my ( $repo, $id ) = @_;
    return App::karr::Git->new( dir => $repo )->load_task_ref( $id // 1 );
}

# Activity-log entries for one action. A rejected invocation must add none: the
# write is what appends here, and appending for a change that never happened was
# half of what this ticket is about.
sub _log_count {
    my ( $repo, $action ) = @_;
    my $log = App::karr::ActivityLog->new(
        git  => App::karr::Git->new( dir => $repo ),
        role => 'user',
    );
    return scalar grep { $_->{action} eq $action } $log->entries;
}

subtest 'edit --block with --unblock is refused, the block survives (#235)' => sub {
    my $repo = _setup_repo();

    is( _run_karr( $repo, 'edit', 1, '--block', 'waiting on API' )->{exit}, 0,
        'setup: the card is blocked with a reason' );
    my $before      = _task($repo);
    my $before_logs = _log_count( $repo, 'edit' );

    # The bug: both branches ran in order and the second won, so the card came
    # out unblocked, `updated` was stamped and an edit entry was logged -- for
    # an invocation that named blocking and unblocking at once.
    my $rv = _run_karr( $repo, 'edit', 1, '--block', 'and again', '--unblock' );
    is( $rv->{exit}, 2, '--block with --unblock exits 2 (ADR 0002 usage error)' )
        or diag $rv->{stdout} . $rv->{stderr};
    like( $rv->{stderr}, qr/cannot use --block and --unblock together/,
        '...and says which pair it refused' );
    unlike( $rv->{stdout}, qr/Updated task/,
        '...and does not report an update' );

    my $after = _task($repo);
    ok( $after->blocked, 'the card is still blocked' );
    is( $after->block_reason, 'waiting on API',
        '...with the reason it had before' );
    is( $after->updated, $before->updated, 'and `updated` was not stamped' );
    is( _log_count( $repo, 'edit' ), $before_logs,
        'and no activity-log entry was appended' );
};

subtest 'edit --body with --append-body is refused, the body is untouched (#235)' => sub {
    my $repo = _setup_repo();

    is( _run_karr( $repo, 'edit', 1, '--body', 'original body' )->{exit}, 0,
        'setup: the card has a body' );
    my $before      = _task($repo);
    my $before_logs = _log_count( $repo, 'edit' );

    # The bug: --body set the body and --append-body then appended to what it
    # had just set, leaving "neu\nnote" -- a body neither half asked for.
    my $rv = _run_karr( $repo, 'edit', 1, '--body', 'neu', '--append-body', 'note' );
    is( $rv->{exit}, 2, '--body with --append-body exits 2 (ADR 0002 usage error)' )
        or diag $rv->{stdout} . $rv->{stderr};
    like( $rv->{stderr}, qr/cannot use --body and --append-body together/,
        '...and says which pair it refused' );

    my $after = _task($repo);
    is( $after->body, 'original body', 'the body is neither replaced nor appended to' );
    unlike( $after->body, qr/neu\nnote/, '...and in particular is not the concatenation' );
    is( $after->updated, $before->updated, 'and `updated` was not stamped' );
    is( _log_count( $repo, 'edit' ), $before_logs,
        'and no activity-log entry was appended' );
};

subtest 'create with a positional title and --title is refused, no id burned (#235)' => sub {
    my $repo = _setup_repo();
    my $before_logs = _log_count( $repo, 'create' );

    # The bug: `$self->title // $pos[0]` took --title and dropped the positional
    # without a word, so the card was created under a title the caller had also
    # spelled differently one argument earlier.
    my $rv = _run_karr( $repo, 'create', 'TITEL', '--title', 'ANDERER' );
    is( $rv->{exit}, 2, 'two titles exit 2 (ADR 0002 usage error)' )
        or diag $rv->{stdout} . $rv->{stderr};
    like( $rv->{stderr}, qr/title provided both as an argument and with --title/,
        '...and names the contradiction' );
    unlike( $rv->{stdout}, qr/Created task/, '...and reports no creation' );

    is( _log_count( $repo, 'create' ), $before_logs,
        'no activity-log entry was appended' );

    # Rejected before the id is allocated (the #54 rule), so the next create
    # gets the id the refused one would have taken.
    my $next = _run_karr( $repo, 'create', 'Next card' );
    is( $next->{exit}, 0, 'a following create succeeds' ) or diag $next->{stderr};
    like( $next->{stdout}, qr/Created task 2: Next card/,
        '...and gets id 2, so the refused create burned nothing' );

    # Each spelling on its own is still a title.
    my $positional = _run_karr( $repo, 'create', 'Positional only' );
    is( $positional->{exit}, 0, 'a positional title alone still creates' )
        or diag $positional->{stderr};
    my $flag = _run_karr( $repo, 'create', '--title', 'Flag only' );
    is( $flag->{exit}, 0, '--title alone still creates' ) or diag $flag->{stderr};
};

subtest 'move with a target status and --next is refused, the card stays (#235)' => sub {
    my $repo = _setup_repo();
    my $before      = _task($repo);
    my $before_logs = _log_count( $repo, 'move' );
    is( $before->status, 'backlog', 'setup: the card sits on backlog' );

    # The bug: --next overwrote the positional target unconditionally, so this
    # landed the card on todo -- not on archived, and not with a word about it.
    my $rv = _run_karr( $repo, 'move', 1, 'archived', '--next' );
    is( $rv->{exit}, 2, 'a target status with --next exits 2 (ADR 0002 usage error)' )
        or diag $rv->{stdout} . $rv->{stderr};
    like( $rv->{stderr}, qr/cannot use a target status and --next\/--prev together/,
        '...and names the contradiction' );
    unlike( $rv->{stdout}, qr/Moved task/, '...and reports no move' );

    my $after = _task($repo);
    is( $after->status, 'backlog', 'the card did not move' );
    is( $after->updated, $before->updated, 'and `updated` was not stamped' );
    is( _log_count( $repo, 'move' ), $before_logs,
        'and no activity-log entry was appended' );

    # Same guard for --prev, which is the other half of the same option.
    my $prev = _run_karr( $repo, 'move', 1, 'archived', '--prev' );
    is( $prev->{exit}, 2, 'a target status with --prev exits 2 as well' )
        or diag $prev->{stdout} . $prev->{stderr};
    is( _task($repo)->status, 'backlog', '...and the card still did not move' );
};

subtest 'move --next with --prev is refused (#235)' => sub {
    my $repo = _setup_repo();
    my $before      = _task($repo);
    my $before_logs = _log_count( $repo, 'move' );

    # The bug: the if/elsif let --next win and dropped --prev, so this advanced
    # the card one column while the caller had also asked to rewind it.
    my $rv = _run_karr( $repo, 'move', 1, '--next', '--prev' );
    is( $rv->{exit}, 2, '--next with --prev exits 2 (ADR 0002 usage error)' )
        or diag $rv->{stdout} . $rv->{stderr};
    like( $rv->{stderr}, qr/cannot use --next and --prev together/,
        '...and names the contradiction' );

    my $after = _task($repo);
    is( $after->status, $before->status, 'the card did not move' );
    is( _log_count( $repo, 'move' ), $before_logs,
        'and no activity-log entry was appended' );
};

subtest 'the legal spellings of a move still work (#235 control)' => sub {
    my $repo = _setup_repo();

    # --next alone is the whole point of the option and must keep working: the
    # guards above must reject the contradiction, not the relative move.
    my $next = _run_karr( $repo, 'move', 1, '--next' );
    is( $next->{exit}, 0, 'move ID --next still exits 0' ) or diag $next->{stderr};
    like( $next->{stdout}, qr/Moved task 1: backlog -> todo/,
        '...and advances the card one column' );
    is( _task($repo)->status, 'todo', '...which is where the card now sits' );

    # And so does --prev alone, from there back.
    my $prev = _run_karr( $repo, 'move', 1, '--prev' );
    is( $prev->{exit}, 0, 'move ID --prev still exits 0' ) or diag $prev->{stderr};
    is( _task($repo)->status, 'backlog', '...and rewinds the card one column' );

    # A positional target alone is untouched too.
    my $explicit = _run_karr( $repo, 'move', 1, 'archived' );
    is( $explicit->{exit}, 0, 'move ID STATUS still exits 0' ) or diag $explicit->{stderr};
    is( _task($repo)->status, 'archived', '...and puts the card where it was told' );
};

done_testing;
