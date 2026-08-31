# ABSTRACT: Turn internal errors into one clean user-facing line

package App::karr::Error;
our $VERSION = '0.601';
use strict;
use warnings;
use Scalar::Util qw( blessed );
use Exporter qw( import );

our @EXPORT_OK = qw( user_error clean_error is_usage_error command_hint
  original_argv set_original_argv );

=head1 SYNOPSIS

    use App::karr::Error qw( user_error clean_error );

    eval { $dir->mkpath; 1 }
      or user_error( "Could not create $dir: ", clean_error($@) );

=head1 DESCRIPTION

karr's errors are read by humans and by agents scripting the CLI, so a
user-facing message is one line of prose and nothing else. Two things kept
breaking that:

=over 4

=item *

C<croak> appends C<< " at Some/Module.pm line 42." >> B<even when the message
already ends in a newline> -- the trailing-newline convention that C<die>
honours does not apply to L<Carp>. Every C<< croak "...\n" >> in a command path
therefore leaks a module path and a line number at the user.

=item *

Exceptions raised underneath karr (L<Path::Tiny>, libgit2, a captured C<git>
stderr) carry the same call-site suffix plus, often, several more lines of
backend chatter.

=back

C<user_error> raises the first kind and C<clean_error> reduces the second kind
to something fit to embed in the first. Keep C<croak> for programming errors --
a wrong argument to an internal method -- where the call site is the point.

=head1 SEE ALSO

L<karr>, L<App::karr>, L<App::karr::Git>

=cut

# The indentation every suggestion line carries, and the pattern that finds one
# again at the end of a message. Two spaces and the program name, so the line is
# recognisable without a marker of its own -- which matters because clean_error
# below has to tell karr's own answer apart from the backend chatter it exists
# to cut away.
my $HINT_INDENT = '  ';
my $HINT_LINE   = qr{\n\Q$HINT_INDENT\Ekarr [^\n]*};

sub command_hint {
  my (@tokens) = @_;
  return $HINT_INDENT
    . join ' ', 'karr', map { _hint_token($_) } grep { defined && length } @tokens;
}

=method command_hint

    command_hint( 'move', 79, 'in-progress', '--claim', 'NAME' );
    # "  karr move 79 in-progress --claim NAME"

Renders one line showing the invocation that would have worked, indented to sit
under the message it belongs to and with no trailing newline. The tokens are the
words after C<karr>: the real ones the caller typed where they are known, an
upper-case placeholder only for the value the caller still has to supply. A
token the shell would not take verbatim is single-quoted, so the line can be
copied as it stands.

The suggestion is always the B<last> thing a message prints. Agents pipe karr
through C<tail -n>, so anything printed in front of a usage block is what gets
cut (ticket k263).

=cut

# The argv as the caller typed it, kept for the suggestion lines. F<bin/karr>
# records it once and does it BEFORE the two rewrites that follow, because
# neither leaves the caller's own words standing:
# App::karr::Role::CliArgs/normalize_option_argv respells --claimed-by as
# --claimed_by (#256) and folds a flag-shaped value onto its option with an `=`
# (#259). A suggestion has to show what was typed, so it is read from here and
# not from @ARGV.
#
# Nothing else records one. A library caller, a test that loads a command class
# directly and F<bin/karr-foundation> all read back undef, and the suggestion
# line is then left out rather than guessed at (ticket k263).
my $ORIGINAL_ARGV;

sub set_original_argv {
  my (@argv) = @_;
  $ORIGINAL_ARGV = [@argv];
  return;
}

=method set_original_argv

    set_original_argv(@ARGV);

Records the caller's own argv, once, before anything rewrites it. F<bin/karr>
is the only caller.

=cut

sub original_argv {
  return unless defined $ORIGINAL_ARGV;
  return [@$ORIGINAL_ARGV];
}

=method original_argv

    my $argv = original_argv();   # arrayref, or undef when none was recorded

Reads that argv back as a fresh arrayref. Returns C<undef> where
L</set_original_argv> was never called, which is how a caller that cannot show
the words the user typed knows to print no suggestion at all.

=cut

