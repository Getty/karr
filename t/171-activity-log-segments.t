use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use File::Temp qw( tempdir );
use YAML::XS qw( Dump );

use App::karr::Git;
use App::karr::BoardStore;
use App::karr::ActivityLog;
use App::karr::Task;
use App::karr::Cmd::Log;
use App::karr::Cmd::Context;

# Regression for karr board ticket #171:
#   ActivityLog::log_entry appended to one ref per identity, and a ref holds a
#   blob, so every entry rewrote the whole log: N entries of ~93 bytes wrote
#   ~93*N**2/2 bytes of objects. Measured on a fresh board, 10,000 mutating
#   commands would leave about 4.6 GB of blobs behind for a log that is 1 MB --
#   quadratic, and made worse by karr's parentless commits turning each of
#   those blobs into garbage the moment the next one lands.
#
#   The log is now a chain of segments -- refs/karr/log/<role>/<email> plus
#   <...>+000001, +000002 -- and only the newest one is appended to, so a write
#   costs at most segment_max_bytes instead of the whole history.
#
#   What this file nails down is the growth *behaviour*, not just the ref
#   names: doubling the number of entries may not much more than double the
#   bytes written. Reverting to one ref makes that ratio ~4 instead of ~2.

sub init_repo {
    my $repo = tempdir( CLEANUP => 1 );
    system( 'git', 'init', '-q', $repo ) == 0 or BAIL_OUT('git init failed');
    system( 'git', '-C', $repo, 'config', 'user.email', 'test@example.com' ) == 0
        or BAIL_OUT('git config failed');
    system( 'git', '-C', $repo, 'config', 'user.name', 'Test User' ) == 0
        or BAIL_OUT('git config failed');
    my $git = App::karr::Git->new( dir => $repo );
    $git->write_ref( 'refs/karr/config', Dump( { version => 1, board => { name => 'T' } } ) );
    $git->write_ref( 'refs/karr/meta/next-id', "1\n" );
    return ( $repo, $git );
}

# The identity every ActivityLog in this file writes under, with role 'agent'.
my $BASE = 'refs/karr/log/agent/test%40example.com';

sub log_refs {
    my ($repo) = @_;
    my @refs = split /\n/,
        `git -C $repo for-each-ref --format='%(refname)' refs/karr/log/`;
    return sort @refs;
}

# Raw (pre-zlib) size of every blob in the repository -- i.e. everything the
# log writes ever cost, including the copies that are now unreachable. Reading
# it out of git rather than off the filesystem keeps compression, which is much
# kinder to a big repetitive blob than to a small one, from flattening exactly
# the difference this measures.
sub blob_bytes {
    my ($repo) = @_;
    my $out = `git -C $repo cat-file --batch-all-objects --batch-check='%(objecttype) %(objectsize)'`;
    my $total = 0;
    for my $line ( split /\n/, $out ) {
        my ( $type, $size ) = split ' ', $line;
        $total += $size if defined $type && $type eq 'blob';
    }
    return $total;
}

sub write_entries {
    my ( $log, $from, $to ) = @_;
    $log->log_entry(
        agent   => 'agent-fox',
        action  => 'edit',
        task_id => $_,
        detail  => 'in-progress',
        ts      => sprintf( '2026-01-01T00:%02d:%02dZ', int( $_ / 60 ), $_ % 60 ),
    ) for $from .. $to;
    return;
}

subtest 'a log rotates into segment refs instead of one growing ref' => sub {
    my ( $repo, $git ) = init_repo();
    my $log = App::karr::ActivityLog->new(
        git => $git, role => 'agent', segment_max_bytes => 512 );
    write_entries( $log, 1, 40 );

    my @refs = log_refs($repo);
    cmp_ok( scalar @refs, '>', 1, '40 entries do not all live in one ref' )
        or diag( "refs: @refs" );
    is( $refs[0], $BASE, 'the first segment is the ref every karr wrote before' );
    like( $refs[1], qr/\A\Q$BASE\E\+000001\z/,
        'the second is a +NNNNNN sibling, not a child (git allows no ref under a ref)' );

    for my $ref (@refs) {
        my $len = length $git->read_ref($ref);
        cmp_ok( $len, '<=', 512 + 200,
            "$ref stays within the cap (plus at most the entry that filled it)" );
    }

    my @entries = $log->entries;
    is( scalar @entries, 40, 'every entry is still readable' );
    is_deeply( [ map { $_->{task_id} } @entries ], [ 1 .. 40 ],
        'and comes back in write order across segment boundaries' );
};

