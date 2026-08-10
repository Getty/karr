# ABSTRACT: Turn internal errors into one clean user-facing line

package App::karr::Error;
our $VERSION = '0.403';
use strict;
use warnings;
use Scalar::Util qw( blessed );
use Exporter qw( import );

our @EXPORT_OK = qw( user_error clean_error );

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

sub clean_error {
  my ($err) = @_;

  # libgit2 exceptions (Git::Libgit2::Error) put the useful text in ->message;
  # everything else in karr's path (Path::Tiny::Error, plain die strings)
  # stringifies usefully.
  my $detail = blessed($err) && $err->can('message') ? $err->message : "$err";

  $detail =~ s/ at \S+ line \d+\.?.*\z//s;   # the call site and all that follows
  $detail =~ s/\n.*\z//s;                    # keep only the first line
  $detail =~ s/\s+\z//;
  return length $detail ? $detail : 'unknown error';
}

=method clean_error

    my $line = clean_error($@);

Reduces a caught exception to a single line of prose: drops the
C<at FILE line N.> call site, keeps only the first line, and trims trailing
whitespace. Returns C<'unknown error'> when nothing is left. Accepts a plain
string or an exception object (L<Git::Libgit2::Error>-style objects are read
through C<< ->message >>).

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

1;
