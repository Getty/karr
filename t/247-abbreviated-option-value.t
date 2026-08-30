use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use TestKarr qw( run_karr );
use File::Temp qw( tempdir );
use JSON::MaybeXS qw( decode_json );

# Regression tests for karr board ticket #247.
#
# BUG: an abbreviated option that takes a value loses that value to the
#     positionals, and the resulting message blames the value:
#
#       karr edit 1 --unbl          -> Updated task 1        (boolean: fine)
#       karr edit 1 --prio=high     -> Updated task 1        (inline value: fine)
#       karr edit 1 --prio high     -> unexpected extra argument: 'high'  (2)
#       karr edit 1 --tit "Renamed" -> unexpected extra argument: 'Renamed' (2)
#
#     Exactly one shape is affected: an abbreviated option that consumes a
#     value, given in space form. The option itself parses -- an abbreviation
#     that did not would say "Unknown option" -- but
#     App::karr::Role::CliArgs matched the token against %{_options_data} by
#     its full name only, found nothing, and fell through to the branch that
#     treats an unrecognised dash token as non-consuming. The following token
#     was therefore counted as a positional, and check_positional_args named
#     it as the surplus one -- pointing the caller at their value while the
#     mistake sat in the abbreviation in front of it.
#
# WHERE ABBREVIATIONS ARE RESOLVED (probed before writing this file, because
#     the fix has to sit downstream of it rather than duplicate it):
#     MooX::Options::Role::_options_fix_argv rewrites a prefix that matches
#     exactly one option to that option's full name BEFORE Getopt::Long is
#     called; Getopt::Long sees only what MooX::Options could not resolve, and
#     is what reports "Option ti is ambiguous (timestamp, title)". Both engines
#     match on a plain, case-sensitive prefix (--PRIORITY is "Unknown option"
#     here, so ignore_case is off). Either way, an abbreviation that survives
#     option parsing resolved to exactly one option, and an ambiguous one exits
#     2 before execute() ever runs -- which is why CliArgs never has to pick a
#     winner and must not pre-empt the ambiguity path.
#
# Section (a) is RED on the pre-fix tree, section (b) is GREEN there and has to
# stay that way -- in particular the boolean abbreviation in front of a
# positional (`archive --jso 1`), which a fix that simply flipped the
# unrecognised-token default to "consuming" would break.

# In-process runner (t/lib/TestKarr.pm): same ($cwd, @argv) signature and
# { exit, stdout, stderr } return as the open3 helper this file used to carry,
# dispatched through the shared App::karr::Dispatch path. KARR_TEST_SUBPROC=1
# restores the old open3 path.
sub _run_karr { return run_karr(@_) }

sub _git_ok {
    my (@cmd) = @_;
    my $rc = system(@cmd);
    is( $rc, 0, "@cmd" );
}

# Fresh isolated temp repo per subtest, never the developer's real board.
sub _setup_repo {
    my $repo = tempdir( CLEANUP => 1 );
    _git_ok( 'git', 'init', '-q', $repo );
    _git_ok( 'git', '-C', $repo, 'config', 'user.email', 'test@example.com' );
    _git_ok( 'git', '-C', $repo, 'config', 'user.name', 'Test User' );

    my $init = _run_karr( $repo, 'init', '--name', 'Abbreviated-Option Board' );
    is( $init->{exit}, 0, 'karr init succeeds' ) or diag $init->{stderr};

    return $repo;
}

sub _seed_tasks {
    my ( $repo, $n, %opts ) = @_;
    my $status = $opts{status} // 'todo';
    for my $i ( 1 .. $n ) {
        my $rv = _run_karr( $repo, 'create', '--title', "Task $i", '--status', $status );
        is( $rv->{exit}, 0, "seed task $i created" ) or diag $rv->{stderr};
    }
}

sub _field_of {
    my ( $repo, $id, $label ) = @_;
    my $rv = _run_karr( $repo, 'show', $id );
    return undef unless $rv->{exit} == 0;
    return $1 if $rv->{stdout} =~ /^\Q$label\E:\s+(.+?)\s*$/m;
    return undef;
}

