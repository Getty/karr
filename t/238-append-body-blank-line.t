use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use TestKarr qw( run_karr );
use File::Temp qw( tempdir );

use App::karr::Git;
use App::karr::Task;

# Ticket #238: appending to a task body joined the new text to the old one with
# a single newline, so Markdown -- which folds a single newline into a space --
# rendered every appended note into the paragraph above it. On a card that
# collects notes over a working session (the normal case for `handoff --note`
# and `edit -a`) the whole history became one block.
#
# kanban-md's AppendBody (internal/board/mutate.go:571) trims the trailing
# newlines off the existing body and joins with "\n\n"; an empty existing body
# gets no separator at all, so nothing ever starts with a blank line. karr now
# does the same, in App::karr::Task::append_body -- one implementation for both
# call sites, which had been copies of each other.
#
# The second half of the ticket: `edit -a` had no way to date a note while
# `handoff --note` did. It has one now -- the same opt-in -t/--timestamp flag,
# in the same UTC form -- rather than a stamp forced on every append, which
# would rewrite structured Markdown (`-a "## Findings"` is a heading only as
# long as nothing is prefixed to that line).

# In-process runner (t/lib/TestKarr.pm): same ($cwd, @argv) signature and
# { exit, stdout, stderr } return as the open3 helper this file used to carry,
# dispatched through the shared App::karr::Dispatch path. KARR_TEST_SUBPROC=1
# restores the old open3 path.
sub _run_karr { return run_karr(@_) }

# Fresh isolated temp repo per subtest, never the developer's real board.
sub _setup_repo {
    my (%arg) = @_;
    my $repo = tempdir( CLEANUP => 1 );
    system( 'git', 'init', '-q', $repo )                                     == 0 or die 'git init';
    system( 'git', '-C', $repo, 'config', 'user.email', 'test@example.com' ) == 0 or die 'git config';
    system( 'git', '-C', $repo, 'config', 'user.name', 'Test User' )         == 0 or die 'git config';

    my $init = _run_karr( $repo, 'init', '--name', 'Append Board' );
    is( $init->{exit}, 0, 'karr init succeeds' ) or diag $init->{stderr};

    my @create = ( 'create', '--title', 'Card A', '--status', 'backlog' );
    push @create, '--body', $arg{body} if defined $arg{body};
    my $create = _run_karr( $repo, @create );
    is( $create->{exit}, 0, 'seed task created' ) or diag $create->{stderr};

    return $repo;
}

