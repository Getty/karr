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

use App::karr::Git;
use App::karr::Foundation::Questions;

# Ticket #191, work package 7 of the fleet-execution epic (#194): a question is
# a file with an answer field, not a dialogue. That is what removes the special
# case for "a human happens to be present" -- the chain writes the question and
# walks on, and whoever answers (a person at a terminal, a chat bridge, the
# coordination agent) writes into the same mailbox without knowing anything
# about the chain.
#
# What is pinned here, and why each is a decision rather than an accident:
#
#   1. The question and the answer are TWO refs. #190's sync resolves a ref
#      both sides changed by taking the remote's version and not keeping the
#      local one, so an answer stored as a field inside the question would be
#      the thing that gets thrown away. Two refs means the asker and the
#      answerer never write the same ref at all.
#   2. Because the ids are small integers minted per clone, an answer names the
#      question text it answers. Two clones that mint the same id between syncs
#      would otherwise pair an answer with somebody else's question, silently.
#   3. A question is written once: create-only, never rewritten. A mint that
#      loses the race bumps to the next id instead of clobbering the winner --
#      the runner is concurrent (#186), so this is an ordinary case.
#   4. An answer is create-only too: two people answering at once is one
#      answer and one refusal, never a coin toss.
#   5. The policy for "nobody answers" is validated where it is written:
#      use_default without a default, or a deadline-less policy that would fire
#      the moment the question is asked, are planner mistakes and are refused.
#   6. Retention: answered questions age out, open ones never do. An open
#      question is work nobody has done yet, whatever its age.
#   7. `karr set-refs` may not hand-write the mailbox; `karr get-refs` may still
#      read it. Answering by hand is `karr-foundation answer`, which is a door
#      built for it -- set-refs joins its arguments with a single space and
#      could only ever produce a payload the mailbox skips.
#
# Everything runs in throwaway repositories; no agent is ever started.

my $ROOT = abs_path('.');

sub init_repo {
    my $repo = tempdir( CLEANUP => 1 );
    system( 'git', 'init', '-q', $repo ) == 0 or BAIL_OUT('git init failed');
    system( 'git', '-C', $repo, 'config', 'user.email', 'fleet@example.com' ) == 0
        or BAIL_OUT('git config failed');
    system( 'git', '-C', $repo, 'config', 'user.name', 'Fleet' ) == 0
        or BAIL_OUT('git config failed');
    return $repo;
}

sub mk_mailbox {
    my ( $repo, %arg ) = @_;
    return App::karr::Foundation::Questions->new(
        git => App::karr::Git->new( dir => "$repo" ), %arg );
}

sub refs_under {
    my ( $repo, $prefix ) = @_;
    my @refs = sort( split /\n/,
        `git -C '$repo' for-each-ref --format='%(refname)' '$prefix'` );
    return @refs;
}

sub oid_of {
    my ( $repo, $ref ) = @_;
    my $out = `git -C '$repo' rev-parse '$ref' 2>/dev/null`;
    chomp $out;
    return $out;
}

sub err_of {
    my ( $code ) = @_;
    my $err = '';
    eval { $code->(); 1 } or $err = $@;
    return $err;
}

sub run_bin {
    my ( $bin, $cwd, @argv ) = @_;
    my $old = getcwd();
    chdir $cwd or die "chdir $cwd: $!";
    my $errfh = gensym;
    my $pid = open3( my $in, my $outfh, $errfh,
        $^X, "-I$ROOT/lib", "$ROOT/bin/$bin", @argv );
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

# A stamp the store will read as already past / still ahead.
sub stamp {
    my ( $offset ) = @_;
    my @t = gmtime( time + $offset );
    return sprintf '%04d-%02d-%02dT%02d:%02d:%02dZ',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0];
}

# ---------------------------------------------------------------------------

