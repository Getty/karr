# ABSTRACT: Generate a random two-word agent name

package App::karr::Cmd::AgentName;
our $VERSION = '0.601';
use Moo;
use MooX::Cmd;
use MooX::Options (
  usage_string => 'USAGE: karr agentname',
);
use App::karr::Role::CliArgs;
use App::karr::Role::ExitCodes;
use App::karr::Role::Output;

# Unknown option / bad option value exits 2, not 1 (ADR 0002 exit-code
# contract). This board-less command has no BoardDiscovery to inherit it from.
with 'App::karr::Role::CliArgs';
with 'App::karr::Role::ExitCodes';
with 'App::karr::Role::Output';

=head1 SYNOPSIS

    karr agentname

    # Capture the name once, then pass the same variable to every call that
    # has to agree about the claim:
    NAME=$(karr agentname)
    karr pick --claim "$NAME" --move in-progress
    karr handoff 7 --claim "$NAME" --note "Implementation complete"

=head1 DESCRIPTION

Generates a random two-word, lowercase agent name joined by a hyphen. The
command prefers the system dictionary when available and falls back to the
built-in word list otherwise.

Every call mints a new name. Nothing is remembered between calls -- not per
board, not per process, not per agent -- so C<$(karr agentname)> written twice
produces two unrelated names.

That matters because claims are compared by name. C<--claim> on
L<App::karr::Cmd::Pick> and L<App::karr::Cmd::Move> records the name;
L<App::karr::Cmd::Move>, L<App::karr::Cmd::Edit> and
L<App::karr::Cmd::Handoff> check the name they are handed against the one on
the card (L<App::karr::Role::ClaimTimeout/check_claim>); and C<karr list
--claimed-by> and C<karr log --agent> select on it. So this pair

    karr pick --claim "$(karr agentname)" --move in-progress    # DON'T
    karr handoff 7 --claim "$(karr agentname)"                  # DON'T

claims under one name and hands off under another. Substituting the command
inline is only ever correct where the name is used once and never referred to
again -- which is almost never, since the handoff at the end of the work is a
second reference. Capture it into a shell variable instead, as the SYNOPSIS
does (ticket #176).

A name that was not captured is still recoverable from the board rather than
lost: C<karr pick> prints C<(claimed by NAME)>, C<karr show ID> prints
C<Claimed:>, and the refusal C<check_claim> raises names the current claimant.
Minting a fresh one instead is the mistake. While the original claim is live
the mismatch is refused outright; once it has expired the mutation goes
through and re-stamps the card, but no longer without saying so -- the
override is reported with the name it stepped over
(L<App::karr::Role::ClaimTimeout/expired_claim_report>), which is the same
name to go back to.

The generated name is deliberately not made stable per agent. Any handle that
would survive across separate C<karr> processes -- the board, the Git
identity, the host -- is equally shared by every other agent working that same
board, so deriving a name from one would hand two concurrent agents an
identical claim. That is strictly worse than the mismatch it would fix: a
mismatch is refused by C<check_claim>, a collision is indistinguishable from
the rightful owner and is not. Callers that need a stable identity should
supply their own name and not go through this command, which exists to suggest
a name, not to remember one.

=head1 OPTIONS

=over 4

=item * C<--json>

Emit the generated name as one JSON object -- C<{"name":"..."}> -- and nothing
else on stdout, so a caller can capture the name without trimming a trailing
newline.

=back

=head1 SEE ALSO

L<karr>, L<App::karr>, L<App::karr::Cmd::Pick>, L<App::karr::Cmd::Handoff>,
L<App::karr::Cmd::Log>, L<App::karr::Role::ClaimTimeout>

=cut

sub execute {
  my ($self, $args_ref, $chain_ref) = @_;

  my @words = $self->_load_words;
  my $name = $words[rand @words] . '-' . $words[rand @words];
  if ($self->json) {
    $self->print_json( { name => $name } );
  } else {
    print "$name\n";
  }
}

sub _load_words {
  my ($self) = @_;
  my @words;

  # Try system dictionary first
  if (-r '/usr/share/dict/words') {
    open my $fh, '<', '/usr/share/dict/words' or last;
    while (<$fh>) {
      chomp;
      push @words, lc $_ if /^[a-z]{4,8}$/i;
    }
    close $fh;
  }

  # Fallback word list
  unless (@words) {
    @words = qw(
      able acid aged also area army away baby back ball band bank base bath
      bear beat been bell best bill bird bite blow blue boat body bomb bond
      bone book born boss bulk burn busy cake call calm came camp card care
      cash cast cell chat chip city claim clan clay clip club coal coat code
      coin cold come cook cool cope copy core cost crew crop dark data date
      dawn dead deal dear debt deep deny desk diet dirt disc disk dock does
      done door dose down draw drew drop drug dual duke dull dust duty each
      earn ease east easy edge else even ever evil exam exec face fact fail
      fair fall fame farm fast fate fear feed feel fell file fill film find
      fine fire firm fish five flat fled flew flip flow fold folk fond font
      food foot ford form fort four free from fuel full fund gain game gang
      gate gave gear gift girl give glad goal goes gold golf gone good grab
      gray grew grid grip grow gulf guru hack half hall hand hang harm hate
      have head hear heat held help herb here hero high hill hint hire hold
      hole holy home hope host hour huge hung hunt hurt idea inch into iron
      item jack jean jobs join joke jump jury just keen keep kept kick kill
      kind king knew knit know lack laid lake lamp land lane last late lawn
      lead lean left lend less life lift like limb line link lion list live
      load loan lock logo long look lord lose loss lost lots love luck made
      mail main make male many mark mass mate meal mean meat meet menu mere
      mild mile milk mind mine miss mode mood moon more most move much must
      myth name navy near neat neck need nest next nice nine none norm nose
      note odds once only onto open oral ours pace pack page paid pain pair
      pale palm park part pass past path peak pick pile pine pink pipe plan
      play plot plug plus poem poet poll pond pool poor port post pour pray
      pull pump pure push quit race rain rank rare rate read real rear rely
      rent rest rice rich ride ring rise risk road rock rode role roll roof
      room root rope rose ruin rule rush safe said sake sale salt same sand
      sang save seal seat seed seek seem seen self send sept ship shop shot
      show shut sick side sign silk site size skin slim slip slow snap snow
      soft soil sold sole some song soon sort soul spin spot star stay stem
      step stop such suit sure swim tail take tale talk tall tank tape task
      taxi team teen tell tend term test text than that them then they thin
      this thus tide tied till time tiny told toll tone took tool tops toss
      tour town trap tree trim trio trip true tube tuck tune turn twin type
      ugly unit upon urge used user vale vast very vice view vote wage wait
      wake walk wall want ward warm wash vast wave weak wear week went were
      west what whom wide wife wild will wind wine wing wire wise wish with
      wood word wore work worn wrap yard yeah year zero zone
    );
  }

  return @words;
}

1;