subtest 'the objects written grow linearly with the log, not quadratically' => sub {
    # Same cap, same entries, one run twice the length of the other. With one
    # ref per identity the bytes written go up by ~4x; with segments by ~2x.
    my %bytes;
    for my $n ( 60, 120 ) {
        my ( $repo, $git ) = init_repo();
        my $log = App::karr::ActivityLog->new(
            git => $git, role => 'agent', segment_max_bytes => 512 );
        write_entries( $log, 1, $n );
        $bytes{$n} = blob_bytes($repo);
    }

    cmp_ok( $bytes{60}, '>', 0, 'the measurement itself works' )
        or BAIL_OUT('git cat-file --batch-all-objects produced nothing');

    my $per_entry_60  = $bytes{60} / 60;
    my $per_entry_120 = $bytes{120} / 120;
    diag( sprintf 'blob bytes: 60 entries = %d (%.0f/entry), 120 entries = %d (%.0f/entry)',
        $bytes{60}, $per_entry_60, $bytes{120}, $per_entry_120 );

    cmp_ok( $bytes{120} / $bytes{60}, '<', 2.5,
        'twice the entries cost about twice the bytes (quadratic would be ~4x)' );
    cmp_ok( $per_entry_120 / $per_entry_60, '<', 1.4,
        'the cost of one entry does not grow with the length of the log' );
};

subtest 'last_entry reads one segment, not the whole log' => sub {
    my ( $repo, $git ) = init_repo();
    my $log = App::karr::ActivityLog->new(
        git => $git, role => 'agent', segment_max_bytes => 512 );
    write_entries( $log, 1, 40 );

    # Only log refs are counted: reading an entry also reads the board's
    # encoding marker (maybe_repair_legacy), which says nothing about how much
    # of the log was touched.
    my @read;
    my $orig = \&App::karr::Git::read_ref_with_oid;
    no warnings 'redefine';
    local *App::karr::Git::read_ref_with_oid = sub {
        push @read, $_[1] if $_[1] =~ m{\Arefs/karr/log/};
        return $orig->(@_);
    };

    @read = ();
    my $last = $log->last_entry;
    is( $last->{task_id}, 40, 'last_entry answers with the newest entry' );
    is( scalar @read, 1, 'and got there with a single ref read' )
        or diag( "read: @read" );

    @read = ();
    my @all = $log->entries;
    is( scalar @all, 40, 'reading the whole log still returns everything' );
    cmp_ok( scalar @read, '>', 1,
        'and does read every segment -- so the single read above is a property of last_entry, not of a one-ref log' );
};

subtest 'a board written before the split keeps its history and keeps growing' => sub {
    my ( $repo, $git ) = init_repo();

    # Exactly what a pre-#171 karr left behind: one ref, one JSON line each.
    $git->write_ref( $BASE, join "\n",
        '{"ts":"2026-01-01T00:00:00Z","agent":"old","action":"create","task_id":1}',
        '{"ts":"2026-01-02T00:00:00Z","agent":"old","action":"move","task_id":1}' );

    my $roomy = App::karr::ActivityLog->new(
        git => $git, role => 'agent', segment_max_bytes => 8192 );
    is( scalar $roomy->entries, 2, 'the old ref is read without migration' );

    $roomy->log_entry( agent => 'new', action => 'edit', task_id => 1,
        ts => '2026-01-03T00:00:00Z' );
    is_deeply( [ log_refs($repo) ], [$BASE],
        'and is appended to, not abandoned, while it is under the cap' );
    is( scalar $roomy->entries, 3, 'so the entry joins the existing history' );

    # Same board seen by a karr whose cap the old ref already exceeds: it must
    # roll forward rather than rewrite the ref it found.
    my $before = $git->read_ref($BASE);
    my $tight  = App::karr::ActivityLog->new(
        git => $git, role => 'agent', segment_max_bytes => 64 );
    $tight->log_entry( agent => 'new', action => 'edit', task_id => 2,
        ts => '2026-01-04T00:00:00Z' );

    is( $git->read_ref($BASE), $before, 'the full segment is left untouched' );
    is_deeply( [ log_refs($repo) ], [ $BASE, "$BASE+000001" ],
        'and the entry opens the next segment' );
    is_deeply( [ map { $_->{ts} } $tight->entries ],
        [ map { "2026-01-0${_}T00:00:00Z" } 1 .. 4 ],
        'the merged log stays in chronological order across the split' );
};

