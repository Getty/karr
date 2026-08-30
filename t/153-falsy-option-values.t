use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use TestKarr qw( run_karr run_karr_stdin );
use File::Temp qw( tempdir );

use App::karr::Git;
use App::karr::ActivityLog;

# Ticket #153: the truthiness guards around option values in Cmd/Edit,
# Cmd/Create and Cmd/Handoff silently dropped "0" -- writing the task, bumping
# `updated`, appending to the activity log, and printing success. The #78 rule
# (`defined && length`) is what --body was changed to; this ticket extends it
# to the siblings that did not get the conversion.
#
# The fix lands "0" as a real value rather than rejecting it: a literal "0" is
# one character long and is a meaningful title/block-reason/tag/assignee/estimate
# -- exactly the same argument ticket #78 made for --body "0". Two characters
# ("00") have always been truthy; the bug was that one was not.

# In-process runner (t/lib/TestKarr.pm): same ($cwd, $stdin, @argv) signature
# and { exit, stdout, stderr } return as the open3 helper this file used to
# carry, dispatched through the shared App::karr::Dispatch path.
# KARR_TEST_SUBPROC=1 restores the old open3 path.
sub _run_karr {
    my ( $cwd, $stdin, @argv ) = @_;
    return defined $stdin
        ? run_karr_stdin( $cwd, $stdin, @argv )
        : run_karr( $cwd, @argv );
}

# Fresh isolated temp repo per subtest, never the developer's real board.
sub _setup_repo {
    my $repo = tempdir( CLEANUP => 1 );
    system( 'git', 'init', '-q', $repo )                                     == 0 or die 'git init';
    system( 'git', '-C', $repo, 'config', 'user.email', 'test@example.com' ) == 0 or die 'git config';
    system( 'git', '-C', $repo, 'config', 'user.name', 'Test User' )         == 0 or die 'git config';

    my $init = _run_karr( $repo, undef, 'init', '--name', 'Falsy Board' );
    is( $init->{exit}, 0, 'karr init succeeds' ) or diag $init->{stderr};

    my $create = _run_karr( $repo, undef, 'create',
        '--title', 'original title', '--status', 'todo' );
    is( $create->{exit}, 0, 'seed task created' ) or diag $create->{stderr};

    return $repo;
}

