# ABSTRACT: Role providing common output format options

package App::karr::Role::Output;
our $VERSION = '0.501';
use Moo::Role;
use MooX::Options;
# Loaded without importing: a Moo::Role composes every sub in this package into
# its consumers, so an imported json_encode would become a method on every
# command class.
use App::karr::Encoding ();

=head1 DESCRIPTION

Small role that adds shared output options for commands with alternate
renderings and provides a JSON printer used throughout the CLI.

=cut

option json => (
  is => 'ro',
  doc => 'JSON output',
);

option compact => (
  is => 'ro',
  doc => 'Compact output',
);

# Characters out, not octets: STDOUT carries the CLI's :encoding(UTF-8) layer
# (App::karr::Encoding::enable_std_utf8), so encoding here as well would give an
# agent double-encoded JSON -- the machine-readable half of ticket #53.
sub print_json {
  my ($self, $data) = @_;
  print App::karr::Encoding::json_encode($data) . "\n";
}

=method print_json

    $self->print_json($data);

In a command class that composes this role, encodes C<$data> (a plain hashref
or arrayref) via L<App::karr::Encoding/json_encode> and prints it to STDOUT
followed by a newline, unconditionally -- unlike L</print_json_results> below,
it does not check C<< $self->json >> itself, so a caller that wants the
C<--json> gate applies it before calling this method.

=cut

=method print_json_results

  $self->print_json_results(@results);

Emits a batch of per-item result hashes as JSON when C<--json> is active, and
is a no-op otherwise. A single result is rendered as a bare JSON object and
multiple results as a JSON array, matching the output convention shared by the
C<move>, C<edit>, C<delete>, and C<archive> commands.

=cut

sub print_json_results {
  my ($self, @results) = @_;
  return unless $self->json;
  $self->print_json(@results == 1 ? $results[0] : \@results);
}

1;
