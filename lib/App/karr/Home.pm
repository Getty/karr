# ABSTRACT: The user's home directory, on Windows too

package App::karr::Home;
our $VERSION = '0.603';
use strict;
use warnings;
use Exporter qw( import );

our @EXPORT_OK = qw( home_dir require_home_dir );

=head1 SYNOPSIS

    use App::karr::Home qw( home_dir require_home_dir );

    my $home = home_dir();                 # undef when there is none to name
    my $dir  = require_home_dir('--global');   # dies with one clean line

=head1 DESCRIPTION

Everything karr keeps per user -- the ssh keys it offers a remote, the
globally installed skills, karr-foundation's fleet config -- hangs off the
home directory, and C<$ENV{HOME}> alone does not name it everywhere:
PowerShell and cmd set C<USERPROFILE> and no C<HOME>. Building a path from the
bare variable there looked for keys under F</.ssh/> and died inside
L<Path::Tiny> for the rest. This module is the one place that answers the
question.

=cut

# HOME first, on every platform: it is what Git Bash sets on Windows, and what
# a user who exported it there means. USERPROFILE only on MSWin32 -- on a
# system where HOME is the convention, its absence is a statement and not a
# gap to fill from a variable something else happened to export.
sub home_dir {
  for my $name ( $^O eq 'MSWin32' ? qw( HOME USERPROFILE ) : 'HOME' ) {
    my $dir = $ENV{$name};
    return $dir if defined $dir && length $dir;
  }
  return;
}

=func home_dir

    my $home = home_dir();

Returns the user's home directory as the environment names it: C<HOME>, and
on MSWin32 C<USERPROFILE> when C<HOME> is unset or empty. Returns C<undef>
when neither is set -- the caller decides whether that is an error
(L</require_home_dir>) or merely nothing to look in.

=cut

sub require_home_dir {
  my ($what) = @_;
  my $home = home_dir();
  return $home if defined $home;
  my $names = $^O eq 'MSWin32' ? 'neither HOME nor USERPROFILE is' : 'HOME is not';
  die 'karr: cannot resolve ' . $what . ': ' . $names . " set\n";
}

=func require_home_dir

    my $home = require_home_dir('--global');

L</home_dir> for a caller that cannot go on without one. Dies with a single
user-facing line naming C<$what> -- the option or file that needed the home
directory -- and the variables that were looked at.

=cut

1;
