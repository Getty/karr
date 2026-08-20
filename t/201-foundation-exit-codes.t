use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use File::Temp qw( tempdir );
use Path::Tiny qw( path );
use Cwd qw( abs_path getcwd );
use IPC::Open3 qw( open3 );
use Symbol qw( gensym );

# Ticket #201: karr-foundation joins the exit-code contract
# (docs/adr/0002-exit-code-contract.md, the same one t/57-exit-code-contract.t
# pins for bin/karr).
#
#   0  success
#   1  runtime failure
#   2  usage error
#
# Before the fix bin/karr-foundation had no central handler at all: it ran
#
#     my $foundation = App::karr::Foundation->new_with_options;
#     exit $foundation->run(@ARGV);
#
# so every user_error left perl to invent the status. Probed against the
# pre-fix tree, all of these were the accident and none of them were 1 or 2:
#
#   $ karr-foundation --config <a YAML sequence>        # exit 255
#   Config must be a YAML mapping
#   $ karr-foundation wibble                            # exit 25 (errno!)
#   Unknown command 'wibble' (expected: answer, ask)
#   $ karr-foundation answer 1 cpan                     # exit 25, question settled
#   Question #1 was already answered 'darkpan'
#   $ karr-foundation --totally-bogus                   # exit 1 -- indistinguishable
#   Unknown option: totally_bogus                       # from a failed drain
#
# 25 is ENOTTY left in $! by an earlier check: the code a caller saw was not
# even stable between runs. That is why this test pins the *exact* code
# everywhere and never settles for "non-zero" -- non-zero is what the old
# behaviour already satisfied, and t/120-error-message-sweep.t asserting it for
# the two config errors is exactly why nobody noticed.
#
# No agent is ever started here: the only invocations that reach a board are
# --status (read-only overview) and the mailbox commands, which discover no
# board at all.

my $ROOT = abs_path('.');

sub run_foundation {
    my ( $cwd, @argv ) = @_;
    my $old = getcwd();
    chdir $cwd or die "chdir $cwd: $!";
    my $errfh = gensym;
    my $pid = open3( my $in, my $outfh, $errfh,
        $^X, "-I$ROOT/lib", "$ROOT/bin/karr-foundation", @argv );
    close $in;
    my $out = do { local $/; <$outfh> };
    my $err = do { local $/; <$errfh> };
    waitpid( $pid, 0 );
    my $exit = $? >> 8;
    chdir $old or die "chdir $old: $!";
    return {
        exit   => $exit,
        stdout => defined $out ? $out : '',
        stderr => defined $err ? $err : '',
    };
}

sub init_repo {
    my $repo = tempdir( CLEANUP => 1 );
    system( 'git', 'init', '-q', $repo ) == 0 or BAIL_OUT('git init failed');
    system( 'git', '-C', $repo, 'config', 'user.email', 'fleet@example.com' ) == 0
        or BAIL_OUT('git config failed');
    system( 'git', '-C', $repo, 'config', 'user.name', 'Fleet' ) == 0
        or BAIL_OUT('git config failed');
    return $repo;
}

# A config file in its own directory, so a test never picks up ~/.karr-foundation.
sub write_config {
    my ( $body ) = @_;
    my $cfg = path( tempdir( CLEANUP => 1 ) )->child('config.yml');
    $cfg->spew_utf8($body);
    return "$cfg";
}

# ------------------------------------------------------------------ exit 0

subtest 'success and help exit 0' => sub {
    my $repo = init_repo();
    my $cfg  = write_config("hub: $repo\ndirs:\n  - $repo\n");

    is( run_foundation( $repo, '--config', $cfg, '--status' )->{exit},
        0, 'the read-only overview exits 0' );

    # Help is not a usage error: MooX::Options reaches options_usage with 0.
    is( run_foundation( $repo, '--help' )->{exit}, 0, '--help exits 0' );
    is( run_foundation( $repo, '-h' )->{exit},     0, '-h exits 0' );

    my $ask = run_foundation( $repo, '--config', $cfg, 'ask', 'Which registry?' );
    is( $ask->{exit}, 0, 'ask exits 0' ) or diag "stderr: $ask->{stderr}";
    my $answer = run_foundation( $repo, '--config', $cfg, 'answer', '1', 'cpan' );
    is( $answer->{exit}, 0, 'answer exits 0' ) or diag "stderr: $answer->{stderr}";
};

# ------------------------------------------------------------------ exit 1

subtest 'a broken config is a runtime failure (1)' => sub {
    my $repo = init_repo();

    # Not a mapping: the config is syntactically fine YAML, karr-foundation
    # just cannot use it.
    my $seq = run_foundation( $repo, '--config', write_config("- a\n- b\n") );
    is( $seq->{exit}, 1, 'a config that is not a mapping exits 1' );
    like( $seq->{stderr}, qr/Config must be a YAML mapping/,
        'and the message reaches STDERR' );
    is( $seq->{stdout}, '', 'nothing on STDOUT' );

    my $broken = run_foundation( $repo, '--config', write_config("foo: [unclosed\n") );
    is( $broken->{exit}, 1, 'an unparseable config exits 1' );
    like( $broken->{stderr}, qr/Cannot parse config/, 'and says so' );
};

