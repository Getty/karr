# ABSTRACT: Role providing common output format options

package App::karr::Role::Output;
our $VERSION = '0.403';
use Moo::Role;
use MooX::Options;
# Loaded without importing: a Moo::Role composes every sub in this package into
# its consumers, so an imported encode_json would become a method on every
# command class.
use JSON::MaybeXS ();

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

sub print_json {
  my ($self, $data) = @_;
  print JSON::MaybeXS::encode_json($data) . "\n";
}

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
