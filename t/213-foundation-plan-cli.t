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
use Encode qw( encode );

use App::karr::Git;
use App::karr::Encoding qw( yaml_load );
use App::karr::Foundation;
use App::karr::Foundation::ChainStore;

# Ticket #213: karr-foundation gets a command that writes a chain.
#
# Before it, App::karr::Foundation::ChainStore->write_chain was the only way in
# -- Perl API -- so the one writer that is not a person, the coordination
# agent (#210), was handed a `perl -MApp::karr::Foundation::ChainStore -e ...`
# one-liner in its prompt and asked to type it out. That was the single place
# where karr gave an agent Perl instead of a command, and it meant a rename
# inside that class broke a prompt rather than a call: silently, and only on
# the tick where a plan was wanted.
#
# What is pinned here, and why each is a decision rather than an accident:
#
#   1. The chain arrives as a DOCUMENT on stdin (or --input), not as options.
#      A chain is a DAG and a DAG is nested; the writer that matters most
#      already produces structure. YAML, and JSON through the same parser.
#   2. It REPLACES the chain, it does not append. Only steps whose chain id
#      matches the header are ever ready, so an append would be a new chain
#      over the old steps and the new ones -- a merge with rules of its own.
#   3. Validation is the store's, and nothing is written when it fails: a
#      document karr will not take leaves the chain in the hub exactly as it
#      was, and the writer gets a sentence rather than a Perl error.
#   4. The exit-code contract holds (ADR 0002): a bad invocation is 2, a bad
#      document is 1 -- the document is data, not argv.
#   5. The coordination agent's prompt names the command and no longer carries
#      Perl for it to type.
#
# No agent is ever started: the only invocations here write or check a chain,
# and the prompt is built in-process without dispatching it.

my $ROOT = abs_path('.');

