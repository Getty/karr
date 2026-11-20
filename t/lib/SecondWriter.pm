package SecondWriter;
use strict;
use warnings;

# Loaded with PERL5OPT=-MSecondWriter into one karr process (k333, review
# finding R1): right before take_back_journal runs, a "second writer" appends
# a line to every journalled ref whose name matches KARR_SECOND_WRITER_REFS
# (default: the card data refs), without the journal noticing -- so the
# take-back finds the ref no longer holding this process's own write and must
# report it as left. KARR_SECOND_WRITER_MODE=throw makes the reset / delete of
# those refs throw instead, the other way a ref ends up left.
#
# Only the take-back of a push that failed is touched; nothing else here
# differs from a plain karr run.

use App::karr::Git;

my $RE = defined $ENV{KARR_SECOND_WRITER_REFS} ? qr/$ENV{KARR_SECOND_WRITER_REFS}/ : qr{/tasks/\d+/data\z};

my $orig = \&App::karr::Git::take_back_journal;
no warnings 'redefine';
*App::karr::Git::take_back_journal = sub {
    my ( $self, @rest ) = @_;
    my @hit = grep { $_ =~ $RE } keys %{ $self->{_journal} || {} };
    if ( ( $ENV{KARR_SECOND_WRITER_MODE} // '' ) eq 'throw' ) {
        my $repo = $self->_repo;
        return $orig->( $self, @rest ) unless $repo && @hit;
        my $rclass   = ref $repo;
        my $refclass = ref $repo->reference( $hit[0] );
        my $o_create = $rclass->can('reference_create');
        my $o_delete = $refclass->can('delete');
        no strict 'refs';
        local *{"${rclass}::reference_create"} = sub {
            die "simulated reset failure\n" if $_[1] =~ $RE;
            goto &$o_create;
        };
        local *{"${refclass}::delete"} = sub {
            die "simulated delete failure\n" if $_[0]->name =~ $RE;
            goto &$o_delete;
        };
        return $orig->( $self, @rest );
    }
    {
        local $self->{_journal_paused} = 1;
        for my $ref (@hit) {
            $self->write_ref( $ref, $self->read_ref($ref) . "\nsecond writer\n" );
        }
    }
    return $orig->( $self, @rest );
};

1;
