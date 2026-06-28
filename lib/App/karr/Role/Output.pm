# ABSTRACT: Role providing common output format options

package App::karr::Role::Output;
our $VERSION = '0.304';
use Moo::Role;
use MooX::Options;

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
  require JSON::MaybeXS;
  print JSON::MaybeXS::encode_json($data) . "\n";
}

1;