subtest 'the question and the answer are two refs, and the question is never rewritten' => sub {
    my $repo = init_repo();
    my $box  = mk_mailbox($repo);

    my $id = $box->ask(
        question => 'Which registry do we publish to?',
        context  => 'The release gate is waiting on this.',
        options  => [ 'cpan', 'darkpan' ],
        default  => 'cpan',
        policy   => 'use_default',
        deadline => stamp(3600),
        step     => 12,
    );
    is( $id, 1, 'the first question is #1' );

    is_deeply(
        [ refs_under( $repo, 'refs/karr-foundation/' ) ],
        ['refs/karr-foundation/questions/1/ask'],
        'asking writes one ref and nothing else'
    );

    my $q = $box->question(1);
    is( $q->{question}, 'Which registry do we publish to?', 'the question survives' );
    is( $q->{context},  'The release gate is waiting on this.', 'the context survives' );
    is_deeply( $q->{options}, [ 'cpan', 'darkpan' ], 'the options survive' );
    is( $q->{default}, 'cpan',        'the default survives' );
    is( $q->{policy},  'use_default', 'the policy survives' );
    is( $q->{step},    12,            'the step the chain is waiting on survives' );
    like( $q->{asked}, qr/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z\z/, 'and when' );

    my $before = oid_of( $repo, 'refs/karr-foundation/questions/1/ask' );
    $box->settle( 1, 'darkpan', note => 'the release is a private one' );

    is_deeply(
        [ refs_under( $repo, 'refs/karr-foundation/' ) ],
        [   'refs/karr-foundation/questions/1/answer',
            'refs/karr-foundation/questions/1/ask',
        ],
        'the answer is its own ref beside the question'
    );
    is( oid_of( $repo, 'refs/karr-foundation/questions/1/ask' ), $before,
        'answering does not rewrite the question ref -- which is the whole '
      . 'reason the answer is not a field in it (#190)' );

    my $a = $box->answer(1);
    is( $a->{answer}, 'darkpan', 'the answer is there' );
    is( $a->{note}, 'the release is a private one', 'with its note' );
    is( $a->{question}, 'Which registry do we publish to?',
        'and it names the question it answers' );
};

subtest 'an answer that names another question does not settle this one' => sub {
    my $repo = init_repo();
    my $box  = mk_mailbox($repo);

    my $id = $box->ask( question => 'Ship it?' );
    $box->settle( $id, 'yes' );
    is( $box->resolve($id)->{state}, 'answered', 'the matching answer counts' );

    # What two clones minting the same id between syncs leaves behind: an
    # answer ref that survived and an ask ref that is now somebody else's
    # question. Simulated by writing the ask ref to a different question.
    App::karr::Git->new( dir => "$repo" )->write_ref(
        'refs/karr-foundation/questions/1/ask',
        "id: 1\nquestion: Delete the backups?\nasked: " . stamp(-60) . "\npolicy: block\n" );

    my $warned = '';
    my $r = do {
        local $SIG{__WARN__} = sub { $warned .= $_[0] };
        $box->resolve($id);
    };
    is( $r->{state}, 'open',
        'an answer to a different question does not settle this one' );
    like( $warned, qr/different question/, 'and it says so out loud' );

    # ... and re-answering it needs no force: there is nothing to protect.
    $box->settle( $id, 'no' );
    is( $box->resolve($id)->{state}, 'answered', 'the new answer settles it' );
    is( $box->answer($id)->{answer}, 'no',       'with the new value' );
};

subtest 'a mint that loses the race bumps instead of clobbering the winner' => sub {
    my $repo = init_repo();
    my $box  = mk_mailbox($repo);
    my $git  = App::karr::Git->new( dir => "$repo" );

    # Another writer takes the id between this one's read and its write. No
    # fork needed to pin the decision: what matters is that the create-only
    # write refuses and the caller moves on to the next id.
    my $raced = 0;
    no warnings 'redefine';
    my $orig = \&App::karr::Git::write_ref_cas;
    local *App::karr::Git::write_ref_cas = sub {
        my ( $self, $ref, $content, $old ) = @_;
        if ( !$raced++ && $ref eq 'refs/karr-foundation/questions/1/ask' ) {
            $git->write_ref( $ref,
                "id: 1\nquestion: Somebody else got here first\n"
              . "asked: " . stamp(-5) . "\npolicy: block\n" );
        }
        return $orig->( $self, $ref, $content, $old );
    };

    my $id = $box->ask( question => 'Mine' );
    is( $id, 2, 'the loser takes the next id' );
    is( $box->question(1)->{question}, 'Somebody else got here first',
        'and the winner is untouched' );
    is( $box->question(2)->{question}, 'Mine', 'while the loser is stored whole' );
};

subtest 'two answers at once is one answer and one refusal' => sub {
    my $repo = init_repo();
    my $box  = mk_mailbox($repo);
    my $id   = $box->ask( question => 'Ship it?' );

    $box->settle( $id, 'yes' );
    my $err = err_of( sub { $box->settle( $id, 'no' ) } );
    like( $err, qr/already answered/, 'the second answer is refused' );
    unlike( $err, qr/ at \S+ line \d+/, 'without a source location' );
    is( $box->answer($id)->{answer}, 'yes', 'and the first one stands' );

    $box->settle( $id, 'no', force => 1 );
    is( $box->answer($id)->{answer}, 'no', 'force is the way to change it' );
};

