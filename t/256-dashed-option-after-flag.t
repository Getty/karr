use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use TestKarr qw( run_karr );
use File::Temp qw( tempdir );
use Cwd qw( abs_path );
use IPC::Open3 qw( open3 );
use Symbol qw( gensym );
use JSON::MaybeXS qw( decode_json );

# Regression tests for karr board ticket #256.
#
# BUG: an option whose name has a dash in it is "Unknown option" as soon as a
#     boolean flag stands directly in front of it. The same option one place
#     earlier is fine:
#
#       karr list --claimed-by NAME          -> 0 task(s)                 (0)
#       karr list --json --claimed-by NAME   -> Unknown option: claimed-by (2)
#       karr list --not-blocked --compact    -> the list                  (0)
#       karr list --compact --not-blocked    -> Unknown option: not-blocked (2)
#
#     Nothing declares a dashed option name; the attribute is claimed_by, and
#     MooX::Options::Role::_options_fix_argv folds '-' to '_' in every option
#     name it walks past (4.103, line 148) before Getopt::Long is called. That
#     walk misses one position: having recognised an option it takes the next
#     token as that option's value unconditionally (line 171-172) and re-emits
#     it verbatim, unfolded. After a value-taking option the swallowed token
#     really is the value, so it must stay verbatim; after a BOOLEAN it is the
#     next flag, and it reaches Getopt::Long under a name the generated
#     specification does not have.
#
# UPSTREAM OR HERE (settled before writing this file): 4.103 is the current
#     MooX::Options release and still has the unconditional shift, so no
#     version pin fixes it and karr routes around it -- bin/karr respells the
#     option flags in argv with underscores before MooX::Cmd dispatches, via
#     App::karr::Role::CliArgs/normalize_option_argv. Folding a flag's own
#     dashes is safe because _options_fix_argv folds the same characters one
#     step later for every flag it does reach; the thing that must not be
#     folded is a value that merely looks like a flag, and the role's existing
#     option-table walk is what tells the two apart. Same weaker question as
#     #247: never what an option means, only whether it takes a value.
#
# Sections (a) and (b) are RED on the pre-fix tree, section (c) is GREEN there
# and has to stay that way -- above all `karr edit 1 --body --we-ird`, which a
# fix that simply folded every dashed token would corrupt, and `archive --jso 1`,
# which one that consumed after every unrecognised token would.

my $ROOT = abs_path('.');

# In-process runner (t/lib/TestKarr.pm): same ($cwd, @argv) signature and
# { exit, stdout, stderr } return as the open3 helper this file used to carry,
# dispatched through the shared App::karr::Dispatch path. KARR_TEST_SUBPROC=1
# restores the old open3 path. bin/karr-foundation is a separate binary with
# no in-process runner, so _run_foundation below is unchanged.
sub _run_karr { return run_karr(@_) }

sub _run_foundation {
    my (@argv) = @_;

    my $stderr = gensym;
    my $pid = open3(
        undef,
        my $stdout_fh,
        $stderr,
        $^X,
        "-I$ROOT/lib",
        "$ROOT/bin/karr-foundation",
        @argv,
    );

    my $stdout = do { local $/; <$stdout_fh> };
    my $stderr_text = do { local $/; <$stderr> };
    waitpid( $pid, 0 );
    my $exit = $? >> 8;

    return {
        exit   => $exit,
        stdout => defined $stdout ? $stdout : '',
        stderr => defined $stderr_text ? $stderr_text : '',
    };
}

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

    my $init = _run_karr( $repo, 'init', '--name', 'Dashed-Option Board' );
    is( $init->{exit}, 0, 'karr init succeeds' ) or diag $init->{stderr};

    return $repo;
}

sub _seed_tasks {
    my ( $repo, $n ) = @_;
    for my $i ( 1 .. $n ) {
        my $rv = _run_karr( $repo, 'create', '--title', "Task $i", '--status', 'todo' );
        is( $rv->{exit}, 0, "seed task $i created" ) or diag $rv->{stderr};
    }
}

sub _show { my ( $r, $i ) = @_; _run_karr( $r, 'show', $i )->{stdout} }

# ------------------------------------------------------- (a) RED, #256:
# the two orders of the same invocation give the same answer.

