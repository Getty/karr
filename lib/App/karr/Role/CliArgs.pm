# ABSTRACT: Role providing option-aware CLI positional-argument parsing

package App::karr::Role::CliArgs;
our $VERSION = '0.501';
use Moo::Role;

=head1 DESCRIPTION

This role recovers the real positional arguments from the argv MooX::Cmd echoes
back into a command's C<execute()>. Because MooX::Options runs with protect_argv,
that argv still holds every original token -- option flags, the values they
consumed, and the positionals -- in their original order. C<positional_args>
subtracts the option tokens back out (using the consuming command's own
C<_options_data>) to yield the positionals, and C<check_positional_args> rejects
surplus positionals before a command does any work. A bare C<--> ends option
processing, so everything after it is a positional however option-shaped it
looks.

The same walk answers one question earlier in the run: C<normalize_option_argv>
respells the option flags in an argv with underscores, which F<bin/karr> does
before MooX::Cmd dispatches so that a dashed option name survives whatever
stands in front of it.

Command classes provide C<_options_data> and C<_options_config> via MooX::Options.

=cut

# Walk argv once and record what part each token plays: an option flag, the
# value an option consumed, the bare "--" separator, or a positional. Both
# readers below ask the same question of the same table, so it is answered in
# one place and filtered afterwards -- positional_args keeps the positionals,
# normalize_option_argv rewrites the flags.
#
# The walk exists to extract the real positional arguments from the argv
# MooX::Cmd echoes back into execute(). Because MooX::Options runs with
# protect_argv (its default), the array handed to execute() still holds every
# original token in order:
# recognised option flags, the values they consumed, and --opt=value forms
# included (e.g. `move --claim tester 1 in-progress` arrives verbatim as
# [--claim, tester, 1, in-progress]). This gives cobra-style freedom to place
# flags before, between, or after positionals -- we just have to subtract the
# option tokens back out.
#
# We do that by walking the argv against the command's own %{_options_data}:
# a dash token is an option; if that option takes a value (has a 'format') and
# is given in space form (no inline '='), it also swallows the following token
# as its value -- even a flag-shaped value like `--append-body --weird`.
# Everything not eaten as an option or an option value is a positional, in
# order. Option-name matching mirrors how the token reaches us: leading dashes
# stripped, '-' folded to '_' to hit the underscore keys in _options_data, plus
# a reverse map of short aliases (e.g. -a => append_body, -t => timestamp).
# A token that is not a full name falls through to _abbreviation_takes_value
# below, because an abbreviation of a value-taking option consumes its value
# just as the full spelling does (ticket #247).
#
# A bare "--" is the POSIX end-of-options separator: everything after it is a
# positional, however option-shaped it looks. Getopt::Long already honours it
# when parsing (so `karr create -- --json` never tries to parse --json as a
# flag), but protect_argv hands the ORIGINAL argv -- separator included -- back
# to execute(), so without this branch the walk below re-read the escaped tokens
# as options and dropped them, leaving no positional at all. That was ticket
# #72: an option-shaped title could only be passed via --title.
sub _classify_argv {
    my ($self, $args_ref) = @_;

    my %options_data = $self->_options_data;
    my %by_name;
    for my $name (keys %options_data) {
        $by_name{$name} = $options_data{$name};
        my $short = $options_data{$name}{short};
        next unless defined $short;
        $by_name{$_} = $options_data{$name} for split /\|/, $short;
    }

    my @classified;
    my @args = @$args_ref;
    while (@args) {
        my $arg = shift @args;
        if ($arg eq '--') {
            push @classified, [ $arg, 'separator' ];
            push @classified, map { [ $_, 'positional' ] } @args;
            last;
        }
        if ($arg =~ /^-/) {
            (my $name = $arg) =~ s/^-+//;        # drop leading dashes
            my $has_inline = $name =~ s/=.*//s;  # --opt=value carries its value
            $name =~ tr/-/_/;                    # match underscore keys
            my $data = $by_name{$name};
            my $takes_value =
                $data
                ? ( defined $data->{format} ? 1 : 0 )
                : $self->_abbreviation_takes_value( $name, \%options_data );
            push @classified, [ $arg, 'option' ];
            push @classified, [ shift(@args), 'value' ]
                if $takes_value && !$has_inline && @args;
            next;
        }
        push @classified, [ $arg, 'positional' ];
    }
    return @classified;
}