subtest 'the policy for nobody-answers is checked where it is written' => sub {
    my $repo = init_repo();
    my $box  = mk_mailbox($repo);

    like(
        err_of( sub { $box->ask( question => 'x', policy => 'shrug' ) } ),
        qr/unknown policy 'shrug'/,
        'an unknown policy is refused'
    );
    like(
        err_of( sub {
            $box->ask( question => 'x', policy => 'use_default',
                deadline => stamp(60) );
        } ),
        qr/needs a default/,
        'use_default without a default is a planner mistake, not a surprise later'
    );
    like(
        err_of( sub {
            $box->ask( question => 'x', policy => 'use_default', default => 'a' );
        } ),
        qr/needs a deadline/,
        'a policy that would fire before anybody could answer is refused'
    );
    like(
        err_of( sub {
            $box->ask( question => 'x', options => [ 'a', 'b' ], default => 'c' );
        } ),
        qr/is not one of its options/,
        'a default outside the options is refused'
    );
    like(
        err_of( sub { $box->ask( question => '   ' ) } ),
        qr/needs a question/,
        'and an empty question is not a question'
    );

    is_deeply( [ refs_under( $repo, 'refs/karr-foundation/' ) ], [],
        'none of the refusals wrote a ref' );

    my $id = $box->ask( question => 'no policy given' );
    is( $box->question($id)->{policy}, 'block',
        'the default policy is to wait: nothing runs on a guess' );
};

subtest 'an answer is checked against the options it was offered' => sub {
    my $repo = init_repo();
    my $box  = mk_mailbox($repo);
    my $id = $box->ask( question => 'Which?', options => [ 'a', 'b' ] );

    my $err = err_of( sub { $box->settle( $id, 'c' ) } );
    like( $err, qr/\ba\b.*\bb\b/, 'a value outside the options is refused, with the list' );
    ok( !$box->answer($id), 'and nothing was written' );

    like( err_of( sub { $box->settle( $id, '' ) } ), qr/empty/,
        'an empty answer is not an answer' );
    like( err_of( sub { $box->settle( 99, 'a' ) } ), qr/No question #99/,
        'answering a question nobody asked says so' );

    $box->settle( $id, 'c', force => 1 );
    is( $box->answer($id)->{answer}, 'c',
        'force is there for the answer the options did not anticipate' );
};

subtest 'resolve: open, answered, overdue, and what the policy says then' => sub {
    my $repo = init_repo();
    my $box  = mk_mailbox($repo);

    my $waiting = $box->ask( question => 'no deadline' );
    is( $box->resolve($waiting)->{state}, 'open', 'no deadline means simply open' );

    my $late = $box->ask( question => 'block', deadline => stamp(-60) );
    my $r = $box->resolve($late);
    is( $r->{state},  'overdue', 'a passed deadline is overdue' );
    is( $r->{policy}, 'block',   'and with policy block it stays waiting' );
    ok( !exists $r->{answer}, 'block never invents an answer' );

    my $fallback = $box->ask(
        question => 'default', policy => 'use_default',
        default  => 'cpan',    deadline => stamp(-60) );
    my $f = $box->resolve($fallback);
    is( $f->{state},  'overdue',     'the same state' );
    is( $f->{policy}, 'use_default', 'a different policy' );
    is( $f->{answer}, 'cpan',        'and the default is what it resolves to' );

    my $escalate = $box->ask(
        question => 'ai', policy => 'escalate_to_ai', deadline => stamp(-60) );
    my $e = $box->resolve($escalate);
    is( $e->{policy}, 'escalate_to_ai', 'escalation is a policy like the others' );
    ok( !exists $e->{answer}, 'and it has no answer of its own to give' );

    $box->settle( $fallback, 'darkpan' );
    my $answered = $box->resolve($fallback);
    is( $answered->{state},  'answered', 'an answer beats the deadline' );
    is( $answered->{answer}, 'darkpan',  'and beats the default' );

    is_deeply(
        [ map { $_->{id} } $box->open_questions ],
        [ $waiting, $late, $escalate ],
        'the open mailbox is everything nobody has answered, oldest first'
    );
    is( $box->resolve(404), undef, 'a question that does not exist resolves to nothing' );
};