sub _hint_token {
  my ($token) = @_;
  return $token if $token =~ m{\A[\w.,:=/@+#%-]+\z};
  # POSIX single quoting: the only character a single-quoted string cannot hold
  # is the quote itself, which closes, escapes and reopens.
  $token =~ s/'/'\\''/g;
  return "'" . $token . "'";
}

sub clean_error {
  my ($err) = @_;

  # libgit2 exceptions (Git::Libgit2::Error) put the useful text in ->message;
  # everything else in karr's path (Path::Tiny::Error, plain die strings)
  # stringifies usefully.
  my $detail = blessed($err) && $err->can('message') ? $err->message : "$err";
  $detail =~ s/\s+\z//;

  # karr's own suggestion block comes off the end first and goes back on last.
  # It is the one part of a message that must survive the first-line reduction
  # below -- App::karr::Role::TaskMutation's batch runner cleans every per-id
  # failure through here before printing it, and a `move` that answered
  # "Status 'in-progress' requires a claim:" with the answer itself cut off
  # would be worse than the message this replaced (ticket k263).
  my @hint;
  while ( $detail =~ s/($HINT_LINE)\z// ) {
    my $line = $1;
    $line =~ s/\A\n//;
    unshift @hint, $line;
  }

  $detail =~ s/ at \S+ line \d+\.?.*\z//s;   # the call site and all that follows
  $detail =~ s/\n.*\z//s;                    # keep only the first line
  $detail =~ s/\s+\z//;
  return 'unknown error' unless length $detail;
  return join "\n", $detail, @hint;
}

=method clean_error

    my $line = clean_error($@);

Reduces a caught exception to a single line of prose: drops the
C<at FILE line N.> call site, keeps only the first line, and trims trailing
whitespace. Returns C<'unknown error'> when nothing is left. Accepts a plain
string or an exception object (L<Git::Libgit2::Error>-style objects are read
through C<< ->message >>).

A suggestion block written by L</command_hint> is the exception to "one line":
those trailing lines are lifted off before the reduction and appended again
afterwards, so a message that ends in the command that would have worked keeps
it -- and keeps it last.

=cut

sub user_error {
  my (@parts) = @_;
  my $msg = join '', grep { defined } @parts;
  $msg =~ s/\s+\z//;
  # A plain die, not croak: die honours the trailing newline and appends no
  # call site. bin/karr's central handler prints this verbatim and maps it to
  # the exit code (ADR 0002), so messages that should exit 2 rather than 1 have
  # to start with one of its usage markers ("Usage:" is the one for a bad
  # option value).
  die "$msg\n";
}

=method user_error

    user_error("Task $id not found");
    user_error( "Could not install skill for $agent: ", clean_error($@) );

Raises a user-facing error whose message reaches STDERR exactly as written,
with no module path or line number appended. Parts are concatenated, undef
parts are dropped, and trailing whitespace is normalised to the single
terminating newline. Never returns.

=cut

# The stable leading markers a usage-error die carries (ADR 0002). This used to
# live only in the regex in bin/karr's central handler, which was fine while
# that handler was the only reader. App::karr::Role::TaskMutation's batch runner
# is the second: it has to tell a failure that belongs to one id apart from one
# that condemns the whole invocation, and a second copy of the marker list would
# drift the moment either side gained a marker -- the batch would then quietly
# demote a usage error (2) to a runtime failure (1).
my $USAGE_MARKERS = qr{
    \A (?: Unknown\ command:          # the dispatch guard in App::karr
         | unexpected\ extra\ argument # surplus positionals (Role::CliArgs)
         | Usage:                      # a missing required positional
         | Usage\ error:               # anything usage_error() raises
      )
}x;

sub is_usage_error {
  my ($err) = @_;
  return 0 unless defined $err;
  return "$err" =~ $USAGE_MARKERS ? 1 : 0;
}

=method is_usage_error

    exit( is_usage_error($@) ? 2 : 1 );

True when an exception is one of karr's usage errors -- "you called this wrong"
rather than "the operation failed" -- decided by the stable leading markers
listed in F<bin/karr>. Accepts a plain string or an exception object; a new
usage-error die must start with one of those markers, and C<usage_error> in
L<App::karr::Role::ExitCodes> is the generic way to emit one.

=cut

1;
