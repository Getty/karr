# ABSTRACT: Role providing the --compact output option

package App::karr::Role::CompactOutput;
our $VERSION = '0.601';
use Moo::Role;
use MooX::Options;

=head1 DESCRIPTION

Declares C<--compact>, the terse plaintext rendering, for the commands that
actually render one. It is composed by exactly nine commands: C<board>,
C<config>, C<context>, C<dashboard>, C<list>, C<log>, C<metrics>, C<pick> and
C<show>.

C<--compact> used to sit beside C<--json> in L<App::karr::Role::Output>, which
every command with an alternate rendering composes, so all twenty-two of them
advertised C<--compact: Compact output> in C<--help> while only a handful read
the option. On the other thirteen it was accepted and silently thrown away, and
an option that is documented, accepted and then ignored is an answer that looks
like obedience (#254 has the census; #225 and #226 are the same failure on other
options). Splitting the option out of that role is what makes
C<karr move 1 done --compact> answer C<Unknown option: compact> with the usage
and exit C<2>, which is the loud refusal the exit-code contract (ADR 0002) asks
for.

C<--json> stays in L<App::karr::Role::Output> and keeps its own consumers: the
two options are separate questions, and a command may well answer one and not
the other. Where both are composed, C<--json> wins -- the machine-readable
rendering is a payload, not a layout, so it is never reshaped by C<--compact>.

=cut

option compact => (
  is => 'ro',
  doc => 'Compact output',
);

1;
