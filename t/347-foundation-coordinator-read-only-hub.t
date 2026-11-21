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
use TestDenied qw( new_scene run deny allow can_deny );
use Path::Tiny qw( path );
use IPC::Open3 qw( open3 );
use Symbol qw( gensym );
use YAML::XS ();
use App::karr::Git;
use App::karr::BoardStore;
use App::karr::Task;

# Ticket k339: a hub clone that is read-only for its board does not start the
# coordination agent. Its plan/answer calls would be refused at the read-only
# door and an agent run is the expensive part of a tick, so foundation prints
# one line instead and the deviation is recorded again by the next tick once
# the hub can write. Exit code of the tick is unchanged (ADR 0002).
#
# Deviation used: a board no assignment routes (Coordinator->route wants the
# coordination agent for it). Two branches of Foundation::run call
# _coordinator->dispatch after that:
#   overview -- no board resolves an agent ("No agent will run on any board")
#   drain    -- another board has its own agent, so a drain happens first
#
# The control (writable hub, same deviation) runs the coordinator command, so
# a missing marker below cannot mean "the coordinator was never wanted".

my $ROOT = Cwd::abs_path('.');

sub foundation {
    my ( $cfg, @argv ) = @_;
    my $err = gensym;
    my $pid = open3( my $in, my $out, $err, $^X, "-I$ROOT/lib", "$ROOT/bin/karr-foundation", '--config', "$cfg", @argv );
    close $in;
    my $stdout = do { local $/; <$out> } // '';
    my $stderr = do { local $/; <$err> } // '';
    waitpid $pid, 0;
    return { exit => $? >> 8, stdout => $stdout, stderr => $stderr, all => $stdout . $stderr };
}

my @KEEP;

# A plain repo with one todo card on a local board (no remote needed).
sub board_repo {
    my $dir = Path::Tiny->tempdir( CLEANUP => 1 );
    push @KEEP, $dir;
    system( 'git', '-C', "$dir", 'init', '-q' ) == 0 or die 'git init';
    system( 'git', '-C', "$dir", 'config', 'user.email', 'fleet@example.com' );
    system( 'git', '-C', "$dir", 'config', 'user.name',  'Fleet' );
    my $store = App::karr::BoardStore->new( git => App::karr::Git->new( dir => "$dir" ) );
    my $id    = $store->allocate_next_id;
    $store->save_task( App::karr::Task->new( id => $id, title => "task $id", status => 'todo' ) );
    return $dir;
}

# One tick. $branch is 'overview' (no board has an agent) or 'drain' (a second
# board names its own agent, so the tick drains before dispatching).
sub scenario {
    my ( $s, $branch ) = @_;
    my $work     = path( $s->{work} );
    my $tag      = $branch . '-' . int( rand 1e9 );
    my $marker   = $work->child("coordinator-ran-$tag");
    my $unrouted = board_repo();
    my @dirs     = ("$unrouted");
    if ( $branch eq 'drain' ) {
        my $own = board_repo();
        $own->child('.karr')->spew_utf8("agent: worker\n");
        push @dirs, "$own";
    }
    my $cfg = $work->child("fleet-$tag.yml");
    $cfg->spew_utf8( YAML::XS::Dump( {
        hub    => $s->{clone},
        dirs   => \@dirs,
        agents => {
            planner => { command => "touch $marker", role => 'coordinator' },
            worker  => { command => 'true' },
        },
    } ) );
    my $r = foundation($cfg);
    return ( $r, $marker );
}

# Pins that a scenario really reached the Foundation::run branch it names.
sub branch_is {
    my ( $r, $branch ) = @_;
    my $overview = $r->{stdout} =~ /No agent will run on any board/;
    ok $branch eq q{overview} ? $overview : !$overview, "the tick took the $branch branch of run" or diag $r->{all};
}

my $s = new_scene( seed => 1 );

for my $branch (qw( overview drain )) {
    subtest "control ($branch): a writable hub calls the coordination agent" => sub {
        my ( $r, $marker ) = scenario( $s, $branch );
        branch_is($r, $branch);
        is $r->{exit}, 0, 'exit 0' or diag $r->{all};
        ok -e "$marker", 'the coordinator command ran (so its absence below means something)'
            or diag $r->{all};
        like $r->{stdout}, qr/calling the coordination agent 'planner'/, 'and the tick says so';
    };
}

sub assert_not_called {
    my ($branch) = @_;
    my ( $r, $marker ) = scenario( $s, $branch );
    branch_is($r, $branch);
    is $r->{exit}, 0, 'tick exit code is unchanged (0)' or diag $r->{all};
    ok !-e "$marker", 'the coordinator command never ran' or diag $r->{all};
    unlike $r->{all}, qr/calling the coordination agent/, 'the tick does not claim to call it';
    my ($line) = grep { /coordinat/i && /read-only/i } split /\n/, $r->{all};
    ok defined $line, 'one line says the coordination agent was not called because the hub is read-only'
        or diag $r->{all};
    $line //= '';
    ok index( $line, $s->{clone} ) >= 0 || index( $line, path( $s->{clone} )->basename ) >= 0,
        'and that line names the hub' or diag "line: $line";
}

for my $branch (qw( overview drain )) {
    subtest "karr readonly on ($branch): the coordination agent is not started" => sub {
        is run( $s, 'readonly', 'on' )->{exit}, 0, 'readonly on';
        assert_not_called($branch);
        run( $s, 'readonly', 'off' );
    };
}

SKIP: {
    skip 'running as root: it ignores the read-only mode of the bare repository', 2 unless can_deny();

    for my $branch (qw( overview drain )) {
        subtest "denied ($branch): the coordination agent is not started" => sub {
            deny($s);
            is run( $s, 'edit', '1', '-a', 'learn the denial' )->{exit}, 1, 'the clone learns denied';
            assert_not_called($branch);
            allow($s);
            run( $s, 'readonly', 'off' );
        };
    }
}

done_testing;