sub positional_args {
    my ($self, $args_ref) = @_;

    return map { $_->[0] }
        grep { $_->[1] eq 'positional' } $self->_classify_argv($args_ref);
}

=method positional_args

    my @positional = $self->positional_args($args_ref);

In a command class that composes this role, recovers the real positional
arguments from C<$args_ref> -- the argv MooX::Cmd echoes back into
C<execute()>, which under C<protect_argv> still holds every original token:
recognised option flags, the values they consumed, and the positionals, in
their original order. Returns the positionals only, in order, as plain
strings. An abbreviated option consumes its value exactly as its full
spelling does, so C<< karr edit 1 --prio high >> yields the same single
positional as C<< karr edit 1 --priority high >>; a dash-prefixed token that
abbreviates nothing consumes nothing (a genuine typo is already rejected
upstream by MooX::Options). A bare C<--> ends option processing, so every
token after it is returned as a positional however option-shaped it looks.
Never dies -- an argument list with no positionals returns an empty list.

=cut

# Spell every option flag in argv the way Getopt::Long will be told to expect
# it: underscores, not dashes. F<bin/karr> runs this over argv before MooX::Cmd
# dispatches, because MooX::Options cannot be relied on to do it for a flag that
# follows another flag (ticket #256).
#
# MooX::Options is what makes the dashed spelling work at all: nothing declares
# --claimed-by, the attribute is claimed_by, and
# MooX::Options::Role::_options_fix_argv (4.103, line 148) folds '-' to '_' in
# every option name it walks past before Getopt::Long is called. The walk misses
# exactly one position. Having recognised an option, it takes the next token as
# that option's value unconditionally (line 171-172, `defined $original_long_option
# && ( defined( my $arg_value = shift @ARGV ) )`) and re-emits it verbatim --
# no fold, no short-option split. For an option that really takes a value that
# is right and harmless. For a BOOLEAN the next token is the next flag, which
# therefore reaches Getopt::Long still dashed, under a name the generated
# specification does not have:
#
#     karr list --claimed-by NAME          works
#     karr list --json --claimed-by NAME   Unknown option: claimed-by   (exit 2)
#     karr list --not-blocked --compact    works
#     karr list --compact --not-blocked    Unknown option: not-blocked  (exit 2)
#
# Nothing is wrong with the second spelling of either pair; the flag in front of
# it is. All nineteen karr options whose attribute name has an underscore were
# reachable only in the orders that happen to avoid that position -- --add-tag,
# --append-body, --depends-on, --write-to, --show-no-board and fourteen more.
#
# The question asked here is the weaker one that #247 settled on: not what an
# option means, only whether it takes a value. Folding a flag's own dashes is
# always safe -- _options_fix_argv folds the very same characters one step later
# for every flag it does reach, so an unknown --bogus-opt still reports
# "Unknown option: bogus_opt" exactly as before -- and the thing that must NOT
# be folded is a value that merely looks like a flag (`karr edit 1 --body
# --we-ird` stores --we-ird). _classify_argv already separates those two, so
# this is a map over its answer and nothing more. A leading `no-` is left
# standing so that the negation prefix keeps reaching _options_fix_argv as
# such, for the day a karr option is declared negatable.
#
# This can go when _options_fix_argv puts the token it swallows through the same
# rewriting as the token it recognised -- i.e. when the MooX::Options this
# distribution requires no longer has the unconditional shift at line 171. 4.103
# is the current release and still does; nothing here needs to change if it is
# fixed, the fold simply becomes a second, identical fold.
sub normalize_option_argv {
    my ($self, $args_ref) = @_;

    return map { $_->[1] eq 'option' ? $self->_underscore_option_name($_->[0]) : $_->[0] }
        $self->_classify_argv($args_ref);
}

=method normalize_option_argv

    @ARGV = $class->normalize_option_argv(\@ARGV);