subtest 'retention: answered questions age out, open ones never do' => sub {
    my $repo = init_repo();
    my $box  = mk_mailbox( $repo, keep_answered_days => 30 );

    my $old_open = $box->ask( question => 'nobody has answered this in a year' );
    my $old_done = $box->ask( question => 'settled long ago' );
    my $fresh    = $box->ask( question => 'settled just now' );
    $box->settle( $old_done, 'yes' );
    $box->settle( $fresh,    'yes' );

    # Age the settled answer by rewriting its stamp -- the alternative is a
    # test that takes a month.
    my $git = App::karr::Git->new( dir => "$repo" );
    my $ref = "refs/karr-foundation/questions/$old_done/answer";
    my $aged = $git->read_ref($ref);
    $aged =~ s/answered: \S+/answered: 2020-01-01T00:00:00Z/;
    $git->write_ref( $ref, $aged );

    my @gone = $box->prune_questions;
    is_deeply( \@gone, [$old_done], 'an answered question that aged out is dropped' );
    ok( $box->question($old_open), 'an open question is kept whatever its age' );
    ok( $box->question($fresh),    'and a recent answer is kept too' );
    is_deeply(
        [ refs_under( $repo, "refs/karr-foundation/questions/$old_done/" ) ], [],
        'both of the dropped question refs are gone'
    );

    # The same board, read by a mailbox that keeps answers forever: the one
    # remaining answer is aged the same way and still survives.
    my $fresh_ref = "refs/karr-foundation/questions/$fresh/answer";
    my $fresh_aged = $git->read_ref($fresh_ref);
    $fresh_aged =~ s/answered: \S+/answered: 2020-01-01T00:00:00Z/;
    $git->write_ref( $fresh_ref, $fresh_aged );

    my $off = mk_mailbox( $repo, keep_answered_days => 0 );
    is_deeply( [ $off->prune_questions ], [],
        'keep_answered_days 0 keeps everything, the same spelling max_runtime uses' );
    ok( $off->question($fresh), 'including an answer older than any policy' );
};

subtest 'asking prunes, so a mailbox nobody empties still has a bound' => sub {
    my $repo = init_repo();
    my $box  = mk_mailbox( $repo, keep_answered_days => 30 );
    my $id   = $box->ask( question => 'settled long ago' );
    $box->settle( $id, 'yes' );

    my $git  = App::karr::Git->new( dir => "$repo" );
    my $ref  = "refs/karr-foundation/questions/$id/answer";
    my $aged = $git->read_ref($ref);
    $aged =~ s/answered: \S+/answered: 2020-01-01T00:00:00Z/;
    $git->write_ref( $ref, $aged );

    my $next = $box->ask( question => 'a new one' );
    is( $box->question($next)->{question}, 'a new one',
        'the new question is there' );
    ok( !$box->answer($next),
        'and the pruned answer did not come with the id -- an id that comes '
      . 'round again is not a settled question' );
    is( $next, $id,
        'an id IS reused once the question that had it aged out: the ids are '
      . 'minted from what the mailbox holds, and the guard against an answer '
      . 'meeting the wrong question is the question text it names, not a '
      . 'counter that would have to survive a sync' );
};