sub _task {
    my ( $repo, $id ) = @_;
    return App::karr::Git->new( dir => $repo )->load_task_ref( $id // 1 );
}

subtest 'edit -a separates the appended text with a blank line' => sub {
    my $repo = _setup_repo( body => 'a' );

    my $rv = _run_karr( $repo, 'edit', 1, '-a', 'b' );
    is( $rv->{exit}, 0, 'edit -a succeeds' ) or diag $rv->{stdout} . $rv->{stderr};

    is( _task($repo)->body, "a\n\nb",
        'the note is a paragraph of its own, not a continuation line' )
        or diag 'got: ' . _task($repo)->body;
};

subtest 'edit -a on an empty body starts no blank line' => sub {
    my $repo = _setup_repo();
    is( _task($repo)->body, '', 'seed: the card has no body' );

    my $rv = _run_karr( $repo, 'edit', 1, '-a', 'first note' );
    is( $rv->{exit}, 0, 'edit -a succeeds' ) or diag $rv->{stdout} . $rv->{stderr};

    is( _task($repo)->body, 'first note',
        'the body is the note itself, with no leading separator' )
        or diag 'got: ' . _task($repo)->body;
};

subtest 'repeated appends stay separate paragraphs' => sub {
    my $repo = _setup_repo( body => 'a' );

    for my $note (qw( b c )) {
        my $rv = _run_karr( $repo, 'edit', 1, '-a', $note );
        is( $rv->{exit}, 0, "edit -a $note succeeds" )
            or diag $rv->{stdout} . $rv->{stderr};
    }

    is( _task($repo)->body, "a\n\nb\n\nc",
        'each append adds exactly one blank line, and they do not accumulate' )
        or diag 'got: ' . _task($repo)->body;
};

subtest 'handoff --note separates the note with a blank line' => sub {
    my $repo = _setup_repo( body => 'a' );

    my $move = _run_karr( $repo, 'move', 1, 'in-progress', '--claim', 'alice' );
    is( $move->{exit}, 0, 'seed: task claimed and in progress' ) or diag $move->{stderr};

    my $rv = _run_karr( $repo, 'handoff', 1, '--claim', 'alice', '--note', 'b' );
    is( $rv->{exit}, 0, 'handoff --note succeeds' ) or diag $rv->{stdout} . $rv->{stderr};

    is( _task($repo)->body, "a\n\nb",
        'the handoff note is a paragraph of its own' )
        or diag 'got: ' . _task($repo)->body;
};

subtest 'handoff --note on an empty body starts no blank line' => sub {
    my $repo = _setup_repo();

    my $move = _run_karr( $repo, 'move', 1, 'in-progress', '--claim', 'alice' );
    is( $move->{exit}, 0, 'seed: task claimed and in progress' ) or diag $move->{stderr};

    my $rv = _run_karr( $repo, 'handoff', 1, '--claim', 'alice', '--note', 'b' );
    is( $rv->{exit}, 0, 'handoff --note succeeds' ) or diag $rv->{stdout} . $rv->{stderr};

    is( _task($repo)->body, 'b',
        'the body is the note itself, with no leading separator' )
        or diag 'got: ' . _task($repo)->body;
};

subtest 'edit -a --timestamp dates the note the way handoff does' => sub {
    my $repo = _setup_repo( body => 'a' );

    my $rv = _run_karr( $repo, 'edit', 1, '-a', 'stamped note', '--timestamp' );
    is( $rv->{exit}, 0, 'edit -a --timestamp succeeds' )
        or diag $rv->{stdout} . $rv->{stderr};

    my $body = _task($repo)->body;
    like( $body, qr/\Aa\n\n\d{4}-\d{2}-\d{2} \d{2}:\d{2} stamped note\z/,
        'the UTC stamp prefixes the note inline, behind the blank-line separator' )
        or diag 'got: ' . $body;

    # The same shape handoff writes, character for character up to the clock:
    # one implementation, not two formats for the same idea.
    my $hrepo = _setup_repo( body => 'a' );
    my $move = _run_karr( $hrepo, 'move', 1, 'in-progress', '--claim', 'alice' );
    is( $move->{exit}, 0, 'seed: task claimed and in progress' ) or diag $move->{stderr};
    my $ho = _run_karr( $hrepo, 'handoff', 1, '--claim', 'alice',
        '--note', 'stamped note', '-t' );
    is( $ho->{exit}, 0, 'handoff --note -t succeeds' ) or diag $ho->{stderr};

    ( my $edit_shape = $body ) =~ s/\d/0/g;
    ( my $handoff_shape = _task($hrepo)->body ) =~ s/\d/0/g;
    is( $edit_shape, $handoff_shape,
        'edit -a -t and handoff --note -t write the same stamp format' );
};

subtest 'edit --timestamp alone names no change' => sub {
    my $repo = _setup_repo( body => 'a' );

    my $rv = _run_karr( $repo, 'edit', 1, '--timestamp' );
    is( $rv->{exit}, 2, '--timestamp on its own is a usage error (exit 2)' )
        or diag $rv->{stdout} . $rv->{stderr};
    like( $rv->{stderr}, qr/no changes specified/,
        '...and says so: a stamp decorates an append, it is not one' );
    is( _task($repo)->body, 'a', 'the body is untouched' );
};

# The trailing-newline case cannot be reached through the CLI: Task::_parse_content
# strips every trailing newline off a body it reads, so a stored body never has
# any (the normal form ticket #78 established). It is reachable in process, and
# it is the case kanban-md's strings.TrimRight guards, so it is pinned where it
# lives.
subtest 'Task::append_body trims the trailing newlines off the existing body' => sub {
    my %case = (
        'plain body'            => [ 'first',       "first\n\nsecond" ],
        'one trailing newline'  => [ "first\n",     "first\n\nsecond" ],
        'blank lines at the end'=> [ "first\n\n\n", "first\n\nsecond" ],
        'empty body'            => [ '',            'second' ],
        'newlines only'         => [ "\n\n",        'second' ],
        'body of "0"'           => [ '0',           "0\n\nsecond" ],
    );

    for my $name ( sort keys %case ) {
        my ( $existing, $want ) = @{ $case{$name} };
        my $task = App::karr::Task->new(
            id => 1, title => 'T', status => 'backlog', body => $existing,
        );
        $task->append_body('second');
        is( $task->body, $want, $name );
    }

    # Whitespace that is not a newline is content, not padding: kanban-md trims
    # newlines only, and so do we.
    my $task = App::karr::Task->new(
        id => 1, title => 'T', status => 'backlog', body => "first  \n",
    );
    $task->append_body('second');
    is( $task->body, "first  \n\nsecond", 'only newlines are trimmed' );
};

done_testing;
