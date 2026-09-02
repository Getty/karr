# ABSTRACT: Shared colour decision for the renderers that colour their output

package App::karr::Role::Color;
our $VERSION = '0.601';
use Moo::Role;
use MooX::Options;

=head1 DESCRIPTION

The one place that decides whether a renderer colours its output. Both
L<App::karr::Cmd::Board> and L<App::karr::Cmd::Dashboard> used to carry the
same test (C<-t STDOUT && !$ENV{NO_COLOR}>) as a copy; this role is that test
moved into one place and extended with the C<--no-color> flag.

Colour is on only when all three hold: standard output is a terminal,
C<NO_COLOR> is unset, and neither this command nor a root C<--no-color>
disabled it. The flag is declared here so it is available in both placements
the way C<--dir> is -- C<karr --no-color board> as well as C<karr board
--no-color> -- and the root command composes this role for the same reason.

=cut

option color => (
  is        => 'ro',
  negatable => 1,
  doc       => 'Colour output; --no-color disables it for this invocation',
);

sub _effective_color {
  my ($self) = @_;
  return 0 if defined $self->color && !$self->color;
  if ( $self->can('command_chain') && ( my $chain = $self->command_chain ) ) {
    for my $cmd (@$chain) {
      next if $cmd == $self;
      return 0 if $cmd->can('color') && defined $cmd->color && !$cmd->color;
    }
  }
  return 1;
}

sub _want_color {
  my ($self) = @_;
  return 0 unless $self->_effective_color;
  return 0 if $ENV{NO_COLOR};
  return -t STDOUT ? 1 : 0;
}

1;
