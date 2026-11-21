#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use lib 't/lib';
use Cwd ();
use lib Cwd::abs_path('lib');
use TestGit qw( require_git_c );
require_git_c();
use TestDenied qw( new_scene run );

# Ticket k344. A guarded push that comes back stale because another clone
# changed a card THIS command wrote ends a non-reapplying command (move, edit)
# on "task N changed on the remote while this command ran." That refusal says
# what is not published, so it counts as reported like every other push-failure
# message (App::karr::CloneState/reported): no lasting warning ("karr: changes
# still not on the remote ...") may follow it in the same run -- and whatever
# the warning would have named must be in the refusal instead.
#
# The race is t/lib/RaceBeforePush.pm (clone b edits card 1 right before a's
# push); a ref the take-back leaves is t/lib/SecondWriter.pm. Everything else
# is the real bin/karr against a bare origin.

my $LIB = Cwd::abs_path('lib');
my $TL  = Cwd::abs_path('t/lib');
my $BIN = Cwd::abs_path('bin/karr');

sub stale_scene {
    my $s = new_scene( seed => 1 );
    system("git clone -q '$s->{origin}' '$s->{work}/b' 2>/dev/null");
    system( 'git', '-C', "$s->{work}/b", 'config', 'user.email', 'b@karr.test' );
    system( 'git', '-C', "$s->{work}/b", 'config', 'user.name',  'agent-b' );
    system("cd '$s->{work}/b' && '$^X' -I'$LIB' '$BIN' sync >/dev/null 2>&1");
    return $s;
}

# Clone b edits card 1 right before a's push; a's command is @argv. $second
# (a ref regex) also loads SecondWriter, so the take-back leaves those refs.
sub stale_run {
    my ( $s, $second, @argv ) = @_;
    local $ENV{KARR_TEST_RACE} = "cd '$s->{work}/b' && env -u PERL5OPT -u KARR_TEST_RACE '$^X' -I'$LIB' '$BIN' edit 1 --title 'from b' >/dev/null";
    local $ENV{PERL5LIB} = join ':', $LIB, $TL, grep { defined && length } $ENV{PERL5LIB};
    local $ENV{PERL5OPT} = join ' ', ( defined $second ? '-MSecondWriter' : () ), '-MRaceBeforePush';
    local $ENV{KARR_SECOND_WRITER_REFS} = $second if defined $second;
    return run( $s, @argv );
}

my $WARN = qr/^karr: (?:changes still not on the remote|this clone cannot write the board)/m;

subtest 'a) a ref the take-back left: the refusal says it, no warning repeats it' => sub {
    my $s = stale_scene();
    my $r = stale_run( $s, '/log/', 'edit', '1', '--title', 'from a' );
    my $e = $r->{stderr};

    is $r->{exit}, 1, 'exit 1 stays';
    like $e, qr/^task 1 changed on the remote while this command ran\.$/m, 'the refusal was printed';
    like $e, qr/still holds this clone's version, not the remote's, and would go out with the next push\./,
        'and it names the ref the take-back left';
    unlike $e, $WARN, 'no lasting warning after it';
};

subtest 'b) taken back clean, older unpublished work: the refusal names it, no warning' => sub {
    my $s = stale_scene();
    is run( $s, 'create', 'older', '--local-only' )->{exit}, 0, 'a local-only card (precondition)';
    my $r = stale_run( $s, undef, 'edit', '1', '--title', 'from a' );
    my $e = $r->{stderr};

    is $r->{exit}, 1, 'exit 1 stays';
    like $e, qr/^task 1 changed on the remote while this command ran\.$/m, 'the refusal was printed';
    like $e, qr/it was taken back here: this clone now holds the remote's version/, 'the clean branch';
    like $e, qr/^Saved in this clone, not on the remote: .*#2/m,
        'the refusal names the still-unpublished card with the saved-here line';
    unlike $e, $WARN, 'no lasting warning after it';
};

done_testing;
