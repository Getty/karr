use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use File::Temp qw( tempdir );
use Cwd qw( abs_path getcwd );
use IPC::Open3 qw( open3 );
use Symbol qw( gensym );
use App::karr::Encoding qw( json_decode );

# Ticket #248: `karr delete ID --json` asked its confirmation on STDOUT, so the
# result object arrived behind a bare `Delete task 1: A? [y/N] ` and the stream
# as a whole would not decode:
#
#     printf "n\n" | karr delete 1 --json
#     -> Delete task 1: A? [y/N] {"deleted":false,"id":1,"title":"A"}
#
# The object was never the problem, which is why this pins the *stream* and not
# the object: every assertion below decodes what karr wrote to STDOUT in one
# piece, the way a caller does. A test that fished the JSON out of the line
# first would have passed against the bug it is here for.
#
# Both answers are covered on purpose. `y` and `n` print different results and
# take different branches out of the callback, and the prompt precedes both, so
# a fix that only covered the path it was reported on would leave the other
# half broken.
#
# The fix is the channel, not a --json branch: a question is dialogue and
# belongs on STDERR whatever the output format, so the plain path is pinned
# here too -- STDOUT there carries the outcome line and no question.

my $ROOT = abs_path('.');
my $BIN  = "$ROOT/bin/karr";

# A throwaway repo per subtest. Never the developer's board.
sub _board {
    my $repo = tempdir( CLEANUP => 1 );
    system( 'git', 'init', '-q', $repo ) == 0 or die 'git init';
    system( 'git', '-C', $repo, 'config', 'user.email', 'test@example.com' ) == 0
        or die 'git config';
    system( 'git', '-C', $repo, 'config', 'user.name', 'Test User' ) == 0
        or die 'git config';

    _karr( $repo, [], 'init', '--name', 'Channel Board' );
    _karr( $repo, [], 'create', '--title', 'Card one' );
    _karr( $repo, [], 'create', '--title', 'Card two' );
    return $repo;
}

# Runs karr with the answers on stdin and hands back the two streams apart.
# Keeping them apart is the whole point of the ticket, so the helper never
# merges them.
sub _karr {
    my ( $cwd, $answers, @argv ) = @_;

    my $old = getcwd();
    chdir $cwd or die "chdir $cwd: $!";
    my $err = gensym;
    my $pid = open3( my $in, my $out, $err, $^X, "-I$ROOT/lib", $BIN, @argv );
    chdir $old or die "chdir $old: $!";

    print {$in} $_ for @{ $answers || [] };
    close $in;

    my $stdout = do { local $/; <$out> };
    my $stderr = do { local $/; <$err> };
    waitpid( $pid, 0 );

    return {
        exit   => $? >> 8,
        stdout => defined $stdout ? $stdout : '',
        stderr => defined $stderr ? $stderr : '',
    };
}

# What a JSON consumer does: decode the stream, not a line picked out of it.
sub _decodes {
    my ( $text, $label ) = @_;
    my $data = eval { json_decode($text) };
    ok( defined $data, $label ) or diag "stdout was: $text";
    return $data;
}

subtest 'answering no leaves stdout decodable as a whole (#248)' => sub {
    my $repo = _board();

    my $rv = _karr( $repo, ["n\n"], 'delete', '1', '--json' );
    is( $rv->{exit}, 0, 'answering no is an answer, not a failure' )
        or diag $rv->{stderr};

    my $data = _decodes( $rv->{stdout},
        'the whole stream decodes -- no prompt in front of the object' );
    is( $data->{id},      1,       '...and it names the card' );
    is( $data->{deleted}, 0,       '...and reports it was not deleted' );
    is( $data->{title},   'Card one', '...with the title it carries' );

    like( $rv->{stderr}, qr/Delete task 1: Card one\? \[y\/N\] /,
        'the question was asked, on STDERR where dialogue belongs' );
    unlike( $rv->{stdout}, qr/\[y\/N\]/,
        'and nothing of it reached STDOUT' );

    is( _karr( $repo, [], 'show', '1', '--json' )->{exit}, 0,
        'the card is still on the board' );
};

subtest 'answering yes leaves stdout decodable as a whole (#248)' => sub {
    my $repo = _board();

    my $rv = _karr( $repo, ["y\n"], 'delete', '1', '--json' );
    is( $rv->{exit}, 0, 'the delete succeeds' ) or diag $rv->{stderr};

    my $data = _decodes( $rv->{stdout},
        'the whole stream decodes on the answering half too' );
    is( $data->{id},      1, '...and it names the card' );
    is( $data->{deleted}, 1, '...and reports the delete happened' );

    like( $rv->{stderr}, qr/Delete task 1: Card one\? \[y\/N\] /,
        'the question was asked on STDERR' );
    unlike( $rv->{stdout}, qr/\[y\/N\]/,
        'and nothing of it reached STDOUT' );

    isnt( _karr( $repo, [], 'show', '1', '--json' )->{exit}, 0,
        'the card is gone' );
};

subtest 'a batch with mixed answers decodes as one array (#248)' => sub {
    my $repo = _board();

    # Two prompts, two different answers: the case --yes cannot express, and
    # therefore the reason --json without --yes stays a legal invocation
    # instead of being refused.
    my $rv = _karr( $repo, [ "n\n", "y\n" ], 'delete', '1,2', '--json' );
    is( $rv->{exit}, 0, 'the batch exits 0' ) or diag $rv->{stderr};

    my $data = _decodes( $rv->{stdout},
        'two prompts still leave one decodable array behind' );
    is( ref $data, 'ARRAY', 'a batch renders as an array' );
    is( scalar @$data, 2, '...with one entry per id' );
    is( $data->[0]{id},      1, 'the declined card is first' );
    is( $data->[0]{deleted}, 0, '...and was kept' );
    is( $data->[1]{id},      2, 'the confirmed card is second' );
    is( $data->[1]{deleted}, 1, '...and was deleted' );

    unlike( $rv->{stdout}, qr/\[y\/N\]/,
        'neither question reached STDOUT' );
};

subtest 'the plain path keeps the question off stdout too (#248)' => sub {
    my $repo = _board();

    # Without --json there is no object to corrupt, but the same rule decides
    # the channel: `karr delete 1 > kept.txt` used to write the question into
    # the file and show the operator a blank cursor.
    my $rv = _karr( $repo, ["n\n"], 'delete', '1' );
    is( $rv->{exit}, 0, 'answering no exits 0' ) or diag $rv->{stderr};

    like( $rv->{stderr}, qr/Delete task 1: Card one\? \[y\/N\] /,
        'the question is on STDERR' );
    unlike( $rv->{stdout}, qr/\[y\/N\]/,
        'and not on STDOUT' );
    like( $rv->{stdout}, qr/Skipped task 1: Card one/,
        'while the outcome stays on STDOUT, where results live' );
};

done_testing;
