#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use Cwd ();
use lib Cwd::abs_path('lib');
use TestGit qw( require_git_c );
require_git_c();
use TestDenied qw( new_scene run deny pushes reset_log karr_config can_deny lines_matching );
use App::karr::CloneState;

# Ticket k333 (review finding R1), end to end. A denied write is taken back --
# but a ref another process wrote since the command's own write cannot be, and
# the message said "Nothing was changed" over a card that was still in the
# clone. Now the take-back reports what it left (App::karr::Git/
# take_back_journal), and the denial message (App::karr::CloneState/
# denial_message) and the stale-push message (Role::SyncLifecycle) name it.
#
# The second writer is t/lib/SecondWriter.pm, loaded into the one karr process
# through PERL5OPT: right before the take-back it rewrites the refs the test
# names. Everything else is the real bin/karr against a bare origin made
# unwritable with chmod.

plan skip_all => 'running as root: it ignores the read-only mode of the bare repository'
    unless can_deny();

my $LIB = Cwd::abs_path('lib');
my $TL  = Cwd::abs_path('t/lib');
my $BIN = Cwd::abs_path('bin/karr');

# Runs a block with SecondWriter loaded into every karr process it starts.
sub with_second_writer {
    my ( $refs, $code, %more ) = @_;
    local $ENV{PERL5LIB} = join ':', $LIB, $TL, grep { defined && length } $ENV{PERL5LIB};
    local $ENV{PERL5OPT} = join ' ', '-MSecondWriter', ( $more{opt} // () );
    local $ENV{KARR_SECOND_WRITER_REFS} = $refs if defined $refs;
    local $ENV{KARR_SECOND_WRITER_MODE} = $more{mode} if defined $more{mode};
    return $code->();
}

sub ref_exists {
    my ( $s, $ref ) = @_;
    return system( 'git', '-C', $s->{clone}, 'rev-parse', '-q', '--verify', $ref ) == 0 ? 1 : 0;
}

my $PART = qr/^Part of this command's change could not be taken back and is still in this clone, not on the remote: (.+?)\. This clone is now read-only for the board; the change stays here until this clone can write, then 'karr sync' publishes it\.$/m;

subtest 'the card left by a second writer: it is named, not "Nothing was changed"' => sub {
    my $s = new_scene( seed => 1 );
    deny($s);
    reset_log($s);
    my $r = with_second_writer( undef, sub { run( $s, 'create', 'probe', '--body', 'x' ) } );
    my $e = $r->{stderr};

    is $r->{exit}, 1, 'exit 1';
    is $r->{stdout}, '', 'no success line';
    like $e, qr/^karr: write access to the remote 'origin' .* was denied: this user cannot write the remote repository's files\.$/m,
        'line 1 is still the denial';
    my @lines = grep { /^(?:karr: write access|Part of this|This command's|Nothing was changed)/ } split /\n/, $e;
    my ($names) = $lines[1] =~ $PART;
    ok defined $names, 'line 2 is verbatim the "Part of this command\'s change" sentence';
    is $names, '#2', 'naming exactly the card';
    unlike $e, qr/Nothing was changed/, 'and "Nothing was changed" is nowhere';
    like $e, qr/^If this clone is only for reading: karr readonly on\.$/m, 'the fix lines print';
    like $e, qr/karr readonly off/, 'including how to lift the state';
    ok ref_exists( $s, 'refs/karr/tasks/2/data' ), 'the card ref is still in this clone';
    is karr_config($s)->{'karr.readonly'}, 'denied', 'git config: karr.readonly = denied';
    is pushes($s), 1, 'one push attempt';
};

subtest 'card and log left: both named, in that order' => sub {
    my $s = new_scene( seed => 1 );
    deny($s);
    my $r = with_second_writer( '/tasks/\d+/data\z|/log/', sub { run( $s, 'create', 'probe' ) } );
    my $e = $r->{stderr};

    is $r->{exit}, 1, 'exit 1';
    my ($names) = $e =~ $PART;
    ok defined $names, 'the "Part of" sentence';
    is $names, '#2, log', 'names the card and the log';
    unlike $e, qr/Nothing was changed/, 'no "Nothing was changed"';
    ok ref_exists( $s, 'refs/karr/tasks/2/data' ), 'the card ref is still here';
    is karr_config($s)->{'karr.readonly'}, 'denied', 'the clone is read-only';
};

subtest 'nothing put back at all: "This command\'s change"' => sub {
    my $s = new_scene( seed => 1 );
    deny($s);
    my $r = with_second_writer( '.', sub { run( $s, 'create', 'probe' ) } );
    my $e = $r->{stderr};

    is $r->{exit}, 1, 'exit 1';
    like $e, qr/^This command's change could not be taken back and is still in this clone, not on the remote: #2[^.\n]*\. This clone is now read-only for the board; the change stays here until this clone can write, then 'karr sync' publishes it\.$/m,
        'the sentence starts with "This command\'s change", not "Part of"';
    unlike $e, qr/Part of this command/, 'not "Part of"';
    unlike $e, qr/Nothing was changed/, 'no "Nothing was changed"';
    ok ref_exists( $s, 'refs/karr/tasks/2/data' ), 'the card ref is still here';
    is karr_config($s)->{'karr.readonly'}, 'denied', 'the clone is read-only';
};

subtest 'a reset that throws leaves the ref the same way' => sub {
    my $s = new_scene( seed => 1 );
    deny($s);
    my $r = with_second_writer( '/tasks/\d+/data\z', sub { run( $s, 'create', 'probe' ) }, mode => 'throw' );
    my $e = $r->{stderr};

    is $r->{exit}, 1, 'exit 1';
    my ($names) = $e =~ $PART;
    ok defined $names, 'the "Part of" sentence';
    is $names, '#2', 'naming the card whose delete failed';
    unlike $e, qr/Nothing was changed/, 'no "Nothing was changed"';
    ok ref_exists( $s, 'refs/karr/tasks/2/data' ), 'the card ref is still here';
};

subtest 'older unpublished changes: "Also still only in this clone", without repeating a left name' => sub {
    my $s = new_scene( seed => 1 );
    # An older change that never reached the remote: card #2, local only.
    is run( $s, 'create', 'older', '--local-only' )->{exit}, 0, 'a local-only card (precondition)';
    deny($s);
    my $r = with_second_writer( undef, sub { run( $s, 'create', 'probe' ) } );
    my $e = $r->{stderr};

    is $r->{exit}, 1, 'exit 1';
    like $e, qr/^Part of this command's change could not be taken back and is still in this clone, not on the remote: #3\./m,
        'the command\'s own card (#3) is the left one';
    my ($also) = $e =~ /^(Also still only in this clone, not on the remote: .*)$/m;
    ok defined $also, 'the older changes are on a line starting "Also still only in this clone, not on the remote:"';
    like $also // '', qr/#2/, 'it names the older card';
    unlike $also // '', qr/#3/, 'and does not repeat the left card';
    unlike $e, qr/^Still only in this clone/m, 'the plain "Still only" wording is not used beside a left ref';
};

subtest 'a full take-back keeps the old line' => sub {
    my $s = new_scene( seed => 1 );
    deny($s);
    my $r = run( $s, 'create', 'probe' );
    my $e = $r->{stderr};

    is $r->{exit}, 1, 'exit 1';
    like $e, qr/^Nothing was changed: this command's change was taken back, and this clone is now read-only for the board\. Run the command again once this clone can write\.$/m,
        'the C1 line, verbatim';
    unlike $e, qr/could not be taken back/, 'and nothing was left';
    ok !ref_exists( $s, 'refs/karr/tasks/2/data' ), 'the card is gone';
};

# `already` (the clone was read-only before this denial) cannot be reached
# through the CLI: a read-only clone refuses a write before it writes. The
# message builder is the unit that carries the wording.
subtest 'denial_message: left, already, and the line about older changes' => sub {
    my %base = (
        failure => { class => 'denied', reason => "this user cannot write the remote repository's files", remote => 'origin' },
        remote  => 'origin', push_url => '/srv/o.git',
    );
    my $text = App::karr::CloneState->denial_message( %base, taken_back => ['x'], left => ['#7'], already => 1 );
    like $text, qr/^Part of this command's change could not be taken back and is still in this clone, not on the remote: #7\. This clone stays read-only for the board; the change stays here until this clone can write, then 'karr sync' publishes it\.$/m,
        'already: "This clone stays read-only", not "is now"';
    unlike $text, qr/is now read-only/, 'no "is now"';

    $text = App::karr::CloneState->denial_message( %base, left => [ '#7', 'log' ], unpublished => ['#3'] );
    like $text, qr/^This command's change could not be taken back and is still in this clone, not on the remote: #7, log\. This clone is now read-only/m,
        'nothing put back: "This command\'s change", names joined';
    like $text, qr/^Also still only in this clone, not on the remote: #3\.$/m, 'unpublished after a left: "Also still"';

    $text = App::karr::CloneState->denial_message( %base, taken_back => ['x'], unpublished => ['#3'] );
    like $text, qr/^Still only in this clone, not on the remote: #3\.$/m, 'without a left ref it is the plain "Still"';
    like $text, qr/^Nothing was changed: this command's change was taken back/m, 'and "Nothing was changed" stays';
};

# ---------------------------------------------------------------------
# The stale path: another clone changed the card between this command's pull
# and its push. The push is refused as stale, the command's writes are taken
# back, the remote's version is pulled in, and the command stops.
# ---------------------------------------------------------------------
sub stale_scene {
    my $s = new_scene( seed => 1 );
    system("git clone -q '$s->{origin}' '$s->{work}/b' 2>/dev/null");
    system( 'git', '-C', "$s->{work}/b", 'config', 'user.email', 'b@karr.test' );
    system( 'git', '-C', "$s->{work}/b", 'config', 'user.name',  'agent-b' );
    system("cd '$s->{work}/b' && '$^X' -I'$LIB' '$BIN' sync >/dev/null 2>&1");
    return $s;
}

# Clone b edits card 1 right before a's push; a's own command is $argv.
sub stale_run {
    my ( $s, $refs, @argv ) = @_;
    local $ENV{KARR_TEST_RACE} = "cd '$s->{work}/b' && env -u PERL5OPT -u KARR_TEST_RACE '$^X' -I'$LIB' '$BIN' edit 1 --title 'from b' >/dev/null";
    return with_second_writer( $refs, sub { run( $s, @argv ) }, opt => '-MRaceBeforePush' );
}

subtest 'stale, a ref the take-back left survives the pull: named, with the next push as the danger' => sub {
    my $s = stale_scene();
    my $r = stale_run( $s, '/log/', 'edit', '1', '--title', 'from a' );
    my $e = $r->{stderr};

    is $r->{exit}, 1, 'exit 1';
    like $e, qr/^task 1 changed on the remote while this command ran\.$/m, 'names the card that changed';
    like $e, qr/^Nothing this command wrote was published, but not all of it could be taken back here: .*log.* still holds this clone's version, not the remote's, and would go out with the next push\.$/m,
        'says not all of it was taken back, and what still holds this clone\'s version';
    like $e, qr/^Run the command again if it still applies\.$/m, 'and to run it again';
    unlike $e, qr/it was taken back here: this clone now holds the remote's version/, 'not the all-clear wording';
    ok ref_exists( $s, 'refs/karr/log/user/a%40karr.test' ), 'the log ref is still in the clone';
};

subtest 'stale, the left ref is one the pull replaced: the old all-clear message' => sub {
    my $s = stale_scene();
    my $r = stale_run( $s, '/tasks/\d+/data\z', 'edit', '1', '--title', 'from a' );
    my $e = $r->{stderr};

    is $r->{exit}, 1, 'exit 1';
    like $e, qr/^Nothing this command wrote was published, and it was taken back here: this clone now holds the remote's version\.$/m,
        'the old message';
    unlike $e, qr/not all of it could be taken back/, 'without the new warning';
};

subtest 'stale, everything taken back: the old message too' => sub {
    my $s = stale_scene();
    my $r = stale_run( $s, '^$', 'edit', '1', '--title', 'from a' );
    is $r->{exit}, 1, 'exit 1';
    like $r->{stderr}, qr/Nothing this command wrote was published, and it was taken back here/, 'the old message';
    unlike $r->{stderr}, qr/not all of it could be taken back/, 'no new warning';
};

done_testing;