subtest 'other runtime failures exit 1' => sub {
    my $repo = init_repo();

    # Nothing to work on: run() returns 1 by value rather than dying, and the
    # handler must not swallow the returned code on its way to exit().
    my $none = run_foundation( $repo, '--config', write_config("dirs: []\n") );
    is( $none->{exit}, 1, 'a config that discovers no repo exits 1' );
    like( $none->{stderr}, qr/no repos found/, 'and says why' );

    # The mailbox needs a hub. A well-formed command that cannot be carried out
    # is a runtime failure, not a usage error.
    my $nohub = run_foundation( $repo, '--config', write_config("dirs:\n  - $repo\n"),
        'ask', 'Q?' );
    is( $nohub->{exit}, 1, 'ask without a hub exits 1' );
    like( $nohub->{stderr}, qr/hub/, 'and names what is missing' );

    # A value MooX::Options accepts as a plain string, then ask's own
    # validation rejects, is a runtime failure -- not the usage error the
    # subtest below pins for a value MooX::Options itself cannot parse
    # (--wait). Ticket #217: the POD used to lump both under "invalid option
    # value" as if either exited 2.
    my $badpolicy = run_foundation( $repo,
        '--config', write_config("hub: $repo\ndirs:\n  - $repo\n"),
        'ask', 'Q?', '--policy', 'nonsense' );
    is( $badpolicy->{exit}, 1, 'an unrecognized --policy value exits 1, not 2' );
    like( $badpolicy->{stderr}, qr/unknown policy/, 'and says why' );
};

subtest 'answering an already answered question exits 1 (#191)' => sub {
    my $repo = init_repo();
    my $cfg  = write_config("hub: $repo\ndirs:\n  - $repo\n");

    is( run_foundation( $repo, '--config', $cfg, 'ask', 'Which registry?',
            '--options', 'cpan,darkpan' )->{exit},
        0, 'setup: the question is asked' );
    is( run_foundation( $repo, '--config', $cfg, 'answer', '1', 'darkpan' )->{exit},
        0, 'setup: and answered once' );

    my $again = run_foundation( $repo, '--config', $cfg, 'answer', '1', 'cpan' );
    is( $again->{exit}, 1,
        'answering a settled question is a runtime refusal (1): the command was '
      . 'typed correctly, the mailbox declines to act' );
    like( $again->{stderr}, qr/already answered/, 'and says why' );
};

# ------------------------------------------------------------------ exit 2

subtest 'usage errors exit 2' => sub {
    my $repo = init_repo();
    my $cfg  = write_config("hub: $repo\ndirs:\n  - $repo\n");

    my $unknown = run_foundation( $repo, '--config', $cfg, 'wibble' );
    is( $unknown->{exit}, 2, 'an unknown mailbox command exits 2' );
    like( $unknown->{stderr}, qr/\QUnknown command:\E/,
        'carrying the marker App::karr::Error::is_usage_error keys on' );
    like( $unknown->{stderr}, qr/wibble/, 'and naming what was typed' );

    # Missing positional.
    my $bare_ask = run_foundation( $repo, '--config', $cfg, 'ask' );
    is( $bare_ask->{exit}, 2, 'ask with no question exits 2' );
    like( $bare_ask->{stderr}, qr/^Usage: karr-foundation ask/m, 'with a Usage: line' );

    my $bare_answer = run_foundation( $repo, '--config', $cfg, 'answer', '1' );
    is( $bare_answer->{exit}, 2, 'answer with no answer exits 2' );
    like( $bare_answer->{stderr}, qr/^Usage: karr-foundation answer/m,
        'with a Usage: line' );

    # Surplus positional.
    is( run_foundation( $repo, '--config', $cfg, 'answer', '1', 'cpan', 'extra' )->{exit},
        2, 'answer with a surplus argument exits 2' );
    is( run_foundation( $repo, '--config', $cfg, 'ask', 'one?', 'two?' )->{exit},
        2, 'ask with two questions exits 2' );
};

subtest 'option-parse errors exit 2, not 1' => sub {
    my $repo = init_repo();

    # These never reach the handler in bin/karr-foundation: MooX::Options exits
    # from inside options_usage, and App::karr::Role::ExitCodes (composed by
    # App::karr::Foundation) is what makes that exit a 2. Without the role they
    # are 1 -- the same code a drain that genuinely failed returns, which is
    # the distinction the contract exists for.
    my $bogus = run_foundation( $repo, '--totally-bogus' );
    is( $bogus->{exit}, 2, 'an unknown option exits 2' );
    like( $bogus->{stderr}, qr/Unknown option/, 'and says which' );

    is( run_foundation( $repo, '--wait', 'soon', 'ask', 'Q?' )->{exit},
        2, 'an option value that does not parse exits 2' );
};

done_testing;
