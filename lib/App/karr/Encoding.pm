# ABSTRACT: The character/octet boundary for karr

package App::karr::Encoding;
our $VERSION = '0.403';
use strict;
use warnings;
use Exporter qw( import );
use Encode qw( encode decode FB_CROAK LEAVE_SRC );
use YAML::XS ();
use JSON::MaybeXS ();

=head1 SYNOPSIS

    use App::karr::Encoding qw( decode_argv enable_std_utf8 yaml_dump );

    enable_std_utf8();
    decode_argv();

    print yaml_dump( { title => "Fix \x{fc}nicode \x{2014} \x{e4}rger" } );

=head1 DESCRIPTION

karr holds one rule: B<everything inside the program is a Perl character
string, and bytes exist only at the outer edges>. This module is the only place
that crosses that line, so every edge crosses it the same way.

The edges, and who guards them:

=over 4

=item * B<C<@ARGV>> — L</decode_argv>, called from F<bin/karr> and
F<bin/karr-foundation>.

=item * B<C<STDOUT>/C<STDERR>> — L</enable_std_utf8>, likewise called from the
two scripts. An in-process caller that captures output (a test, say) has to put
the same layer on its capture handle, because reopening C<STDOUT> drops the
layer the script installed.

=item * B<Git refs> — L<App::karr::Git/write_ref> and
L<App::karr::Git/read_ref> call L</to_octets> and L</from_octets>. Blobs hold
UTF-8 octets; everything above C<read_ref> sees characters.

=item * B<Files> — L<Path::Tiny>'s C<slurp_utf8>/C<spew_utf8>, which are
already character-level. Nothing extra is needed, and nothing extra may be
added: an C<Encode::encode> in front of a C<spew_utf8> is a double encode.

=item * B<YAML> — L</yaml_dump> and L</yaml_load>. C<YAML::XS::Dump> emits
octets and C<YAML::XS::Load> expects them, which is the opposite of the rule
above, so those two functions are never called directly. (C<DumpFile> and
C<LoadFile> B<are> character-level and are used unwrapped.)

=item * B<JSON> — L</json_encode> and L</json_decode>. The C<encode_json> and
C<decode_json> functions are octet-level for the same reason and are likewise
not used directly.

=back

=head2 Legacy boards

karr up to and including 0.402 mixed the two levels, and every board written by
those versions has UTF-8 octets encoded a second time in its task frontmatter,
its config, and its activity log. Task bodies are unaffected: they never passed
through C<Dump>. L</repair_mojibake> undoes exactly that second encoding, and
L<App::karr::Git/board_encoding_version> decides when to apply it — see
L<App::karr::Cmd::Repair> for the migration.

=head1 SEE ALSO

L<karr>, L<App::karr>, L<App::karr::Git>, L<App::karr::Task>,
L<App::karr::Cmd::Repair>

=cut

our @EXPORT_OK = qw(
  BOARD_ENCODING_VERSION
  decode_argv
  enable_std_utf8
  to_octets
  from_octets
  yaml_dump
  yaml_load
  json_encode
  json_decode
  repair_mojibake
);

=func BOARD_ENCODING_VERSION

The encoding contract version this code writes, stored per board in
C<refs/karr/meta/encoding>. A board without that ref predates the contract and
is read through L</repair_mojibake>.

=cut

use constant BOARD_ENCODING_VERSION => 2;

=func to_octets

  my $bytes = to_octets($characters);

Encodes a character string to UTF-8 octets. C<undef> passes through.

=cut

sub to_octets {
  my ($chars) = @_;
  return $chars unless defined $chars;
  return encode( 'UTF-8', $chars );
}

=func from_octets

  my $characters = from_octets($bytes);

Decodes UTF-8 octets to a character string. A payload that is not valid UTF-8
is returned B<unchanged> rather than being lossily substituted: karr ref blobs
and command-line arguments are UTF-8 by contract, and passing a non-conforming
payload through keeps the pre-0.403 byte-in/byte-out behaviour for it instead
of quietly replacing bytes with U+FFFD.

=cut

sub from_octets {
  my ($octets) = @_;
  return $octets unless defined $octets;
  my $chars = eval { decode( 'UTF-8', $octets, FB_CROAK | LEAVE_SRC ) };
  return defined $chars ? $chars : $octets;
}

