use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use TestKarr qw( run_karr );
use File::Temp qw( tempdir );
use Cwd qw( abs_path );
use Path::Tiny qw( path );

# Ticket #176: `karr agentname` mints a new name on every call and remembers it
# nowhere, and the shipped docs demonstrated the idiom as
#
#     karr pick --claim "$(karr agentname)" --move in-progress
#
# which is correct for that one call and wrong for everything an agent does
# afterwards. Copied by analogy to the end of the work --
# `karr handoff ID --claim "$(karr agentname)"` -- it claims under one name and
# hands off under another. That is what bit a worker on this repo's own board.
#
# The decision recorded on #176 was to keep the generator random and stateless
# (a name derived from anything stable enough to survive across separate karr
# processes -- board, git identity, host -- would be shared by every concurrent
# agent on that board, turning a refused mismatch into an unrefusable
# collision) and to make the documentation carry the warning and show only the
# capture-once idiom. So this test pins three things:
#
#   1. the property that makes the idiom dangerous (the name really is fresh
#      every call), because a future "let's cache it" change must not land
#      quietly;
#   2. what the mismatch actually does -- refused while the claim is live, with
#      the held name in the error, and silent on the read paths -- since that
#      is exactly what the new POD promises a confused agent;
#   3. that no shipped doc or POD demonstrates the breaking shape again.

my $ROOT = abs_path('.');

# In-process runner (t/lib/TestKarr.pm): same ($cwd, @argv) signature and
# { exit, stdout, stderr } return as the open3 helper this file used to carry,
# dispatched through the shared App::karr::Dispatch path. KARR_TEST_SUBPROC=1
# restores the old open3 path.
sub _run_karr { return run_karr(@_) }

# Always a throwaway repo; never the developer's real board.
sub _setup_repo {
    my $repo = tempdir( CLEANUP => 1 );
    system( 'git', 'init', '-q', $repo ) == 0 or die 'git init failed';
    system( 'git', '-C', $repo, 'config', 'user.email', 'test@example.com' ) == 0
      or die 'git config failed';
    system( 'git', '-C', $repo, 'config', 'user.name', 'Test User' ) == 0
      or die 'git config failed';

    my $init = _run_karr( $repo, 'init', '--name', 'Ticket176 Board' );
    is( $init->{exit}, 0, 'karr init succeeds' ) or diag $init->{stderr};

    return $repo;
}

sub _name {
    my ($repo) = @_;
    my $rv = _run_karr( $repo, 'agentname' );
    is( $rv->{exit}, 0, 'karr agentname exits 0' ) or diag $rv->{stderr};
    my $name = $rv->{stdout};
    chomp $name;
    return $name;
}

subtest 'agentname is ephemeral: repeated calls do not agree' => sub {
    my $repo = _setup_repo();

    # Six draws from a word list of hundreds. Asserting "call 1 ne call 2"
    # would be a flaky test (two draws can legitimately collide); asserting
    # that six draws are not *all* the same value cannot fail by chance in any
    # practical sense, and still fails immediately the day someone makes the
    # name stable per repo or per board -- which is the change #176 decided
    # against and which this pins.
    my %seen;
    $seen{ _name($repo) }++ for 1 .. 6;

    cmp_ok( scalar keys %seen, '>', 1,
        'six karr agentname calls do not all return the same name' )
      or diag "every call returned: " . join( ', ', keys %seen );
};

subtest 'a freshly minted name does not carry the claim' => sub {
    my $repo = _setup_repo();

    my $create = _run_karr( $repo, 'create', 'Claim continuity' );
    is( $create->{exit}, 0, 'task created' ) or diag $create->{stderr};

    my $claimed  = _name($repo);
    my $unrelated;
    # Guard against the (astronomically unlikely) draw that repeats the claim
    # name, which would make the mismatch assertions below vacuous.
    do { $unrelated = _name($repo) } while $unrelated eq $claimed;

    my $move = _run_karr( $repo, 'move', '1', 'in-progress', '--claim', $claimed );
    is( $move->{exit}, 0, 'move claims the task' ) or diag $move->{stderr};

    # The write path is loud: check_claim refuses, and names the holder, which
    # is the recovery route App::karr::Cmd::AgentName's POD points a confused
    # agent at.
    my $handoff = _run_karr( $repo, 'handoff', '1', '--claim', $unrelated, '--note', 'x' );
    isnt( $handoff->{exit}, 0, 'handoff under a freshly minted name is refused' );
    like( $handoff->{stderr}, qr/\Qis claimed by $claimed\E/,
        'the refusal names the claim actually held, so the name is recoverable' );

    my $show = _run_karr( $repo, 'show', '1' );
    like( $show->{stdout}, qr/^Claimed:\s+\Q$claimed\E$/m,
        'karr show reads the held claim name back off the card' );

    # The read paths are silent: no error, no output, exit 0. This is why the
    # mismatch is easy to miss -- an agent that asks "what do I hold?" under a
    # fresh name is told "nothing" rather than "wrong name".
    my $list = _run_karr( $repo, 'list', '--claimed-by', $unrelated, '--compact' );
    is( $list->{exit}, 0, 'list --claimed-by with a fresh name exits 0' );
    unlike( $list->{stdout}, qr/Claim continuity/,
        'list --claimed-by silently reports nothing for the fresh name' );

    my $log = _run_karr( $repo, 'log', '--agent', $unrelated );
    is( $log->{exit}, 0, 'log --agent with a fresh name exits 0' );
    unlike( $log->{stdout}, qr/\bmove\b/,
        'log --agent silently reports nothing for the fresh name' );

    # ... while the name that was actually used finds both.
    my $list_ok = _run_karr( $repo, 'list', '--claimed-by', $claimed, '--compact' );
    like( $list_ok->{stdout}, qr/Claim continuity/,
        'the captured name still finds the task' );
};