Returns C<$args_ref> with every long option flag in it respelled with
underscores -- C<--claimed-by> becomes C<--claimed_by> -- and everything else
returned untouched: positionals, short options, the values options consume,
and every token after a bare C<-->. Both spellings mean the same option to
karr, and this is the one that survives MooX::Options in every argv position
(ticket #256). It reads the option table and nothing else, so unlike the two
methods above it is called as a B<class> method, before any command object
exists: F<bin/karr> runs it over argv for the command class MooX::Cmd is about
to dispatch to.

=cut

sub _underscore_option_name {
    my ($self, $token) = @_;

    return $token unless $token =~ /\A--(no-)?([^=]*)(.*)\z/s;
    my ($negation, $name, $rest) = ($1, $2, $3);
    $name =~ tr/-/_/;
    return '--' . (defined $negation ? $negation : '') . $name . $rest;
}

# Does a dash token that is not a full option name consume the token after it?
#
# Before ticket #247 the answer was always no, on the reasoning that karr's
# abbreviatable flags consume nothing anyway. That was true once; --title,
# --priority, --body, --claim and --note have taken values for a long time, so
# `karr edit 1 --prio high` handed "high" to the positionals and
# check_positional_args then reported the caller's value as the surplus
# argument -- pointing at the value while the mistake sat in the abbreviation
# in front of it.
#
# The question deliberately answered here is weaker than "which option is
# this?", because karr must not carry a second implementation of anybody's
# abbreviation rules. Prefix resolution happens twice upstream and neither
# copy is ours: MooX::Options::Role::_options_fix_argv rewrites a prefix that
# matches exactly one option to its full name before Getopt::Long is called,
# and Getopt::Long resolves (or rejects, "Option ti is ambiguous (timestamp,
# title)") whatever is left. So by the time argv is echoed back into
# execute(), every abbreviation still present resolved to exactly one option
# and an ambiguous one exited 2 long before -- which means we only have to ask
# whether the options this token could possibly abbreviate agree about taking
# a value, never which of them won. Both engines match on a plain,
# case-sensitive prefix (--PRIORITY is "Unknown option" here), so a prefix test
# is the whole of it.
#
# No candidate at all is the unchanged non-consuming answer: an inline-value
# short (-anote, which MooX::Options splits itself), the --h/--help/--man/
# --usage family that describe_options adds outside %{_options_data}, or a
# typo, which was rejected upstream before it could reach us. Candidates that
# disagree cannot occur -- that is the ambiguous spelling, and it never got
# here -- and answer no, keeping the pre-#247 behaviour for a shape that would
# otherwise have no defined answer.
sub _abbreviation_takes_value {
    my ( $self, $name, $options_data ) = @_;

    my @candidates = grep { index( $_, $name ) == 0 } keys %$options_data;
    return 0 unless @candidates;

    my $takes_value = defined $options_data->{ $candidates[0] }{format} ? 1 : 0;
    for my $candidate (@candidates) {
        return 0
            if ( defined $options_data->{$candidate}{format} ? 1 : 0 ) != $takes_value;
    }
    return $takes_value;
}

# Reject surplus positional arguments before a command does any work, matching
# kanban-md's cobra Args validators (ExactArgs/RangeArgs/MaximumNArgs) which
# refuse extra positionals ahead of RunE. The comma list stays the one and only
# batch syntax; there is no space-separated id batch. Counting is done against
# positional_args (the real positionals with option tokens subtracted out), not
# a leading run of non-dash tokens, so `archive 1 --json 99` correctly rejects
# the trailing "99" instead of silently dropping it.
sub check_positional_args {
    my ($self, $args_ref, $max) = @_;

    my @positional = $self->positional_args($args_ref);
    return if @positional <= $max;

    my @extra   = @positional[$max .. $#positional];
    my %config  = $self->_options_config;
    my $usage   = $config{usage_string};

    die sprintf "unexpected extra argument%s: %s\n%s",
        (@extra == 1 ? '' : 's'),
        join(', ', map { "'$_'" } @extra),
        ($usage ? "$usage\n" : '');
}

=method check_positional_args

    $self->check_positional_args($args_ref, $max);

In a command class that composes this role, dies with a usage message
(C<"unexpected extra argument(s): '...'\n">, followed by the command's usage
string if it has one) when C<$args_ref> resolves to more than C<$max>
positionals via L</positional_args>; otherwise returns nothing. The message
starts with the C<unexpected extra argument> marker
L<App::karr::Error/is_usage_error> recognises, so F<bin/karr>'s central
handler exits C<2> (ADR 0002), not C<1>. There is no
minimum-arity check here -- a missing required positional is each command's
own concern -- this only rejects surplus. Call it before a command does any
work: kanban-md's cobra C<Args> validators run before C<RunE> the same way,
and karr's batch commands rely on the comma list (parsed by
L<App::karr::Role::BoardAccess/parse_ids>) as the one and only way to pass
more than one id, so a second bare positional is always a mistake rather than
an alternate batch syntax.

=cut

1;