sub run_foundation {
    my ( %arg ) = @_;
    my $old = getcwd();
    my $cwd = $arg{cwd} // $ROOT;
    chdir $cwd or die "chdir $cwd: $!";
    my $errfh = gensym;
    my $pid = open3( my $in, my $outfh, $errfh,
        $^X, "-I$ROOT/lib", "$ROOT/bin/karr-foundation", @{ $arg{argv} } );
    if ( defined $arg{stdin} ) {
        binmode $in, ':raw';
        print {$in} encode( 'UTF-8', $arg{stdin} );
    }
    close $in;
    my $out = do { local $/; <$outfh> };
    my $err = do { local $/; <$errfh> };
    waitpid( $pid, 0 );
    my $exit = $? >> 8;
    chdir $old or die "chdir back: $!";
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

# A config in a directory of its own, so agents.state and assignment.yml never
# land next to somebody's real fleet.
sub write_config {
    my ( $body ) = @_;
    my $cfg = path( tempdir( CLEANUP => 1 ) )->child('config.yml');
    $cfg->spew_utf8($body);
    return "$cfg";
}

sub store {
    my ( $repo ) = @_;
    return App::karr::Foundation::ChainStore->new(
        git => App::karr::Git->new( dir => "$repo" ) );
}

sub step_refs {
    my ( $repo ) = @_;
    my @refs = sort( split /\n/,
        `git -C '$repo' for-each-ref --format='%(refname)' 'refs/karr-foundation/chain/'` );
    return \@refs;
}

my $FOUR_STEPS = <<'CHAIN';
steps:
  - id: docs
    kind: shell
    repo: /srv/docs-site
    command: ./build-docs.sh
    precheck: board_actionable == yes
  - id: smoke
    kind: shell
    repo: /srv/webapp
    command: ./smoke-test.sh
  - id: registry
    kind: question
    needs: [ docs, smoke ]
  - id: publish
    kind: shell
    repo: /srv/webapp
    needs: [ registry ]
    command: ./publish.sh
limits:
  concurrent: 2
note: release 0.6
CHAIN

# A hub, a config naming it, and nothing else: writing a chain discovers no
# board and runs nothing.
sub fleet {
    my $hub = init_repo();
    my $cfg = write_config("hub: $hub\ndirs:\n  - $hub\n");
    return ( $hub, $cfg );
}

# ------------------------------------------------------- the document arrives

subtest 'a YAML document on stdin becomes the chain in the hub' => sub {
    my ( $hub, $cfg ) = fleet();

    my $r = run_foundation(
        cwd   => $hub,
        argv  => [ '--config', $cfg, 'plan' ],
        stdin => $FOUR_STEPS,
    );
    is( $r->{exit}, 0, 'plan exits 0' ) or diag "stderr: $r->{stderr}";

    my $header = store($hub)->header;
    like( $r->{stdout}, qr/\QWrote chain $header->{id}\E: 4 step\(s\)/,
        'it names the chain id it wrote and how many steps' );
    like( $r->{stdout}, qr/execute it with: karr-foundation chain/,
        'and the command that runs it' );
    like( $r->{stdout}, qr/^\s+publish\s+shell, in \/srv\/webapp, needs registry$/m,
        'each step is told back: what it is, where, and what it waits for' );

    is_deeply( step_refs($hub), [
        'refs/karr-foundation/chain/meta',
        'refs/karr-foundation/chain/step/docs',
        'refs/karr-foundation/chain/step/publish',
        'refs/karr-foundation/chain/step/registry',
        'refs/karr-foundation/chain/step/smoke',
    ], 'one ref per step plus the header' );

    is_deeply( $header->{limits}, { concurrent => 2 },
        "the header carries the document's limits, untouched" );
    is( $header->{note}, 'release 0.6', 'and its note' );

    my %by_id = map { $_->{id} => $_ } store($hub)->steps;
    is( $by_id{registry}{kind}, 'question', 'a step keeps its kind' );
    is_deeply( $by_id{registry}{needs}, [ 'docs', 'smoke' ], 'and its edges' );
    is( $by_id{docs}{precheck}, 'board_actionable == yes', 'and its precheck' );
    is( $by_id{publish}{command}, './publish.sh', 'and its command' );

    # The point of writing one: what the CLI wrote is what the executor reads.
    # ready_steps only returns steps whose chain id matches the header, so this
    # fails the moment the two halves stop being written together.
    is_deeply( [ sort map { $_->{id} } store($hub)->ready_steps ],
        [ 'docs', 'smoke' ],
        'the chain is executable: the steps with no edge are ready at once' );
};

subtest 'JSON is a chain document, and so is a bare list of steps' => sub {
    my ( $hub, $cfg ) = fleet();

    # JSON needs no flag: it goes through the same parser YAML does.
    my $json = '{"steps":[{"id":"one","kind":"ticket","repo":"/srv/x",'
             . '"ticket":41},{"id":"two","kind":"plan","needs":["one"]}],'
             . '"limits":{"concurrent":3}}';
    my $r = run_foundation(
        cwd => $hub, argv => [ '--config', $cfg, 'plan' ], stdin => $json );
    is( $r->{exit}, 0, 'a JSON document is accepted' ) or diag $r->{stderr};
    is_deeply( [ map { $_->{id} } store($hub)->steps ], [ 'one', 'two' ],
        'and lands as steps' );
    is_deeply( store($hub)->header->{limits}, { concurrent => 3 },
        'with its header' );
    like( $r->{stdout}, qr/one\s+ticket #41, in \/srv\/x/,
        'a ticket step is told back with its card, not with "ticket, ticket"' );

    # A bare list IS the step list -- which is what write_chain's own first
    # argument looks like, so a planner that wrote only steps wrote a document.
    my $r2 = run_foundation(
        cwd  => $hub, argv => [ '--config', $cfg, 'plan' ],
        stdin => "- id: alone\n  kind: plan\n" );
    is( $r2->{exit}, 0, 'a bare list is a document too' ) or diag $r2->{stderr};
    is_deeply( [ map { $_->{id} } store($hub)->steps ], [ 'alone' ],
        'and it is the steps' );
};

subtest '--input reads the document from a file instead of stdin' => sub {
    my ( $hub, $cfg ) = fleet();
    my $file = path( tempdir( CLEANUP => 1 ) )->child('chain.yml');
    $file->spew_utf8($FOUR_STEPS);

    my $r = run_foundation(
        cwd => $hub, argv => [ '--config', $cfg, 'plan', '--input', "$file" ] );
    is( $r->{exit}, 0, '--input exits 0' ) or diag "stderr: $r->{stderr}";
    is( scalar( store($hub)->steps ), 4, 'and writes the same four steps' );

    my $missing = run_foundation( cwd => $hub,
        argv => [ '--config', $cfg, 'plan', '--input', "$file.nope" ] );
    is( $missing->{exit}, 1, 'an unreadable --input is a runtime failure' );
    like( $missing->{stderr}, qr/\QCould not read\E/,
        'named as the caller path it is, with no karr call site' );
    unlike( $missing->{stderr}, qr/App\/karr/,
        'no module path leaks into the message' );
};

# --------------------------------------------------------- replace, not append

subtest 'a second plan replaces the chain, it does not add to it' => sub {
    my ( $hub, $cfg ) = fleet();
    run_foundation( cwd => $hub, argv => [ '--config', $cfg, 'plan' ],
        stdin => $FOUR_STEPS );
    my $first = store($hub)->header->{id};

    my $r = run_foundation( cwd => $hub, argv => [ '--config', $cfg, 'plan' ],
        stdin => "steps:\n  - id: only\n    kind: plan\n" );
    is( $r->{exit}, 0, 'the second plan exits 0' ) or diag $r->{stderr};

    is_deeply( [ map { $_->{id} } store($hub)->steps ], [ 'only' ],
        'the steps of the old chain are gone, not merged with the new one' );
    isnt( store($hub)->header->{id}, $first, 'and the chain id is a new one' );
    is( store($hub)->header->{note}, undef,
        'a header key the new document does not carry is gone with it' );
};

subtest 'a chain with a running step is refused unless --force' => sub {
    my ( $hub, $cfg ) = fleet();
    run_foundation( cwd => $hub, argv => [ '--config', $cfg, 'plan' ],
        stdin => $FOUR_STEPS );
    store($hub)->update_step( 'docs', sub {
        my ( $step ) = @_;
        $step->{state} = 'running';
        return $step;
    } );
    my $before = store($hub)->header->{id};

    my $r = run_foundation( cwd => $hub, argv => [ '--config', $cfg, 'plan' ],
        stdin => "steps:\n  - id: only\n    kind: plan\n" );
    is( $r->{exit}, 1, 'replacing a chain that is still running is refused' );
    like( $r->{stderr}, qr/still has 1 running step\(s\) \(docs\)/,
        'and says which step' );
    is( store($hub)->header->{id}, $before, 'the chain in the hub is untouched' );
    is( scalar( store($hub)->steps ), 4, 'with all its steps' );

    my $forced = run_foundation( cwd => $hub,
        argv  => [ '--config', $cfg, 'plan', '--force' ],
        stdin => "steps:\n  - id: only\n    kind: plan\n" );
    is( $forced->{exit}, 0, '--force replaces it anyway' ) or diag $forced->{stderr};
    is_deeply( [ map { $_->{id} } store($hub)->steps ], [ 'only' ],
        'and the running step is gone with the chain it belonged to' );
};

subtest '--dry-run checks a chain and writes nothing' => sub {
    my ( $hub, $cfg ) = fleet();
    run_foundation( cwd => $hub, argv => [ '--config', $cfg, 'plan' ],
        stdin => "steps:\n  - id: kept\n    kind: plan\n" );
    my $before = store($hub)->header->{id};

    my $ok = run_foundation( cwd => $hub,
        argv => [ '--config', $cfg, 'plan', '--dry-run' ], stdin => $FOUR_STEPS );
    is( $ok->{exit}, 0, 'a valid chain checks out' ) or diag $ok->{stderr};
    like( $ok->{stdout}, qr/The chain is valid: 4 step\(s\), nothing written/,
        'and says so, with the steps it read' );
    like( $ok->{stdout}, qr/registry\s+question, needs docs, smoke/,
        'told back the same way a written one is' );
    is( store($hub)->header->{id}, $before, 'the chain in the hub is untouched' );
    is_deeply( [ map { $_->{id} } store($hub)->steps ], [ 'kept' ],
        'and so are its steps' );

    my $bad = run_foundation( cwd => $hub,
        argv  => [ '--config', $cfg, 'plan', '--dry-run' ],
        stdin => "steps:\n  - id: a\n    kind: wibble\n" );
    is( $bad->{exit}, 1, 'and a chain that is wrong still fails the check' );
    like( $bad->{stderr}, qr/unknown kind 'wibble'/, 'saying what is wrong' );
};

# ------------------------------------------------------------ bad documents

subtest 'a document karr will not take leaves the chain in the hub alone' => sub {
    my ( $hub, $cfg ) = fleet();
    run_foundation( cwd => $hub, argv => [ '--config', $cfg, 'plan' ],
        stdin => $FOUR_STEPS );
    my $before = store($hub)->header->{id};
    my $refs   = step_refs($hub);

    my @refused = (
        [ 'a scalar is not a document', "just a string\n",
          qr/A chain document is a list of steps, or a mapping/ ],
        [ 'a document with nothing in it', "# nothing here\n",
          qr/The chain document is empty/ ],
        [ 'a mapping without steps', "limits:\n  concurrent: 2\n",
          qr/A chain document needs a 'steps:' list/ ],
        [ 'steps that are not a list', "steps: nope\n",
          qr/'steps:' must be a list of steps/ ],
        [ 'an empty steps list', "steps: []\n",
          qr/A chain needs at least one step/ ],
        [ 'a misspelled header key', "steps:\n  - id: a\n    kind: plan\nlimit: 4\n",
          qr/no 'limit' key \(it takes: limits, note, planner, steps\)/ ],
        [ 'force as a document key', "steps:\n  - id: a\n    kind: plan\nforce: true\n",
          qr/--force on the command line, not something the plan grants itself/ ],
        [ 'limits that are not a mapping', "steps:\n  - id: a\n    kind: plan\nlimits: 4\n",
          qr/'limits:' must be a mapping/ ],
        [ 'a note that is a structure', "steps:\n  - id: a\n    kind: plan\nnote:\n  a: b\n",
          qr/'note:' must be a plain value/ ],
        [ 'YAML that does not parse', "steps: [unclosed\n",
          qr/not valid YAML or JSON/ ],
        [ 'an unknown kind', "steps:\n  - id: a\n    kind: wibble\n",
          qr/unknown kind 'wibble'/ ],
        [ 'a step with no id', "steps:\n  - kind: plan\n",
          qr/A chain step needs an id/ ],
        [ 'a ticket step with no ticket', "steps:\n  - id: a\n    kind: ticket\n    repo: /srv/x\n",
          qr/needs a ticket id/ ],
        [ 'a step naming an agent', "steps:\n  - id: a\n    kind: plan\n    agent: minimax\n",
          qr/names an agent: the chain is shared state/ ],
        [ 'a duplicate id', "steps:\n  - id: a\n    kind: plan\n  - id: a\n    kind: plan\n",
          qr/id 'a' is used twice/ ],
        [ 'an edge out of the chain', "steps:\n  - id: a\n    kind: plan\n    needs: [ zz ]\n",
          qr/needs 'zz', which is not in this chain/ ],
        [ 'a cycle', "steps:\n  - id: a\n    kind: plan\n    needs: [ b ]\n"
                   . "  - id: b\n    kind: plan\n    needs: [ a ]\n",
          qr/has a cycle through step\(s\) a, b/ ],
        [ 'a precheck nobody can read', "steps:\n  - id: a\n    kind: plan\n    precheck: wat\n",
          qr/cannot read precheck 'wat' \(expected: <fact> == <value>/ ],
    );

    for my $case ( @refused ) {
        my ( $what, $document, $expect ) = @$case;
        my $r = run_foundation( cwd => $hub,
            argv => [ '--config', $cfg, 'plan' ], stdin => $document );
        is( $r->{exit}, 1, "$what: refused as a runtime failure" );
        like( $r->{stderr}, $expect, "$what: with a sentence about it" );
        unlike( $r->{stderr}, qr/ at \S+ line \d+/,
            "$what: and no Perl call site in it" );
    }

    is( store($hub)->header->{id}, $before,
        'after all of them the chain in the hub is the one that was there' );
    is_deeply( step_refs($hub), $refs, 'with exactly its refs' );
};

subtest 'the exit-code contract holds for plan (ADR 0002)' => sub {
    my ( $hub, $cfg ) = fleet();

    # 2: you called this wrong. The document is data and arrives on stdin, so a
    # positional argument is a surplus one.
    my $surplus = run_foundation( cwd => $hub,
        argv => [ '--config', $cfg, 'plan', 'chain.yml' ], stdin => $FOUR_STEPS );
    is( $surplus->{exit}, 2, 'a surplus positional is a usage error' );
    like( $surplus->{stderr}, qr/\AUsage: karr-foundation plan/,
        'on the marker bin/karr-foundation keys the split on' );

    my $bogus = run_foundation( cwd => $hub,
        argv => [ '--config', $cfg, 'plan', '--totally-bogus' ] );
    is( $bogus->{exit}, 2, 'an unknown option is one too' );

    # 1: the invocation was right, what arrived was not.
    my $empty = run_foundation( cwd => $hub, argv => [ '--config', $cfg, 'plan' ] );
    is( $empty->{exit}, 1, 'an empty stdin is a runtime failure' );
    like( $empty->{stderr}, qr/No chain document received on stdin/,
        'and says the pipe was empty' );

    my $nohub = run_foundation( cwd => $hub,
        argv  => [ '--config', write_config("dirs:\n  - $hub\n") , 'plan' ],
        stdin => $FOUR_STEPS );
    is( $nohub->{exit}, 1, 'a fleet with no hub cannot be planned for' );
    like( $nohub->{stderr}, qr/No usable hub repository/,
        'and is told where a hub is named' );

    is( scalar( store($hub)->steps ), 0, 'none of that wrote a chain' );
};

subtest 'the document crosses the octet boundary exactly once' => sub {
    my ( $hub, $cfg ) = fleet();
    my $note = "Gr\x{f6}\x{df}e \x{2014} \x{4e2d}\x{6587}";

    my $r = run_foundation( cwd => $hub, argv => [ '--config', $cfg, 'plan' ],
        stdin => "steps:\n  - id: a\n    kind: shell\n    repo: /srv/x\n"
               . "    command: echo \x{2764}\n"
               . "note: $note\n" );
    is( $r->{exit}, 0, 'a document with non-ASCII in it is accepted' )
        or diag "stderr: $r->{stderr}";

    is( store($hub)->header->{note}, $note,
        'and the note comes back as the characters that went in' );
    my ( $step ) = store($hub)->steps;
    is( $step->{command}, "echo \x{2764}", 'so does a step field' );
};

# ------------------------------------------------- what the planner is told

subtest 'the coordination agent is given the command, not Perl to type' => sub {
    my ( $hub, $cfg ) = fleet();
    path($cfg)->spew_utf8( <<"CONFIG" );
hub: $hub
dirs:
  - $hub
agents:
  planner:
    command: /bin/true
    role: coordinator
CONFIG

    my $foundation = App::karr::Foundation->new( config => $cfg );
    my $coordinator = $foundation->_coordinator;
    ok( $coordinator->configured, 'the fleet marks a coordination agent' );
    $coordinator->want( step => 4, reason => 'kind: plan is not executed here' );
    my $prompt = $coordinator->prompt( $coordinator->wanted );

    unlike( $prompt, qr/perl -M/,
        'the prompt no longer carries a perl one-liner (#213)' );
    unlike( $prompt, qr/write_chain/,
        'nor the name of the storage method it called' );
    like( $prompt, qr/karr-foundation --config '\Q$cfg\E' plan <</,
        'it is told the command, with the config the fleet was started with' );
    like( $prompt, qr/karr-foundation --config '\Q$cfg\E' ask /,
        'and the mailbox command carries it for the same reason' );
    like( $prompt, qr/REPLACES the chain/,
        'and that writing one replaces what is there' );

    # The prompt is worth nothing if the shape in it is not one karr takes, so
    # the document the agent is shown is run through the parser it will meet.
    my ( $document ) = $prompt =~ /plan <<'CHAIN'\n(.*?)\n\s*CHAIN\n/s;
    ok( $document, 'the prompt shows a whole document' );
    $document =~ s/^ {5}//mg;
    my ( $steps, %header ) = store($hub)->parse_chain_document(
        yaml_load($document) );
    is( scalar @$steps, 2, 'which parses as a chain document' );
    my $validated = store($hub)->validate_chain($steps);
    is_deeply( [ map { $_->{id} } @$validated ], [ '1', '2' ],
        'and validates as a chain' );
};

done_testing();