subtest 'no shipped doc demonstrates --claim "$(karr agentname)"' => sub {
    my $root = path($ROOT);

    # Every place a user or agent copies a command line from. Some of these are
    # absent outside a full source checkout (.claude/ is repo-only, docs/ and
    # share/ may be pruned), so missing roots are skipped rather than failed --
    # the same shape t/62 and t/136 use.
    my @roots = grep { $_->exists } map { $root->child(@$_) } (
        [qw( lib )],
        [qw( bin karr )],
        [qw( share claude-skill.md )],
        [qw( README.md )],
        [qw( CONTEXT.md )],
        [qw( docs )],
        [qw( .claude )],
    );

    my @files;
    for my $r (@roots) {
        if ( $r->is_dir ) {
            $r->visit(
                sub {
                    my ($p) = @_;
                    push @files, $p if -f $p && $p =~ /\.(?:pm|md|pod|t)\z/;
                },
                { recurse => 1 }
            );
        }
        else { push @files, $r }
    }

    cmp_ok( scalar @files, '>', 0, 'found documentation files to scan' );

    my @bad;
    for my $file (@files) {
        my @lines = split /\n/, $file->slurp_utf8, -1;
        my $n     = 0;
        for my $line (@lines) {
            $n++;
            # Only copy-pasteable command lines: a line that *starts* with the
            # command. Prose that quotes the broken shape in order to warn
            # about it (as the skill doc now does) is not a demonstration of
            # it, and neither is a line explicitly marked as a counter-example.
            next unless $line =~ /\A\s*karr\s/;
            next unless $line =~ /--claim(?:ed-by)?\b/;
            next unless $line =~ /\$\(\s*karr\s+agent-?name\s*\)/;
            next if $line =~ /DON'T/;
            push @bad, $file->relative($root) . " line $n: $line";
        }
    }

    is( scalar @bad, 0,
        'no doc line claims with an inline $(karr agentname) substitution' )
      or diag( "these lines teach the shape that loses the claim -- capture the\n"
          . "name once into a shell variable and pass that instead (ticket #176):\n  "
          . join( "\n  ", @bad ) );

    # And the capture-once idiom is actually shown, so the warning cannot be
    # satisfied by deleting the examples altogether.
    # Single-quoted, not interpolated: '$(' and '$NAME' are a Perl variable and
    # a Perl variable, and a qr// literal here would silently match nothing.
    my $capture_pod   = 'NAME=$(karr agentname)';
    my $reuse_pod     = '--claim "$NAME"';
    my $capture_skill = 'NAME=$(karr agent-name)';

    my $pod = $root->child(qw( lib App karr Cmd AgentName.pm ))->slurp_utf8;
    like( $pod, qr/\Q$capture_pod\E/,
        'AgentName POD shows capturing the name into a variable' );
    like( $pod, qr/\Q$reuse_pod\E/,
        'AgentName POD shows reusing that variable for --claim' );

    my $skill_file = $root->child(qw( share claude-skill.md ));
  SKIP: {
        skip 'share/claude-skill.md not present in this tree', 2
          unless $skill_file->exists;
        my $skill = $skill_file->slurp_utf8;
        like( $skill, qr/\Q$capture_skill\E/,
            'skill doc shows capturing the name into a variable' );
        like( $skill, qr/mints a \*\*new\*\* name/,
            'skill doc warns that every call mints a new name' );
    }
};

done_testing;
