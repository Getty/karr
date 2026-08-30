use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use TestKarr qw( run_karr run_karr_stdin );
use File::Temp qw( tempdir );
use Encode qw( encode_utf8 );

use App::karr::Encoding qw( yaml_load from_octets );
use App::karr::Git;

# Ticket #63: this file used to assert only which refs exist and what next_id
# is, never that a restored task's *content* survived. It therefore stayed green
# with a non-ASCII fixture even while backup/restore was destroying such a board
# (#53). The fixtures below carry non-ASCII and the restore subtests read the
# task back through the CLI.
my $TITLE = "Backup \x{dc}nicode \x{2014} task";
my $BODY  = "Body caf\x{e9} \x{2014} na\x{ef}ve";
my $TAG   = "gr\x{fc}n";

sub _git_ok {
    my (@cmd) = @_;
    my $rc = system(@cmd);
    is($rc, 0, "@cmd");
}

# In-process runner (t/lib/TestKarr.pm): same ($cwd, $stdin, @argv) signature
# and { exit, stdout, stderr } return as the open3 helper this file used to
# carry, dispatched through the shared App::karr::Dispatch path.
# KARR_TEST_SUBPROC=1 restores the old open3 path.
sub _run_karr {
    my ( $cwd, $stdin, @argv ) = @_;
    return defined $stdin
        ? run_karr_stdin( $cwd, $stdin, @argv )
        : run_karr( $cwd, @argv );
}

sub _init_repo {
    my $repo = tempdir( CLEANUP => 1 );
    _git_ok( 'git', 'init', '-q', $repo );
    _git_ok( 'git', '-C', $repo, 'config', 'user.email', 'test@example.com' );
    _git_ok( 'git', '-C', $repo, 'config', 'user.name', 'Test User' );
    return $repo;
}

subtest 'backup exports refs/karr snapshot as YAML' => sub {
    my $repo = _init_repo();
    is( _run_karr( $repo, undef, 'init', '--name', 'Backup Board' )->{exit}, 0, 'board initialized' );
    is(
        _run_karr( $repo, undef, 'create', encode_utf8($TITLE),
            '--body', encode_utf8($BODY), '--tags', encode_utf8($TAG) )->{exit},
        0, 'task created'
    );

    my $rv = _run_karr( $repo, undef, 'backup' );
    is( $rv->{exit}, 0, 'backup exits successfully' );

    my $snapshot = yaml_load( from_octets( $rv->{stdout} ) );
    is( $snapshot->{version}, 1, 'snapshot version recorded' );
    ok( exists $snapshot->{refs}{'refs/karr/config'}, 'config ref included in snapshot' );
    ok( exists $snapshot->{refs}{'refs/karr/meta/next-id'}, 'next-id ref included in snapshot' );
    ok( exists $snapshot->{refs}{'refs/karr/tasks/1/data'}, 'task ref included in snapshot' );

    # The snapshot is the task document verbatim, so the characters that went in
    # must be in it -- exactly once. Under #53 the YAML on stdout was encoded
    # three times over and neither of these held.
    my $doc = $snapshot->{refs}{'refs/karr/tasks/1/data'};
    like( $doc, qr/\Qtitle: $TITLE\E/, 'snapshot carries the title as characters' );
    like( $doc, qr/\Q$BODY\E/,         'snapshot carries the body as characters' );
    ok( index( $rv->{stdout}, encode_utf8($TITLE) ) >= 0,
        'and the bytes on stdout are singly-encoded UTF-8' );
};

subtest 'restore requires --yes and replaces current refs/karr state' => sub {
    my $repo = _init_repo();
    is( _run_karr( $repo, undef, 'init', '--name', 'Restore Board' )->{exit}, 0, 'board initialized' );
    is(
        _run_karr( $repo, undef, 'create', encode_utf8($TITLE),
            '--body', encode_utf8($BODY), '--tags', encode_utf8($TAG) )->{exit},
        0, 'first task created'
    );

    my $backup = _run_karr( $repo, undef, 'backup' );
    is( $backup->{exit}, 0, 'backup succeeds' );

    is( _run_karr( $repo, undef, 'create', 'Second task' )->{exit}, 0, 'second task created after backup' );
    my $git = App::karr::Git->new( dir => $repo );
    $git->write_ref( 'refs/karr/log/transient', qq({"action":"temp"}) );

    my $without_yes = _run_karr( $repo, $backup->{stdout}, 'restore' );
    isnt( $without_yes->{exit}, 0, 'restore without --yes fails' );
    like( $without_yes->{stderr}, qr/destructive/i, 'stderr warns about destructive restore' );

    my $with_yes = _run_karr( $repo, $backup->{stdout}, 'restore', '--yes' );
    is( $with_yes->{exit}, 0, 'restore with --yes succeeds' );
    like( $with_yes->{stderr}, qr/Restored refs\/karr/i, 'restore reports success on stderr' );

    is_deeply( [ $git->list_task_refs ], [1], 'task refs are replaced by snapshot contents' );
    ok( !$git->ref_exists('refs/karr/log/transient'), 'refs absent from snapshot are removed' );
    is( $git->read_next_id_ref, 2, 'next-id metadata is restored from the snapshot' );

    # #63: which refs came back is not the same question as whether what is in
    # them is still the task. Read the restored card and compare it field by
    # field with what was created.
    my $task = $git->load_task_ref(1);
    ok( $task, 'the restored task ref parses back into a task' );
    is( $task->title, $TITLE, 'restored title is intact' );
    is( $task->body,  $BODY,  'restored body is intact' );
    is_deeply( $task->tags, [$TAG], 'restored tag is intact' );

    ok( $git->ref_exists('refs/karr/meta/encoding'),
        'the encoding marker travels with the snapshot' );
    is( $git->board_encoding_version, 2,
        'so the restored board is still on the current encoding contract' );
};

done_testing;