subtest 'list --json --claimed-by NAME: the exact ticket repro (RED)' => sub {
    my $repo = _setup_repo();
    _seed_tasks( $repo, 2 );

    my $claim = _run_karr( $repo, 'move', 1, 'in-progress', '--claim', 'test-agent' );
    is( $claim->{exit}, 0, 'task 1 claimed' ) or diag $claim->{stderr};

    my $flag_first = _run_karr( $repo, 'list', '--json', '--claimed-by', 'test-agent' );
    my $opt_first  = _run_karr( $repo, 'list', '--claimed-by', 'test-agent', '--json' );

    is( $flag_first->{exit}, 0, '--json --claimed-by NAME exits 0' )
        or diag $flag_first->{stderr};
    unlike( $flag_first->{stderr}, qr/Unknown option/,
        'the option behind the flag is not reported as unknown' );
    is( $flag_first->{stdout}, $opt_first->{stdout},
        'both orders return the same JSON' );

    my $tasks = eval { decode_json( $flag_first->{stdout} ) } || [];
    is( scalar @$tasks, 1, 'the filter actually filtered: one claimed task' );
    is( $tasks->[0]{id}, 1, 'and it is the claimed one' );
};

subtest 'list --compact --not-blocked: a dashed boolean behind a boolean (RED)' => sub {
    my $repo = _setup_repo();
    _seed_tasks( $repo, 2 );

    my $blocked = _run_karr( $repo, 'edit', 2, '--block', 'waiting' );
    is( $blocked->{exit}, 0, 'task 2 blocked' ) or diag $blocked->{stderr};

    my $flag_first = _run_karr( $repo, 'list', '--compact', '--not-blocked' );
    my $opt_first  = _run_karr( $repo, 'list', '--not-blocked', '--compact' );

    is( $flag_first->{exit}, 0, '--compact --not-blocked exits 0' )
        or diag $flag_first->{stderr};
    unlike( $flag_first->{stderr}, qr/Unknown option/, 'not reported as unknown' );
    is( $flag_first->{stdout}, $opt_first->{stdout},
        'both orders print the same list' );
    like( $flag_first->{stdout}, qr/^#1\s/m, 'the unblocked task is listed' );
    unlike( $flag_first->{stdout}, qr/^#2\s/m, 'the blocked one is filtered out' );
};

subtest 'edit --unblock --add-tag: the write path, not just the reader (RED)' => sub {
    my $repo = _setup_repo();
    _seed_tasks( $repo, 1 );

    my $rv = _run_karr( $repo, 'edit', 1, '--unblock', '--add-tag', 'behind-a-flag' );

    is( $rv->{exit}, 0, 'edit 1 --unblock --add-tag TAG exits 0' ) or diag $rv->{stderr};
    like( _show( $repo, 1 ), qr/^Tags:\s+behind-a-flag$/m, 'the tag was added' );
};

subtest 'root option, command, then the broken order (RED)' => sub {
    my $repo = _setup_repo();
    _seed_tasks( $repo, 1 );

    # --dir in front of the command is the documented orchestrator form (#71).
    # The normalization has to split argv the way MooX::Cmd does, or the
    # command's option table is applied to the wrong slice.
    my $rv = _run_karr( $ROOT, '--dir', $repo, 'list', '--json', '--claimed-by', 'nobody' );

    is( $rv->{exit}, 0, 'karr --dir PATH list --json --claimed-by NAME exits 0' )
        or diag $rv->{stderr};
    is_deeply( eval { decode_json( $rv->{stdout} ) }, [], 'nobody has claimed anything' );
};

subtest 'context --json --activity-limit N: a dashed value option on a second command (RED)' => sub {
    my $repo = _setup_repo();
    _seed_tasks( $repo, 1 );

    my $flag_first = _run_karr( $repo, 'context', '--json', '--activity-limit', 2 );
    my $opt_first  = _run_karr( $repo, 'context', '--activity-limit', 2, '--json' );

    is( $flag_first->{exit}, 0, 'context --json --activity-limit 2 exits 0' )
        or diag $flag_first->{stderr};
    is( $flag_first->{stdout}, $opt_first->{stdout}, 'both orders agree' );
};

subtest 'init --new-board --claude-skill: two booleans in a row (RED)' => sub {
    my $repo = tempdir( CLEANUP => 1 );
    _git_ok( 'git', 'init', '-q', $repo );
    _git_ok( 'git', '-C', $repo, 'config', 'user.email', 'test@example.com' );
    _git_ok( 'git', '-C', $repo, 'config', 'user.name', 'Test User' );

    my $rv = _run_karr( $repo, 'init', '--new-board', '--claude-skill', '--name', 'Fresh' );

    is( $rv->{exit}, 0, 'init --new-board --claude-skill exits 0' ) or diag $rv->{stderr};
    unlike( $rv->{stderr}, qr/Unknown option/, 'neither dashed flag is unknown' );
    like( $rv->{stdout}, qr/Installed Claude Code skill/, '--claude-skill took effect' );
};

# ------------------------------------------------------- (b) RED, #256:
# the closed class. Every karr command with an underscore in an option name
# had the defect, in exactly the position tested above -- so pin the whole set
# at the level where the fix lives, rather than inventing a valid invocation
# for each of the seventeen options.

subtest 'every Cmd class can normalize its own argv (RED)' => sub {
    require App::karr;

    my $commands = App::karr->_build_command_commands( {} );
    my %seen;
    my @classes = grep { !$seen{$_}++ } sort values %$commands;
    ok( scalar @classes >= 25, 'the command scan found the command classes' );

    for my $class (@classes) {
        eval "require $class; 1" or do { fail("$class loads: $@"); next };
        ok( $class->can('normalize_option_argv'),
            "$class composes App::karr::Role::CliArgs" );
    }
};

subtest 'every dashed option survives a boolean flag in front of it (RED)' => sub {
    require App::karr;

    my $commands = App::karr->_build_command_commands( {} );
    my %seen;
    my @classes = grep { !$seen{$_}++ } sort values %$commands;

    my $dashed = 0;
    for my $class (@classes) {
        eval "require $class; 1" or next;
        next unless $class->can('_options_data') && $class->can('normalize_option_argv');

        my %data    = $class->_options_data;
        my @dashed  = sort grep { /_/ } keys %data;
        my ($flag)  = sort grep { !defined $data{$_}{format} } keys %data;
        next unless @dashed && defined $flag;

        for my $name (@dashed) {
            ( my $spelled = $name ) =~ tr/_/-/;
            my @argv = ( "--$flag", "--$spelled" );
            push @argv, 'VALUE' if defined $data{$name}{format};

            my @normalized = $class->normalize_option_argv( \@argv );
            is( $normalized[1], "--$name",
                "$class: --$spelled behind --$flag reaches Getopt::Long as --$name" );
            $dashed++;
        }
    }

    cmp_ok( $dashed, '>=', 19,
        "the whole affected set was checked (19 dashed options at #256, $dashed now)" );
};

subtest 'even a typo behind a flag is folded before it is reported (RED)' => sub {
    my $repo = _setup_repo();

    # The defect is not only about options that exist: the swallowed token
    # reached Getopt::Long unfolded whatever it was, so `--json --bogus-opt`
    # answered "Unknown option: bogus-opt" while `--bogus-opt` alone answered
    # "Unknown option: bogus_opt". Same mistake, two spellings of the report.
    my $rv = _run_karr( $repo, 'list', '--json', '--bogus-opt' );

    is( $rv->{exit}, 2, 'list --json --bogus-opt exits 2' );
    like( $rv->{stderr}, qr/Unknown option: bogus_opt/,
        'and names it the same way it does without the flag in front' );
};

subtest 'a dashed abbreviation resolves behind a flag too (RED)' => sub {
    my $repo = _setup_repo();
    _seed_tasks( $repo, 1 );

    # The fold happens before MooX::Options' own prefix resolution, so both
    # engines still see a prefix and neither has to be second-guessed (#247).
    my $rv = _run_karr( $repo, 'list', '--json', '--claimed-b', 'nobody' );

    is( $rv->{exit}, 0, 'list --json --claimed-b nobody exits 0' ) or diag $rv->{stderr};
    is_deeply( eval { decode_json( $rv->{stdout} ) }, [], 'and filters on nobody' );
};

subtest 'normalize_option_argv touches flags only (RED)' => sub {
    require App::karr::Cmd::List;
    require App::karr::Cmd::Edit;

    is_deeply(
        [ App::karr::Cmd::List->normalize_option_argv( [qw( --json --claimed-by a-name )] ) ],
        [qw( --json --claimed_by a-name )],
        'the flag is folded, its value is not' );
    is_deeply(
        [ App::karr::Cmd::List->normalize_option_argv( ['--claimed-by=a-name'] ) ],
        ['--claimed_by=a-name'],
        'an inline value keeps its dashes' );
    # The carrier changed with #259 -- a flag-shaped value now rides inline on
    # its own option instead of standing behind it -- but the promise this and
    # the short-option pin below make is the same one, and #259 is what makes
    # it hold in every argv position: the value keeps its dashes and is never
    # read as a flag.
    is_deeply(
        [ App::karr::Cmd::Edit->normalize_option_argv( [qw( --body --we-ird )] ) ],
        [qw( --body=--we-ird )],
        'a flag-shaped value keeps its dashes, carried inline' );
    is_deeply(
        [ App::karr::Cmd::Edit->normalize_option_argv( [ '--timestamp', '--', '--we-ird' ] ) ],
        [ '--timestamp', '--', '--we-ird' ],
        'nothing after the separator is folded' );
    is_deeply(
        [ App::karr::Cmd::Edit->normalize_option_argv( [qw( -a --we-ird )] ) ],
        [qw( --append_body=--we-ird )],
        'a short option is resolved to its long name to carry the value' );
    is_deeply(
        [ App::karr::Cmd::List->normalize_option_argv( ['--no-not-blocked'] ) ],
        ['--no-not_blocked'],
        'a leading no- is left standing for MooX::Options to read as negation' );
};

# ------------------------------------------------------- (d) RED, #256:
# the OTHER binary. bin/karr respells argv before MooX::Cmd dispatches, but
# bin/karr-foundation calls new_with_options straight, so the same defect
# survives there -- dry_run is its only option whose name folds, and
# `--verbose --dry-run` is the spelling the SYNOPSIS itself invites.
#
# Pointed at a config path that does not exist on purpose: the binary then
# says so and exits 0 without touching a repository, which makes the two
# orders comparable byte for byte and keeps the developer's own fleet config
# out of the test.

subtest 'karr-foundation --verbose --dry-run: the same defect, one binary over (RED)' => sub {
    my $missing = tempdir( CLEANUP => 1 ) . '/no-such-config.yml';
    ok( !-e $missing, 'the config path really does not exist' );

    my $flag_first = _run_foundation( '--config', $missing, '--verbose', '--dry-run' );
    my $opt_first  = _run_foundation( '--config', $missing, '--dry-run', '--verbose' );

    unlike( $flag_first->{stderr}, qr/Unknown option/,
        'the dashed option behind the flag is not reported as unknown' );
    is( $flag_first->{exit}, $opt_first->{exit},
        'both orders exit the same' );
    is( $flag_first->{stderr}, $opt_first->{stderr},
        'both orders say the same thing' );
};

subtest 'App::karr::Foundation normalizes its own argv (RED)' => sub {
    require App::karr::Foundation;

    can_ok( 'App::karr::Foundation', 'normalize_option_argv' )
        or return;

    is_deeply(
        [ App::karr::Foundation->normalize_option_argv( [qw( --verbose --dry-run )] ) ],
        [qw( --verbose --dry_run )],
        'the flag behind a boolean is respelled' );
    is_deeply(
        [ App::karr::Foundation->normalize_option_argv( [ '--note', '--we-ird' ] ) ],
        [ '--note=--we-ird' ],
        'a flag-shaped value keeps its dashes, carried inline (#259)' );
    is_deeply(
        [ App::karr::Foundation->normalize_option_argv( [qw( answer 7 darkpan )] ) ],
        [qw( answer 7 darkpan )],
        'the hub command and its positionals are untouched' );
};

# ------------------------------------------------------- (e) RED, #259:
# the other half of the same upstream shift. #256 fixed the case where a
# BOOLEAN is followed by an option whose name has a dash. This is the case
# where a boolean is followed by a VALUE-TAKING option whose value looks like
# a flag: _options_fix_argv swallows the value-taking option as the boolean's
# value, so the value behind it lands in flag position and is folded --
#
#     karr edit 1 --json -a --dashed-note      stored --dashed_note
#     karr list --json --claimed-by --weird-name   filtered on --weird_name
#
# -- and the second one is the worse shape, because #256 turned what used to
# be a loud `Unknown option: claimed-by` (exit 2) into a silent exit 0 with an
# empty list: a plausible answer to a question nobody typed, which #225, #226
# and #251 all rank below an error message.
#
# The value is never in doubt here. _classify_argv has already decided that
# this token is the value of the option in front of it -- the same weaker
# question #247 settled -- so the fix is to hand it over in a form
# _options_fix_argv cannot read as a flag whatever stands in front of it.

subtest 'edit --json -a --dashed-note stores the value as typed (RED)' => sub {
    my $repo = _setup_repo();
    _seed_tasks( $repo, 1 );

    my $rv = _run_karr( $repo, 'edit', 1, '--json', '-a', '--dashed-note' );
    is( $rv->{exit}, 0, 'the edit succeeds' ) or diag $rv->{stderr};

    my $body = _show( $repo, 1 );
    like( $body, qr/--dashed-note/, 'the body carries the value as typed' );
    unlike( $body, qr/--dashed_note/, 'and not the folded spelling' );
};

subtest 'list --json --claimed-by --weird-name filters on what was typed (RED)' => sub {
    my $repo = _setup_repo();
    _seed_tasks( $repo, 2 );

    my $claim = _run_karr( $repo, 'move', 1, 'in-progress', '--claim', '--weird-name' );
    is( $claim->{exit}, 0, 'a card is claimed under a flag-shaped name' )
        or diag $claim->{stderr};

    my $flag_first = _run_karr( $repo, 'list', '--json', '--claimed-by', '--weird-name' );
    my $opt_first  = _run_karr( $repo, 'list', '--claimed-by', '--weird-name', '--json' );

    is( $flag_first->{exit}, 0, '--json --claimed-by VALUE exits 0' )
        or diag $flag_first->{stderr};
    is( $flag_first->{stdout}, $opt_first->{stdout},
        'both orders return the same JSON' );

    my $found = decode_json( $flag_first->{stdout} );
    is( scalar(@$found), 1, 'the claimed card is found, not a silent empty list' );
};

subtest 'a flag-shaped value is handed over inline (RED)' => sub {
    require App::karr::Cmd::Edit;
    require App::karr::Cmd::List;

    is_deeply(
        [ App::karr::Cmd::Edit->normalize_option_argv( [qw( --json -a --dashed-note )] ) ],
        [qw( --json --append_body=--dashed-note )],
        'a short option is resolved to its long name to carry the value' );
    is_deeply(
        [ App::karr::Cmd::List->normalize_option_argv( [qw( --json --claimed-by --weird-name )] ) ],
        [qw( --json --claimed_by=--weird-name )],
        'a long option keeps its own spelling and takes the value inline' );
    is_deeply(
        [ App::karr::Cmd::Edit->normalize_option_argv( [qw( --prio --weird )] ) ],
        [qw( --prio=--weird )],
        'an abbreviation is not resolved -- the = is all it needs (#247)' );
    is_deeply(
        [ App::karr::Cmd::Edit->normalize_option_argv( [qw( --body plain-value )] ) ],
        [qw( --body plain-value )],
        'a value that is not flag-shaped is left in space form' );
    is_deeply(
        [ App::karr::Cmd::Edit->normalize_option_argv( [ '--timestamp', '--', '--we-ird' ] ) ],
        [ '--timestamp', '--', '--we-ird' ],
        'nothing after the separator is touched' );
};

# ------------------------------------------------------- (c) GREEN pins:
# what the fix must not break. A flag-shaped VALUE keeps its dashes, the
# end-of-options separator still ends options, and #243/#247 still hold.

subtest 'a flag-shaped value keeps its dashes (GREEN)' => sub {
    my $repo = _setup_repo();
    _seed_tasks( $repo, 1 );

    my $rv = _run_karr( $repo, 'edit', 1, '--body', '--we-ird' );
    is( $rv->{exit}, 0, 'edit 1 --body --we-ird exits 0' ) or diag $rv->{stderr};
    like( _show( $repo, 1 ), qr/^--we-ird$/m,
        'the value is stored verbatim, not folded to --we_ird' );

    my $append = _run_karr( $repo, 'edit', 1, '-a', '--also-dashed' );
    is( $append->{exit}, 0, 'edit 1 -a --also-dashed exits 0' ) or diag $append->{stderr};
    like( _show( $repo, 1 ), qr/^--also-dashed$/m,
        'a short option keeps its dashed value too' );
};

subtest 'the -- separator still ends option processing (GREEN, #72)' => sub {
    my $repo = _setup_repo();

    my $rv = _run_karr( $repo, 'create', '--', '--not-blocked' );
    is( $rv->{exit}, 0, 'create -- --not-blocked exits 0' ) or diag $rv->{stderr};
    like( $rv->{stdout}, qr/Created task 1: --not-blocked/,
        'the escaped title is the literal token, dashes and all' );
};

subtest 'abbreviations still consume their value (GREEN, #247)' => sub {
    my $repo = _setup_repo();
    _seed_tasks( $repo, 1 );

    my $abbrev = _run_karr( $repo, 'edit', 1, '--prio', 'high' );
    is( $abbrev->{exit}, 0, 'edit 1 --prio high exits 0' ) or diag $abbrev->{stderr};
    like( _show( $repo, 1 ), qr/^Priority:\s+high$/m, 'the abbreviation set the value' );

    # The case a "fold and consume everything" fix would have broken.
    my $boolean = _run_karr( $repo, 'archive', '--jso', 1 );
    is( $boolean->{exit}, 0, 'archive --jso 1 exits 0' ) or diag $boolean->{stderr};
    unlike( $boolean->{stderr}, qr/unexpected extra argument/,
        'the id after a boolean abbreviation is still the positional' );
};

subtest 'an unknown dashed option alone still reports the folded name (GREEN)' => sub {
    my $repo = _setup_repo();

    my $rv = _run_karr( $repo, 'list', '--bogus-opt' );

    is( $rv->{exit}, 2, 'list --bogus-opt exits 2' );
    like( $rv->{stderr}, qr/Unknown option: bogus_opt/,
        'MooX::Options folds a typo the same way, so the message is unchanged' );
};

subtest 'the empty-argument guard still fires first (GREEN, #243)' => sub {
    my $repo = _setup_repo();
    _seed_tasks( $repo, 1 );

    my $rv = _run_karr( $repo, 'list', '--json', '', '--claimed-by', 'nobody' );

    is( $rv->{exit}, 2, 'an empty argument still exits 2' );
    like( $rv->{stderr}, qr/^Usage error: argument 3 is empty/,
        'and is still refused before anything else looks at argv' );
};

subtest 'surplus positionals are still counted after the fold (GREEN, #247)' => sub {
    my $repo = _setup_repo();
    _seed_tasks( $repo, 1 );

    my $rv = _run_karr( $repo, 'archive', 1, '--json', 99 );

    is( $rv->{exit}, 2, 'archive 1 --json 99 exits 2' );
    like( $rv->{stderr}, qr/unexpected extra argument: '99'/,
        'the trailing positional is still named' );
};

subtest 'positional_args is unchanged by the shared walk (GREEN)' => sub {
    require App::karr::Cmd::Edit;

    is_deeply(
        [ App::karr::Cmd::Edit->positional_args( [qw( 1 --claim tester --timestamp )] ) ],
        ['1'],
        'a space-form value is not a positional' );
    is_deeply(
        [ App::karr::Cmd::Edit->positional_args( [qw( --priority=high 1 )] ) ],
        ['1'],
        'an inline value consumes nothing after it' );
    is_deeply(
        [ App::karr::Cmd::Edit->positional_args( [ '--timestamp', '--', '--json' ] ) ],
        ['--json'],
        'the separator itself is dropped and the rest are positionals' );
    is_deeply(
        [ App::karr::Cmd::Edit->positional_args( [qw( --prio high 1 )] ) ],
        ['1'],
        'an abbreviated value option still consumes its value (#247)' );
};

done_testing;
