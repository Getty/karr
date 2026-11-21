#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
BEGIN { plan skip_all => 'karr-foundation cannot run agents on MSWin32' if $^O eq 'MSWin32' }
use lib 't/lib';
use Cwd ();
use lib Cwd::abs_path('lib');
use TestGit qw( require_git_c );
require_git_c();
use TestDenied qw( closed_port_url );
use File::Temp qw( tempdir );
use Path::Tiny qw( path );
use IPC::Open3 qw( open3 );
use Symbol qw( gensym );

use App::karr::Git;
use App::karr::Foundation::ChainStore;

# Ticket k338: a push of refs/karr-foundation/* that fails WITHOUT dying (an
# unreachable remote) used to be silent in `karr-foundation ask`, `answer`,
# `plan` and in the chain executor's push, although the code promises a
# warning. The write is local either way -- which is why the commands must say
# so: what is saved in this clone and not on the remote, and to run
# `karr sync`. Same text the board commands print, on STDERR.
#
# The exit code of each path is pinned as it is today (ADR 0002 is not
# touched by this ticket): 0 for the mailbox commands, plan and chain.
#
# Each subtest first proves the write really happened in the hub clone and
# not on the remote, so "reported" cannot pass on a command that wrote nothing.
# The denied case is k333's and lives in t/334-foundation-read-only.t.

my $ROOT = Cwd::abs_path('.');

# No HOME config of the developer, no credential prompt.
my $home = tempdir( CLEANUP => 1 );
$ENV{HOME}                = $home;
$ENV{GIT_TERMINAL_PROMPT} = 0;

sub sh { system( 'git', @_ ) == 0 or BAIL_OUT("git @_ failed") }

# A hub clone whose fetch URL is a real bare origin and whose push URL is a
# closed port: the pull works, the push is refused with a connection error.
sub new_hub {
    my ($reachable) = @_;
    my $work   = tempdir( CLEANUP => 1 );
    my $origin = "$work/origin.git";
    sh( 'init', '-q', '--bare', $origin );
    system("git clone -q '$origin' '$work/hub' 2>/dev/null");
    sh( '-C', "$work/hub", 'config', 'user.email', 'fleet@karr.test' );
    sh( '-C', "$work/hub", 'config', 'user.name',  'Fleet' );
    sh( '-C', "$work/hub", 'remote', 'set-url', '--push', 'origin', closed_port_url() )
        unless $reachable;
    my $cfg = path("$work/foundation.yml");
    $cfg->spew_utf8("hub: $work/hub\ndirs:\n  - $work/hub\n");
    return { work => $work, origin => $origin, hub => "$work/hub", cfg => "$cfg" };
}

sub foundation {
    my ( $h, $stdin, @argv ) = @_;
    my $err = gensym;
    my $pid = open3( my $in, my $out, $err, $^X, "-I$ROOT/lib",
        "$ROOT/bin/karr-foundation", '--config', $h->{cfg}, @argv );
    print {$in} $stdin if defined $stdin;
    close $in;
    my $stdout = do { local $/; <$out> } // '';
    my $stderr = do { local $/; <$err> } // '';
    waitpid $pid, 0;
    return { exit => $? >> 8, stdout => $stdout, stderr => $stderr };
}

sub fleet_refs {
    my ( $repo, $pat ) = @_;
    return scalar grep { length } split /\n/,
        `git -C '$repo' for-each-ref --format='%(refname)' '$pat'`;
}

# The two stable parts of the board commands' push-failure text.
sub like_push_failure {
    my ( $r, $what ) = @_;
    like $r->{stderr}, qr/not on the remote/, "$what: STDERR says what is saved here and not on the remote"
        or diag "STDERR was: [$r->{stderr}]";
    like $r->{stderr}, qr/karr sync/, "$what: STDERR says to run karr sync";
}

subtest 'ask: the question is written here, the failed push is reported' => sub {
    my $h = new_hub();
    my $r = foundation( $h, undef, 'ask', 'which one?' );
    is $r->{exit}, 0, 'exit code as today: 0';
    like $r->{stdout}, qr/Asked question #\d+/, 'the question was asked';
    ok fleet_refs( $h->{hub}, 'refs/karr-foundation/questions' ), 'the question ref is in the hub clone';
    is fleet_refs( $h->{origin}, 'refs/karr-foundation' ), 0, 'and nothing is on the remote';
    like_push_failure( $r, 'ask' );
};

subtest 'answer: the answer is written here, the failed push is reported' => sub {
    my $h = new_hub();
    my $q = foundation( $h, undef, 'ask', 'which one?' );
    my ($id) = $q->{stdout} =~ /Asked question #(\d+)/ or BAIL_OUT('no question id');
    my $before = fleet_refs( $h->{hub}, 'refs/karr-foundation/questions' );

    my $r = foundation( $h, undef, 'answer', $id, 'this one' );
    is $r->{exit}, 0, 'exit code as today: 0';
    like $r->{stdout}, qr/Answered question #$id: this one/, 'the question was answered';
    cmp_ok fleet_refs( $h->{hub}, 'refs/karr-foundation/questions' ), '>', $before,
        'an answer ref joined the question in the hub clone';
    is fleet_refs( $h->{origin}, 'refs/karr-foundation' ), 0, 'nothing is on the remote';
    like_push_failure( $r, 'answer' );
};

subtest 'plan: the chain is written here, the failed push is reported' => sub {
    my $h   = new_hub();
    my $doc = "steps:\n  - id: one\n    kind: shell\n    repo: $h->{work}\n    command: 'true'\n";
    my $r   = foundation( $h, $doc, 'plan' );
    is $r->{exit}, 0, 'exit code as today: 0';
    like $r->{stdout}, qr/Wrote chain/, 'the chain was written';
    ok fleet_refs( $h->{hub}, 'refs/karr-foundation/chain' ), 'the step ref is in the hub clone';
    is fleet_refs( $h->{origin}, 'refs/karr-foundation' ), 0, 'nothing is on the remote';
    like_push_failure( $r, 'plan' );
};

# The chain publishes its claim before it runs a step, and a claim that cannot
# be published declines the step ("left for the next tick", on STDOUT) -- the
# one push whose failure is already handled. So the remote is reachable at the
# claim, and the step command itself makes it unreachable: the pushes after the
# step (its outcome, the run log's end) are the best-effort ones this ticket is
# about.
subtest 'chain tick: the step state is written here, the failed push is reported' => sub {
    my $h      = new_hub(1);
    my $marker = path("$h->{work}/ran");
    my $break  = "git -C '$h->{hub}' remote set-url --push origin " . closed_port_url();
    my $store  = App::karr::Foundation::ChainStore->new(
        git => App::karr::Git->new( dir => $h->{hub} ) );
    $store->write_chain( [
        { id => 1, kind => 'shell', repo => $h->{work}, command => "echo x >> '$marker'; $break" },
    ] );

    my $r = foundation( $h, undef, 'chain' );
    is $r->{exit}, 0, 'exit code as today: 0';
    ok -e "$marker", 'the step command ran' or diag $r->{stdout} . $r->{stderr};
    is $store->step(1)->{state}, 'done', 'the step is written back as done in the hub clone';
    my $here   = `git -C '$h->{hub}' for-each-ref --format='%(objectname)' refs/karr-foundation/chain`;
    my $there  = `git -C '$h->{origin}' for-each-ref --format='%(objectname)' refs/karr-foundation/chain`;
    ok length $there, 'the claim reached the remote while it was reachable (the control)';
    isnt $here, $there, 'but the outcome is only in the hub clone';
    like_push_failure( $r, 'chain' );
};

done_testing;