subtest 'the CLI: ask raises one, answer settles it' => sub {
    my $repo = init_repo();
    my $cfg  = path( tempdir( CLEANUP => 1 ) )->child('config.yml');
    $cfg->spew_utf8( "hub: $repo\ndirs:\n  - $repo\n" );

    my $r = run_bin( 'karr-foundation', $repo, '--config', "$cfg",
        'ask', 'Which registry do we publish to?',
        '--options', 'cpan,darkpan', '--default', 'cpan',
        '--policy', 'use_default', '--wait', '3600',
        '--context', 'the release gate is waiting' );
    is( $r->{exit}, 0, 'ask succeeds' ) or diag "stderr: $r->{stderr}";
    like( $r->{stdout}, qr/#1/, 'and prints the id somebody has to answer' );

    my $box = mk_mailbox($repo);
    my $q   = $box->question(1);
    is( $q->{question}, 'Which registry do we publish to?', 'the text arrived' );
    is_deeply( $q->{options}, [ 'cpan', 'darkpan' ], 'the options were split on commas' );
    is( $q->{policy}, 'use_default', 'the policy arrived' );
    ok( $q->{deadline}, '--wait became a deadline everybody reads the same way' );
    is( $q->{context}, 'the release gate is waiting', 'and the context' );

    my $s = run_bin( 'karr-foundation', $repo, '--config', "$cfg",
        'answer', '1', 'darkpan', '--note', 'private release' );
    is( $s->{exit}, 0, 'answer succeeds' ) or diag "stderr: $s->{stderr}";
    is( $box->resolve(1)->{state},  'answered', 'the question is settled' );
    is( $box->resolve(1)->{answer}, 'darkpan',  'with what was typed' );

    my $again = run_bin( 'karr-foundation', $repo, '--config', "$cfg",
        'answer', '1', 'cpan' );
    isnt( $again->{exit}, 0, 'answering twice fails' );
    like( $again->{stderr}, qr/already answered/, 'and says why' );
    unlike( $again->{stderr}, qr/ at \S+ line \d+/, 'without a source location' );

    my $bad = run_bin( 'karr-foundation', $repo, '--config', "$cfg", 'wibble' );
    isnt( $bad->{exit}, 0, 'an unknown command fails' );
    like( $bad->{stderr}, qr/wibble/, 'naming what was typed' );

    my $usage = run_bin( 'karr-foundation', $repo, '--config', "$cfg", 'ask' );
    isnt( $usage->{exit}, 0, 'ask with no question fails' );
    like( $usage->{stderr}, qr/Usage: karr-foundation ask/, 'with a usage line' );
};

subtest 'the mailbox needs a hub, and the daemon still runs without one' => sub {
    my $repo = init_repo();
    my $cfg  = path( tempdir( CLEANUP => 1 ) )->child('config.yml');
    $cfg->spew_utf8( "dirs:\n  - $repo\n" );

    my $r = run_bin( 'karr-foundation', $repo, '--config', "$cfg", 'ask', 'Q?' );
    isnt( $r->{exit}, 0, 'asking without a hub fails' );
    like( $r->{stderr}, qr/hub/, 'and says what is missing' );

    my $s = run_bin( 'karr-foundation', $repo, '--config', "$cfg", '--status' );
    is( $s->{exit}, 0, 'while the overview does not need one at all' );
};

subtest 'the overview shows the open mailbox' => sub {
    my $repo = init_repo();
    my $cfg  = path( tempdir( CLEANUP => 1 ) )->child('config.yml');
    $cfg->spew_utf8( "hub: $repo\ndirs:\n  - $repo\n" );

    my $box = mk_mailbox($repo);
    my $open = $box->ask( question => 'Which registry?', options => [ 'cpan', 'darkpan' ] );
    my $late = $box->ask( question => 'Deploy tonight?', policy => 'use_default',
        default => 'no', deadline => stamp(-60) );
    my $done = $box->ask( question => 'Ship it?' );
    $box->settle( $done, 'yes' );

    my $r = run_bin( 'karr-foundation', $repo, '--config', "$cfg", '--status' );
    is( $r->{exit}, 0, 'the overview runs' ) or diag "stderr: $r->{stderr}";
    like( $r->{stdout}, qr/Which registry\?/,
        'an open question is on the dashboard -- a question nobody sees is a '
      . 'chain nobody unblocks' );
    unlike( $r->{stdout}, qr/Ship it\?/, 'a settled one is not' );
    like( $r->{stdout}, qr/#$open/, 'with the id to answer it by' );
    like( $r->{stdout}, qr/options: cpan, darkpan/, 'and what it offers' );
    like( $r->{stdout}, qr/overdue: use_default \(no\)/,
        'an overdue question says what it will resolve to if nobody gets there '
      . 'first -- which is the difference between one somebody must answer and '
      . 'one that answers itself' );
};

subtest 'set-refs cannot hand-write the mailbox, get-refs can still read it' => sub {
    my $repo = init_repo();
    my $box  = mk_mailbox($repo);
    my $id   = $box->ask( question => 'Which registry?' );
    my $git  = $box->git;

    for my $ref ( "refs/karr-foundation/questions/$id/ask",
        "refs/karr-foundation/questions/$id/answer" )
    {
        my $err = err_of( sub { $git->validate_helper_ref( $ref, for_write => 1 ) } );
        like( $err, qr/karr-foundation/, "$ref cannot be written by hand" );
        ok( eval { $git->validate_helper_ref($ref); 1 }, "$ref can still be read" )
            or diag $@;
    }

    my $r = run_bin( 'karr', $repo, 'set-refs',
        "refs/karr-foundation/questions/$id/answer", 'yes' );
    isnt( $r->{exit}, 0, 'the CLI refuses it' );
    like( $r->{stderr}, qr/cannot be set by hand/, 'and says so' );
    ok( !$box->answer($id), 'nothing was written' );

    my $g = run_bin( 'karr', $repo, 'get-refs',
        "refs/karr-foundation/questions/$id/ask" );
    is( $g->{exit}, 0, 'reading one is fine' );
    like( $g->{stdout}, qr/Which registry\?/, 'and shows the question' );
};

done_testing;