sub _title_of    { my ( $r, $i ) = @_; my $rv = _run_karr( $r, 'show', $i );
                   return undef unless $rv->{exit} == 0;
                   return $1 if $rv->{stdout} =~ /^Task #\d+: (.+)$/m; return undef }
sub _status_of   { _field_of( @_[ 0, 1 ], 'Status' ) }
sub _priority_of { _field_of( @_[ 0, 1 ], 'Priority' ) }
sub _claimed_of  { _field_of( @_[ 0, 1 ], 'Claimed' ) }

# --------------------------------------------------------- (a) RED, #247:
# an abbreviated option keeps the value it consumes, and the value never
# reaches the positionals.

subtest 'edit 1 --prio high: the exact ticket repro (RED, ticket #247)' => sub {
    my $repo = _setup_repo();
    _seed_tasks( $repo, 1 );

    my $rv = _run_karr( $repo, 'edit', 1, '--prio', 'high' );

    is( $rv->{exit}, 0, 'edit 1 --prio high exits 0' ) or diag $rv->{stderr};
    unlike( $rv->{stderr}, qr/unexpected extra argument/,
        'the value is never reported as a surplus positional' );
    is( _priority_of( $repo, 1 ), 'high', 'priority is high, as with --priority' );
};

subtest 'edit 1 --tit "Renamed": abbreviation with a text value (RED, ticket #247)' => sub {
    my $repo = _setup_repo();
    _seed_tasks( $repo, 1 );

    my $rv = _run_karr( $repo, 'edit', 1, '--tit', 'Renamed' );

    is( $rv->{exit}, 0, 'edit 1 --tit Renamed exits 0' ) or diag $rv->{stderr};
    is( _title_of( $repo, 1 ), 'Renamed', 'title is Renamed, as with --title' );
};

subtest 'edit --prio critical 1: abbreviation before the id (RED, ticket #247)' => sub {
    my $repo = _setup_repo();
    _seed_tasks( $repo, 1 );

    # The worst spelling of the bug: here the surplus positional the pre-fix
    # tree names is the id itself ("unexpected extra argument: '1'"), because
    # the swallowed value took the id's place in the count.
    my $rv = _run_karr( $repo, 'edit', '--prio', 'critical', 1 );

    is( $rv->{exit}, 0, 'edit --prio critical 1 exits 0' ) or diag $rv->{stderr};
    is( _priority_of( $repo, 1 ), 'critical', 'priority is critical' );
};

subtest 'move 1 --cla tester in-progress: abbreviation between positionals (RED, ticket #247)' => sub {
    my $repo = _setup_repo();
    _seed_tasks( $repo, 1 );

    my $rv = _run_karr( $repo, 'move', 1, '--cla', 'tester', 'in-progress' );

    is( $rv->{exit}, 0, 'move 1 --cla tester in-progress exits 0' ) or diag $rv->{stderr};
    is( _status_of( $repo, 1 ), 'in-progress', 'task 1 moved to in-progress' );
    is( _claimed_of( $repo, 1 ), 'tester', 'task 1 claimed by tester' );
};

subtest 'show --la 2: abbreviation whose value is a count (RED, ticket #247)' => sub {
    my $repo = _setup_repo();
    _seed_tasks( $repo, 2 );

    my $short = _run_karr( $repo, 'show', '--la', 2 );
    my $long  = _run_karr( $repo, 'show', '--last', 2 );

    is( $short->{exit}, 0, 'show --la 2 exits 0' ) or diag $short->{stderr};
    is( $short->{stdout}, $long->{stdout}, 'show --la 2 renders exactly what --last 2 renders' );

    my @headings = ( $short->{stdout} =~ /^Task #\d+:/mg );
    is( scalar @headings, 2,
        'two tasks are rendered -- the 2 was the value of --last, not an id positional' );
};

# The two below compose App::karr::Role::CliArgs directly rather than through
# App::karr::Role::BoardAccess, which is the other build shape in the
# distribution. get-refs is also the one that answers wrongly instead of
# refusing: it reads positional_args()[0] as the ref name without an arity
# check, so on the pre-fix tree the swallowed --dir value became the ref.

subtest 'skill check --ag claude-code: direct CliArgs consumer (RED, ticket #247)' => sub {
    my $repo = _setup_repo();

    my $short = _run_karr( $repo, 'skill', 'check', '--ag', 'claude-code' );
    my $long  = _run_karr( $repo, 'skill', 'check', '--agent', 'claude-code' );

    is( $short->{exit}, 0, 'skill check --ag claude-code exits 0' ) or diag $short->{stderr};
    is( $short->{stdout}, $long->{stdout}, '--ag reports exactly what --agent reports' );
};

subtest 'get-refs --di . REF: wrong answer, not a refusal (RED, ticket #247)' => sub {
    my $repo = _setup_repo();

    my $set = _run_karr( $repo, 'set-refs', 'probe/ref', 'hello' );
    is( $set->{exit}, 0, 'set-refs probe/ref hello exits 0' ) or diag $set->{stderr};

    my $rv = _run_karr( $repo, 'get-refs', '--di', '.', 'probe/ref' );

    is( $rv->{exit}, 0, 'get-refs --di . probe/ref exits 0' ) or diag $rv->{stderr};
    is( $rv->{stdout}, "hello\n", 'stdout is the payload, not an error about the ref name' );
};

# ---------------------------------------------------- (b) GREEN pins, #247:
# everything that already worked has to keep working, byte for byte where the
# ticket names the wording.

subtest 'edit 1 --unbl: a boolean abbreviation still consumes nothing (GREEN pin)' => sub {
    my $repo = _setup_repo();
    _seed_tasks( $repo, 1 );

    my $blocked = _run_karr( $repo, 'edit', 1, '--block', 'waiting' );
    is( $blocked->{exit}, 0, 'edit 1 --block waiting exits 0' ) or diag $blocked->{stderr};

    my $rv = _run_karr( $repo, 'edit', 1, '--unbl' );

    is( $rv->{exit}, 0, 'edit 1 --unbl exits 0' ) or diag $rv->{stderr};
    unlike( _run_karr( $repo, 'show', 1 )->{stdout}, qr/^Blocked:/m,
        'task 1 is no longer blocked' );
};

subtest 'archive --jso 1: a boolean abbreviation must not eat the positional (GREEN pin)' => sub {
    my $repo = _setup_repo();
    _seed_tasks( $repo, 1 );

    my $rv = _run_karr( $repo, 'archive', '--jso', 1 );

    is( $rv->{exit}, 0, 'archive --jso 1 exits 0' ) or diag $rv->{stderr};

    my $data = eval { decode_json( $rv->{stdout} ) };
    ok( $data, 'stdout is valid JSON -- --jso was honoured as --json' )
        or diag "stdout was: $rv->{stdout}";
    is( $data->{id}, 1, 'JSON reports id 1' ) if $data;

    is( _status_of( $repo, 1 ), 'archived', 'task 1 is archived -- the id survived --jso' );
};

subtest 'edit 1 --prio=high: the inline-value form is unchanged (GREEN pin)' => sub {
    my $repo = _setup_repo();
    _seed_tasks( $repo, 1 );

    my $rv = _run_karr( $repo, 'edit', 1, '--prio=high' );

    is( $rv->{exit}, 0, 'edit 1 --prio=high exits 0' ) or diag $rv->{stderr};
    is( _priority_of( $repo, 1 ), 'high', 'priority is high' );
};

subtest 'edit 1 --ti X: the ambiguity path stays Getopt::Long\'s (GREEN pin)' => sub {
    my $repo = _setup_repo();
    _seed_tasks( $repo, 1 );

    # --timestamp (ticket #238) made --ti ambiguous with --title. That message
    # comes from Getopt::Long, before execute() runs at all, and the fix must
    # not pre-empt it with a guess of its own.
    my $rv = _run_karr( $repo, 'edit', 1, '--ti', 'X' );

    is( $rv->{exit}, 2, 'edit 1 --ti X exits 2' );
    like( $rv->{stderr}, qr/Option ti is ambiguous \(timestamp, title\)/,
        'the ambiguity is still reported verbatim by Getopt::Long' );
    is( _title_of( $repo, 1 ), 'Task 1', 'nothing was written' );
};

subtest 'edit 1 99 --prio high: surplus positionals still rejected, and only they are named (RED+GREEN, ticket #247)' => sub {
    my $repo = _setup_repo();
    _seed_tasks( $repo, 1 );

    my $rv = _run_karr( $repo, 'edit', 1, 99, '--prio', 'high' );

    is( $rv->{exit}, 2, 'edit 1 99 --prio high exits 2' );
    like( $rv->{stderr}, qr/unexpected extra argument: '99'/,
        'the message names the surplus id' );
    unlike( $rv->{stderr}, qr/'high'/,
        'the message no longer accuses the option value as well' );
    is( _priority_of( $repo, 1 ), 'medium', 'nothing was written' );
};

subtest 'create -- --json: the end-of-options separator is unchanged (GREEN pin)' => sub {
    my $repo = _setup_repo();

    my $rv = _run_karr( $repo, 'create', '--', '--json' );

    is( $rv->{exit}, 0, 'create -- --json exits 0' ) or diag $rv->{stderr};
    is( _title_of( $repo, 1 ), '--json', 'the escaped token became the title' );
};

subtest 'value-carrying short and long forms are unchanged (GREEN pin)' => sub {
    my $repo = _setup_repo();
    _seed_tasks( $repo, 1 );

    my $short = _run_karr( $repo, 'edit', 1, '-a', 'from the short form' );
    is( $short->{exit}, 0, 'edit 1 -a TEXT exits 0' ) or diag $short->{stderr};

    my $abbrev = _run_karr( $repo, 'edit', 1, '--appen', 'from the abbreviation' );
    is( $abbrev->{exit}, 0, 'edit 1 --appen TEXT exits 0' ) or diag $abbrev->{stderr};

    my $show = _run_karr( $repo, 'show', 1 );
    like( $show->{stdout}, qr/from the short form/,   'the -a text is in the body' );
    like( $show->{stdout}, qr/from the abbreviation/, 'the --appen text is in the body' );
};

subtest 'the empty-argument guard (#243) still fires in front of all this (GREEN pin)' => sub {
    my $repo = _setup_repo();
    _seed_tasks( $repo, 1 );

    my $rv = _run_karr( $repo, 'edit', '', '--prio', 'high' );

    is( $rv->{exit}, 2, 'edit "" --prio high exits 2' );
    like( $rv->{stderr}, qr/^Usage error: argument 2 is empty/,
        'the empty argument is still refused before any command sees it' );
};

done_testing;