subtest 'pre-#75 legacy refs are still read, and still answer last_entry' => sub {
    my ( $repo, $git ) = init_repo();
    # The lossy naming karr used before #75, for role 'user': bare sanitized
    # email first, then role-qualified. Nothing writes these any more.
    $git->write_ref( 'refs/karr/log/test_example.com',
        '{"ts":"2025-01-01T00:00:00Z","agent":"old","action":"create","task_id":1}' );
    $git->write_ref( 'refs/karr/log/user/test_example.com',
        '{"ts":"2025-02-01T00:00:00Z","agent":"old","action":"move","task_id":1}' );

    my $log = App::karr::ActivityLog->new(
        git => $git, role => 'user', segment_max_bytes => 64 );
    is_deeply( [ map { $_->{ts} } $log->entries ],
        [ '2025-01-01T00:00:00Z', '2025-02-01T00:00:00Z' ],
        'both legacy refs are read, oldest scheme first' );
    is( $log->last_entry->{ts}, '2025-02-01T00:00:00Z',
        'last_entry falls back to them when this identity has no segment yet' );

    $log->log_entry( agent => 'new', action => 'edit', task_id => 1,
        ts => '2025-03-01T00:00:00Z' );
    is( $log->last_entry->{ts}, '2025-03-01T00:00:00Z',
        'and yields to the current scheme as soon as there is one' );
    is( scalar $log->entries, 3, 'without losing the legacy history' );
};

subtest 'the commands that read the whole log see every segment' => sub {
    my ( $repo, $git ) = init_repo();
    my $store = App::karr::BoardStore->new( git => $git );
    $store->save_task( App::karr::Task->new(
        id => 1, title => 'Task 1', status => 'todo', priority => 'high' ) );

    # Somebody else's log, spread over several segments.
    my $other = App::karr::ActivityLog->new(
        git => $git, role => 'agent', segment_max_bytes => 200 );
    $other->log_entry( agent => 'agent-fox', action => 'move', task_id => 1,
        detail => 'in-progress', ts => "2026-02-0${_}T00:00:00Z" ) for 1 .. 6;
    my @rotated = log_refs($repo);
    cmp_ok( scalar @rotated, '>', 1, 'the other identity rotated' );

    my $out;
    {
        local *STDOUT;
        open STDOUT, '>:encoding(UTF-8)', \$out or die $!;
        App::karr::Cmd::Log->new( store => $store, last => 100 )->execute( [], [] );
    }
    like( $out, qr/2026-02-01T00:00:00Z/, '`karr log` shows the oldest segment' )
        or diag("got:\n$out");
    like( $out, qr/2026-02-06T00:00:00Z/, 'and the newest' ) or diag("got:\n$out");

    # `karr context` leaves the invoking identity out of the activity section --
    # which has to mean all of its segments, not just the ref its identity
    # spells out.
    my $mine = App::karr::ActivityLog->new(
        git => $git, role => 'user', segment_max_bytes => 200 );
    $mine->log_entry( agent => 'agent-me', action => 'edit', task_id => 1,
        detail => 'todo', ts => "2026-03-0${_}T00:00:00Z" ) for 1 .. 6;

    my $ctx;
    {
        local *STDOUT;
        open STDOUT, '>:encoding(UTF-8)', \$ctx or die $!;
        App::karr::Cmd::Context->new(
            store => $store, git => $git, role => 'user',
            sections => 'activity', activity_limit => 20,
        )->execute( [], [] );
    }
    like( $ctx, qr/agent-fox/, '`karr context` reports the other identity' )
        or diag("got:\n$ctx");
    unlike( $ctx, qr/agent-me/,
        'and none of its own entries, including the rotated ones' )
        or diag("got:\n$ctx");
};

done_testing;
