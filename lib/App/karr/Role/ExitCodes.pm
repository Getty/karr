# ABSTRACT: Normalize MooX::Options option-parse errors to exit code 2 (ADR 0002)

package App::karr::Role::ExitCodes;
our $VERSION = '0.403';
use Moo::Role;

=head1 DESCRIPTION

Part of karr's exit-code contract (ADR 0002): C<0> success, C<1> runtime
failure, C<2> usage error.

MooX::Options handles an option-parse failure -- an unknown option, an invalid
option value, or a missing required option -- by printing a diagnostic and then
calling C<< $class->options_usage($code) >> with a positive C<$code>, which
C<exit>s that code. Historically that code was C<1>, which collided with genuine
runtime failures. Those are B<usage> errors, so this role wraps C<options_usage>
to force any positive (error) code to C<2>.

Help requests (C<-h>, C<--help>, C<--usage>) reach C<options_usage> with a code
of C<0> (or undef), so they are left untouched: they still print to STDOUT and
exit C<0>.

The complementary half of the contract -- catching the uncaught C<die>s raised
by command bodies and classifying them into runtime (C<1>) versus usage (C<2>)
-- lives in the central handler in F<bin/karr>. The root command's own
option-parse errors go through its C<_print_help> override instead of this role,
and that override applies the same positive-to-C<2> remap.

=cut

around options_usage => sub {
    my ($orig, $self, $code, @rest) = @_;
    $code = 2 if defined $code && $code > 0;
    return $orig->($self, $code, @rest);
};

1;