=func decode_argv

  decode_argv();

Decodes C<@ARGV> in place from UTF-8. Arguments that are not valid UTF-8 are
left as they arrived.

=cut

sub decode_argv {
  $_ = from_octets($_) for @ARGV;
  return;
}

=func enable_std_utf8

  enable_std_utf8();

Puts a C<:encoding(UTF-8)> layer on C<STDOUT> and C<STDERR> so command bodies
can C<print> character strings.

C<STDIN> is deliberately left alone. Only L<App::karr::Cmd::Restore> reads it,
and it decodes its own payload, so a layer here would decode it twice.

=cut

sub enable_std_utf8 {
  binmode STDOUT, ':encoding(UTF-8)';
  binmode STDERR, ':encoding(UTF-8)';
  return;
}

=func yaml_dump

  my $characters = yaml_dump($data);

C<YAML::XS::Dump> at the character level.

=cut

sub yaml_dump {
  my (@data) = @_;
  return from_octets( YAML::XS::Dump(@data) );
}

=func yaml_load

  my $data = yaml_load($characters);

C<YAML::XS::Load> at the character level.

=cut

sub yaml_load {
  my ($chars) = @_;
  return YAML::XS::Load( to_octets($chars) );
}

# One codec for the process. utf8 => 0 is the whole point: the caller gets a
# character string back and the output layer encodes it once, at the edge.
my $JSON;

sub _json {
  return $JSON //= JSON::MaybeXS->new(
    utf8            => 0,
    canonical       => 1,
    convert_blessed => 1,
  );
}

=func json_encode

  my $characters = json_encode($data);

C<encode_json> at the character level, with C<canonical> key ordering so the
C<--json> payload an agent parses is byte-stable across runs.

=cut

sub json_encode {
  my ($data) = @_;
  return _json()->encode($data);
}

=func json_decode

  my $data = json_decode($characters);

C<decode_json> at the character level.

=cut

sub json_decode {
  my ($chars) = @_;
  return _json()->decode($chars);
}

=func repair_mojibake

  my $fixed = repair_mojibake($data);

Undoes one round of UTF-8 double encoding, walking hashes and arrays and
returning a fresh structure. Blessed references and hash keys are passed
through untouched.

A string is only rewritten when it cannot be anything but double-encoded:

=over 4

=item * pure ASCII is never touched, so an ASCII board is bit-identical
afterwards and the repair is safe to run over a whole board;

=item * a string containing a codepoint above U+00FF cannot be a byte string
misread as characters, so it is already correct and is left alone;

=item * what remains must additionally form valid UTF-8 when read back as
bytes. Ordinary Latin-1 text almost never does — C<"\x{fc}ber"> is C<fc 62>,
which is not valid UTF-8 — whereas C<"\x{c3}\x{bc}ber"> is C<c3 bc 65 72>,
which decodes to C<"\x{fc}ber">.

=back

The residual ambiguity is a string whose non-ASCII characters happen to spell
valid UTF-8, such as a literal C<"\x{c3}\x{a9}">. That is why the repair is
bounded to boards that predate C<refs/karr/meta/encoding> instead of running
forever.

=cut

sub repair_mojibake {
  my ($data) = @_;

  my $ref = ref $data;
  return { map { $_ => repair_mojibake( $data->{$_} ) } keys %$data }
    if $ref eq 'HASH';
  return [ map { repair_mojibake($_) } @$data ]
    if $ref eq 'ARRAY';
  return $data if $ref;
  return $data unless defined $data;

  return $data unless $data =~ /[^\x00-\x7F]/;   # ASCII: nothing to repair
  return $data if     $data =~ /[^\x00-\xFF]/;   # real characters: already right

  # LEAVE_SRC on both calls, and it is not cosmetic: with a CHECK argument and
  # without it, Encode consumes the source string in place. Omitting it here
  # emptied $data, so every string that reached the decode and failed it -- all
  # ordinary Latin-1 text -- came back as "" instead of unchanged.
  my $octets = eval { encode( 'ISO-8859-1', $data, FB_CROAK | LEAVE_SRC ) };
  return $data unless defined $octets;
  my $decoded = eval { decode( 'UTF-8', $octets, FB_CROAK | LEAVE_SRC ) };
  return defined $decoded ? $decoded : $data;
}

1;