sub _task {
    my ( $repo, $id ) = @_;
    return App::karr::Git->new( dir => $repo )
        ->load_task_ref( $id // 1 );
}

# Count edit entries in the activity log for this repo. The seeded task's
# creation is the only entry before any test command runs, so any extra one is
# a write that landed.
sub _edit_count {
    my ($repo) = @_;
    my $log = App::karr::ActivityLog->new(
        git => App::karr::Git->new( dir => $repo ),
        role => 'user',
    );
    return scalar grep { $_->{action} eq 'edit' } $log->entries;
}

subtest 'edit --title 0 lands as the literal title "0" (#153)' => sub {
    my $repo = _setup_repo();
    my $before_logs = _edit_count($repo);

    # The bug: this used to print "Updated task 1: original title" and exit 0
    # with the title still "original title" -- a silent write that bumped
    # `updated` and appended to the activity log for a change that never
    # happened. The fix lands "0" as the title (ticket #78's rule applied to
    # --title's siblings).
    my $rv = _run_karr( $repo, undef, 'edit', 1, '--title', '0' );
    is( $rv->{exit}, 0, 'edit --title 0 succeeds' )
        or diag $rv->{stdout} . $rv->{stderr};
    like( $rv->{stdout}, qr/Updated task 1: 0/,
        '...and stdout reports the new title "0", not the old one' );

    my $after = _task($repo);
    is( $after->title, '0',
        'and the literal "0" landed as the new title' );
    is( _edit_count($repo), $before_logs + 1,
        'and exactly one activity-log entry was appended (a real write)' );
};

subtest 'edit --block 0 records block reason "0" (#153 sharp edge)' => sub {
    my $repo = _setup_repo();

    # The ticket's sharp edge: the card was reported updated but was NOT
    # blocked, and pick would hand it straight out. The fix lands "0" as a
    # block reason rather than silently dropping it.
    my $rv = _run_karr( $repo, undef, 'edit', 1, '--block', '0' );
    is( $rv->{exit}, 0, 'edit --block 0 succeeds' )
        or diag $rv->{stdout} . $rv->{stderr};

    my $task = _task($repo);
    ok( $task->has_blocked,
        'and the card IS blocked (not silently left unblocked)' );
    is( $task->block_reason, '0',
        'and the literal "0" is the recorded block reason' );
};

subtest 'edit --title 00 still works: truthiness, not numeric validation' => sub {
    # The giveaway for the bug: --title 00 (two characters, truthy) has always
    # worked. The fix has to keep it working -- and the difference between "0"
    # and "00" being meaningful is the proof that the fix is definedness, not
    # numeric validation.
    my $repo = _setup_repo();

    my $rv = _run_karr( $repo, undef, 'edit', 1, '--title', '00' );
    is( $rv->{exit}, 0, 'edit --title 00 succeeds' )
        or diag $rv->{stdout} . $rv->{stderr};
    like( $rv->{stdout}, qr/Updated task 1: 00/,
        '...and reports the new title' );
    is( _task($repo)->title, '00',
        '...and the new title landed in the ref' );
};

subtest 'edit --append-body 0 appends, never replaces (#153 self-contradicting guard)' => sub {
    # The comment immediately inside the guard reads:
    #     "length, not truth: appending to a body of "0" must not replace it
    #     (ticket #78)"
    # The guard was `if ($self->append_body)`, which is truth, not length --
    # and the body it appended to was set by --body, the place where #78 was
    # actually fixed. So `karr edit 1 -a 0` against a task whose body is "0"
    # used to silently do nothing while still claiming to have updated the
    # task. The fix makes --append_body honour the same comment.
    my $repo = _setup_repo();

    # Seed a body of "0" by writing through the board directly; --body "0"
    # already lands thanks to ticket #78.
    my $seed = _run_karr( $repo, undef, 'edit', 1, '--body', '0' );
    is( $seed->{exit}, 0, 'seed: --body 0 lands as the literal "0"' )
        or diag $seed->{stderr};
    is( _task($repo)->body, '0', 'and the body is now "0"' );

    my $rv = _run_karr( $repo, undef, 'edit', 1, '-a', 'appended' );
    is( $rv->{exit}, 0, 'edit -a appended succeeds' )
        or diag $rv->{stdout} . $rv->{stderr};

    # "appending to a body of "0" must not replace it" -- #78. The blank line
    # between the two is #238's separator: a body of "0" is a body, so it takes
    # the separator like any other.
    is( _task($repo)->body, "0\n\nappended",
        'and the existing body of "0" was preserved and the new text appended' )
        or diag "got: " . _task($repo)->body;
};

subtest 'create --title 0 and the bare positional 0 land the title "0" (#153)' => sub {
    my $repo = _setup_repo();

    # The one guard in Cmd::Create that #153 left deciding by truth:
    #     my $title = $self->title // $pos[0]
    #       or die "Title is required. Use --title or pass as argument.\n";
    # The assignment yields "0", which is false in Perl, so BOTH call forms
    # were rejected with "Title is required" while every other option in the
    # very same file had already been converted to `defined && length`.
    # kanban-md's resolveCreateTitle tests the flag against "" and the args
    # against length, so it takes "0" as a title.
    my $flag = _run_karr( $repo, undef, 'create', '--title', '0' );
    is( $flag->{exit}, 0, 'create --title 0 succeeds' )
        or diag $flag->{stdout} . $flag->{stderr};
    like( $flag->{stdout}, qr/Created task 2: 0/,
        '...and stdout reports the created title "0"' );
    my $created = _task( $repo, 2 );
    is( $created ? $created->title : undef, '0',
        'and the literal "0" landed as the title in the ref' );

    my $positional = _run_karr( $repo, undef, 'create', '0' );
    is( $positional->{exit}, 0, 'create 0 (positional form) succeeds' )
        or diag $positional->{stdout} . $positional->{stderr};
    my $from_positional = _task( $repo, 3 );
    is( $from_positional ? $from_positional->title : undef, '0',
        'and the positional "0" landed as the title too' );

    # Truthiness, not numeric validation: "00" (two characters) has always
    # worked, and that difference is what identifies the bug rather than a
    # rule about numbers.
    my $two = _run_karr( $repo, undef, 'create', '--title', '00' );
    is( $two->{exit}, 0, 'create --title 00 still succeeds' )
        or diag $two->{stderr};
    my $two_chars = _task( $repo, 4 );
    is( $two_chars ? $two_chars->title : undef, '00',
        '...with the title "00"' );

    # And the guard is still a guard: length, not deleted. A create with no
    # title at all stays a failure, exactly as before.
    my $none = _run_karr( $repo, undef, 'create' );
    isnt( $none->{exit}, 0, 'a create with no title at all is still rejected' );
    like( $none->{stderr}, qr/Title is required/,
        '...with the title-required message' );
};

subtest 'create with --tags 0 --assignee 0 --estimate 0 lands all three (#153)' => sub {
    my $repo = _setup_repo();

    # The bug used to create the task and silently drop all three options.
    # --tags is comma-split, so "0" splits to ['0']; --assignee and
    # --estimate are scalar. With the #78 rule (`defined && length`) applied
    # to the siblings, all three land instead of being silently dropped.
    my $rv = _run_karr( $repo, undef, 'create',
        '--title', 'all-three',
        '--tags', '0', '--assignee', '0', '--estimate', '0' );
    is( $rv->{exit}, 0, 'create ... --tags 0 --assignee 0 --estimate 0 succeeds' )
        or diag $rv->{stdout} . $rv->{stderr};

    my $task = _task( $repo, 2 );
    is_deeply( $task->tags, ['0'],
        'and --tags 0 landed as the literal tag "0" (one comma-split element)' );
    is( $task->assignee, '0',
        'and --assignee 0 landed as the literal "0"' );
    is( $task->estimate, '0',
        'and --estimate 0 landed as the literal "0"' );
};

subtest 'handoff --block 0 records block reason "0" (#153)' => sub {
    my $repo = _setup_repo();

    # Move the task into a require_claim column so handoff has somewhere to
    # land it and --claim has something to satisfy.
    my $move = _run_karr( $repo, undef, 'move', 1, 'in-progress',
        '--claim', 'alice' );
    is( $move->{exit}, 0, 'seed task moved into in-progress' )
        or diag $move->{stderr};

    # --block 0 lands as a block reason rather than being silently dropped.
    my $rv = _run_karr( $repo, undef, 'handoff', 1,
        '--claim', 'alice', '--block', '0' );
    is( $rv->{exit}, 0, 'handoff --block 0 succeeds' )
        or diag $rv->{stdout} . $rv->{stderr};

    my $task = _task($repo);
    ok( $task->has_blocked,
        'and the card is blocked' );
    is( $task->block_reason, '0',
        'and the literal "0" is the recorded block reason' );
};

subtest 'handoff --block 0 says so in its success line (#153 message half)' => sub {
    my $repo = _setup_repo();

    my $move = _run_karr( $repo, undef, 'move', 1, 'in-progress',
        '--claim', 'alice' );
    is( $move->{exit}, 0, 'seed task moved into in-progress' )
        or diag $move->{stderr};

    # The reporting half of the guard above. #153 converted the guard that
    # blocks the card but not the one that composes the success line, which
    # still read `if $self->block` -- so the card came back blocked while the
    # output denied it. "00" always printed its "(blocked: 00)".
    my $rv = _run_karr( $repo, undef, 'handoff', 1,
        '--claim', 'alice', '--block', '0' );
    is( $rv->{exit}, 0, 'handoff --block 0 succeeds' )
        or diag $rv->{stdout} . $rv->{stderr};
    ok( _task($repo)->has_blocked, 'and the card really is blocked' );
    like( $rv->{stdout}, qr/\(blocked: 0\)/,
        'and the success line reports the block it just recorded' );
};

subtest 'handoff --note 0 appends the literal "0" to the body (#153)' => sub {
    my $repo = _setup_repo();

    my $move = _run_karr( $repo, undef, 'move', 1, 'in-progress',
        '--claim', 'alice' );
    is( $move->{exit}, 0, 'seed task moved into in-progress' )
        or diag $move->{stderr};

    # --note 0 is the same kind of truthiness guard as --append_body: it
    # appends text to the body, and "0" is meaningful text.
    my $rv = _run_karr( $repo, undef, 'handoff', 1,
        '--claim', 'alice', '--note', '0' );
    is( $rv->{exit}, 0, 'handoff --note 0 succeeds' )
        or diag $rv->{stdout} . $rv->{stderr};

    is( _task($repo)->body, '0',
        'and the literal "0" was appended to the body' );
};

done_testing;
