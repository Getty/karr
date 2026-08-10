# ABSTRACT: Board configuration management

package App::karr::Config;
our $VERSION = '0.403';
use Moo;
use YAML::XS qw( LoadFile DumpFile );
use JSON::MaybeXS qw( JSON );
use Path::Tiny;

=head1 SYNOPSIS

    my $config = App::karr::Config->new(
      file => path('/tmp/karr-materialized/config.yml'),
    );

    my @statuses = $config->statuses;

=head1 DESCRIPTION

L<App::karr::Config> wraps the board configuration file and centralises access
to derived values such as status names, priority order, and merged effective
defaults. It is used by command modules that need a structured view of the
materialized board config instead of working with raw YAML hashes. In the
ref-first architecture the canonical config lives in C<refs/karr/config>, while
this class works with the temporary YAML file generated for a command run.

=head1 SEE ALSO

L<karr>, L<App::karr>, L<App::karr::BoardStore>, L<App::karr::Task>,
L<App::karr::Git>

=cut

has file => ( is => 'ro', required => 1 );
has data => ( is => 'lazy' );

sub _build_data {
  my ($self) = @_;
  my $file = $self->file;
  return LoadFile($file->stringify) if defined $file && -f $file;
  die "No file or data provided to Config\n";
}

sub from_merged {
  my ($class, $merged) = @_;
  return bless { data => $merged, file => undef }, $class;
}

sub save {
  my ($self) = @_;
  DumpFile($self->file->stringify, $self->data);
}

# The three list accessors below tolerate a malformed board config instead of
# dying inside a dereference. `karr config show` has to stay able to print a
# broken board so it can be fixed, and L</validate> checks the list shape
# explicitly before it calls them, so nothing that should fail stops failing
# (ticket #78).
sub _list {
  my ( $self, $key ) = @_;
  my $value = $self->data->{$key};
  return ref $value eq 'ARRAY' ? @$value : ();
}

sub statuses {
  my ($self) = @_;
  return map {
    ref $_ ? $_->{name} : $_
  } $self->_list('statuses');
}

sub status_config {
  my ($self, $name) = @_;
  for my $s ($self->_list('statuses')) {
    if (ref $s) {
      return $s if $s->{name} eq $name;
    } elsif ($s eq $name) {
      return { name => $s };
    }
  }
  return undef;
}

sub priorities {
  my ($self) = @_;
  return ref $self->data->{priorities} eq 'ARRAY'
    ? @{ $self->data->{priorities} }
    : qw( low medium high critical );
}

sub classes {
  my ($self) = @_;
  return map {
    ref $_ ? $_->{name} : $_
  } $self->_list('classes');
}

=head2 classes

Returns the configured class-of-service names in board order, accepting both
the mapping form C<< { name => 'expedite', wip_limit => 1 } >> and a bare
string, the same way L</statuses> does.

    my @classes = $config->classes;

=cut

sub claim_timeout {
  my ($self) = @_;
  return $self->data->{claim_timeout} // '1h';
}

sub foundation_enabled {
  my ($self) = @_;
  my $f = $self->data->{foundation};
  return 1 unless ref $f eq 'HASH' && exists $f->{enabled};
  return $f->{enabled} ? 1 : 0;
}

=head2 foundation_enabled

Returns true when automated agent runs (L<App::karr::Foundation>) are allowed on
this board. The flag lives in the board config under C<foundation.enabled> and
therefore travels with C<refs/karr/config>; a board that never set it is
enabled.

    if ($config->foundation_enabled) {
        # karr-foundation may drain this board
    }

=cut

sub foundation_reason {
  my ($self) = @_;
  my $f = $self->data->{foundation};
  return undef unless ref $f eq 'HASH';
  my $reason = $f->{reason};
  return ( defined $reason && length $reason ) ? $reason : undef;
}

=head2 foundation_reason

Returns the free-text reason recorded alongside C<foundation.enabled>, or undef
when none was given. Only meaningful while the board is disabled.

    my $why = $config->foundation_reason;

=cut

sub parse_bool {
  my ($class, $value) = @_;
  die "Missing boolean value\n" unless defined $value;
  my $v = lc $value;
  $v =~ s/^\s+//;
  $v =~ s/\s+$//;
  return 1 if $v =~ /^(?:1|true|yes|on)$/;
  return 0 if $v =~ /^(?:0|false|no|off)$/;
  die "Invalid boolean: $value (use true/false, yes/no, on/off, 1/0)\n";
}

=head2 parse_bool

Coerces a CLI-supplied boolean string to C<1> or C<0>, dying on anything else.
Needed because a bare C<"false"> from the command line is true in Perl.

    my $bool = App::karr::Config->parse_bool('false');   # 0

=cut

# Go's time.ParseDuration grammar, which is what kanban-md's claim_timeout is
# written in: an optional sign, then one or more decimal-number-plus-unit
# groups. Note there is no day unit -- "7d" is an error in Go too.
my %DURATION_UNIT = (
  ns    => 1e-9,
  us    => 1e-6,
  "\x{b5}s" => 1e-6,   # micro sign
  "\x{3bc}s" => 1e-6,  # greek small letter mu
  ms    => 1e-3,
  s     => 1,
  m     => 60,
  h     => 3600,
);

sub parse_duration {
  my ($class, $str) = @_;
  return undef unless defined $str && length $str;

  my $sign = 1;
  $sign = -1 if $str =~ s/\A-//;
  $str =~ s/\A\+//;

  # Go accepts a bare "0" (and only "0") without a unit.
  return 0 if $str =~ /\A0+\z/;

  my $seconds = 0;
  my $matched = 0;
  while ( length $str ) {
    $str =~ s/\A([0-9]*\.?[0-9]+)// or return undef;
    my $value = $1;
    return undef if $value eq '.';
    $str =~ s/\A(ns|us|\x{b5}s|\x{3bc}s|ms|s|m|h)// or return undef;
    $seconds += $value * $DURATION_UNIT{$1};
    $matched++;
  }
  return undef unless $matched;
  return $sign * $seconds;
}

=head2 parse_duration

Parses a Go C<time.ParseDuration> string into seconds, returning C<undef> when
it is not a duration at all. kanban-md writes C<claim_timeout> in that grammar,
so a compound value such as C<1h30m> has to mean ninety minutes on both sides
of the interop boundary (ticket #78).

    my $secs = App::karr::Config->parse_duration('1h30m');   # 5400
    my $secs = App::karr::Config->parse_duration('7d');      # undef -- no day unit

=cut

# Every rejection here is a usage error (ADR 0002), so it carries the same
# "Usage error:" marker L<App::karr::Role::ExitCodes/usage_error> emits and
# F<bin/karr> maps to exit 2. These are plain class/instance methods rather than
# calls to that role's method because App::karr::Config is not a command and
# does not consume it -- the marker is the contract, not the caller.
sub _usage_error {
  my ($field, $value, $detail) = @_;
  die sprintf "Usage error: invalid %s %s (%s)\n",
    $field, defined $value ? qq{"$value"} : '(none)', $detail;
}

sub validate_status {
  my ($self, $value) = @_;
  my @statuses = $self->statuses;
  return $value if defined $value && grep { $_ eq $value } @statuses;
  _usage_error( 'status', $value, 'valid: ' . join(', ', @statuses) );
}

=head2 validate_status

Dies unless the value is one of the board's configured statuses, returning the
value otherwise so it can be used inline.

    $task->status( $config->validate_status($wanted) );

=cut

sub validate_priority {
  my ($self, $value) = @_;
  my @priorities = $self->priorities;
  return $value if defined $value && grep { $_ eq $value } @priorities;
  _usage_error( 'priority', $value, 'valid: ' . join(', ', @priorities) );
}

=head2 validate_priority

Dies unless the value is one of the board's configured priorities.

=cut

sub validate_class {
  my ($self, $value) = @_;
  my @classes = $self->classes;
  return $value if defined $value && grep { $_ eq $value } @classes;
  _usage_error( 'class', $value, 'valid: ' . join(', ', @classes) );
}

=head2 validate_class

Dies unless the value is one of the board's configured classes of service.

=cut

sub validate_due {
  my ($class, $value) = @_;
  _usage_error( 'due date', $value, 'expected YYYY-MM-DD' )
    unless defined $value && $value =~ /\A(\d{4})-(\d{2})-(\d{2})\z/;
  my ( $y, $m, $d ) = ( $1, $2, $3 );
  # Calendar-correct, not just well-shaped: Go's time.Parse rejects 2026-02-30
  # and so must karr, or the date sorts fine and means nothing.
  _usage_error( 'due date', $value, 'expected YYYY-MM-DD' )
    unless $m >= 1
    && $m <= 12
    && $d >= 1
    && $d <= _days_in_month( $y, $m );
  return $value;
}

=head2 validate_due

Dies unless the value is a real calendar date in C<YYYY-MM-DD>, the only form
kanban-md's C<date.Date> accepts.

    App::karr::Config->validate_due('2026-02-30');   # dies

=cut

sub _days_in_month {
  my ( $year, $month ) = @_;
  my @days = ( 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 );
  return 29 if $month == 2 && ( $year % 4 == 0 && ( $year % 100 != 0 || $year % 400 == 0 ) );
  return $days[ $month - 1 ];
}

sub validate {
  my ( $class, $data ) = @_;
  die "Board config is invalid: not a mapping\n" unless ref $data eq 'HASH';

  my $config = $class->from_merged($data);

  die "Board config is invalid: board.name is required\n"
    unless ref $data->{board} eq 'HASH'
    && defined $data->{board}{name}
    && length $data->{board}{name};
  die "Board config is invalid: tasks_dir is required\n"
    unless defined $data->{tasks_dir} && length $data->{tasks_dir};

  die "Board config is invalid: statuses must be a list\n"
    unless ref $data->{statuses} eq 'ARRAY';
  my @statuses = $config->statuses;
  die "Board config is invalid: at least 2 statuses are required\n"
    unless @statuses >= 2;
  die "Board config is invalid: every status needs a name\n"
    if grep { !defined || !length } @statuses;
  die "Board config is invalid: statuses contain duplicates\n"
    if _has_duplicates(@statuses);

  die "Board config is invalid: priorities must be a list\n"
    unless ref $data->{priorities} eq 'ARRAY';
  my @priorities = $config->priorities;
  die "Board config is invalid: at least 1 priority is required\n"
    unless @priorities >= 1;
  die "Board config is invalid: priorities contain duplicates\n"
    if _has_duplicates(@priorities);

  if ( defined $data->{classes} ) {
    die "Board config is invalid: classes must be a list\n"
      unless ref $data->{classes} eq 'ARRAY';
    my @classes = $config->classes;
    die "Board config is invalid: every class needs a name\n"
      if grep { !defined || !length } @classes;
    die "Board config is invalid: classes contain duplicates\n"
      if _has_duplicates(@classes);
    for my $c ( @{ $data->{classes} } ) {
      next unless ref $c eq 'HASH' && defined $c->{wip_limit};
      die "Board config is invalid: class $c->{name} wip_limit must be >= 0\n"
        unless $c->{wip_limit} =~ /\A\d+\z/;
    }
  }

  my $defaults = $data->{defaults} // {};
  die "Board config is invalid: defaults must be a mapping\n"
    unless ref $defaults eq 'HASH';
  for my $spec (
    [ status   => \@statuses   ],
    [ priority => \@priorities ],
    ) {
    my ( $key, $allowed ) = @$spec;
    my $value = $defaults->{$key};
    next unless defined $value;
    die "Board config is invalid: defaults.$key $value is not in the $key list\n"
      unless grep { $_ eq $value } @$allowed;
  }
  if ( defined $defaults->{class} && length $defaults->{class} ) {
    my @classes = $config->classes;
    die "Board config is invalid: defaults.class $defaults->{class} is not in the classes list\n"
      if @classes && !grep { $_ eq $defaults->{class} } @classes;
  }

  if ( defined $data->{claim_timeout} && length $data->{claim_timeout} ) {
    die "Board config is invalid: claim_timeout $data->{claim_timeout} is not a duration\n"
      unless defined $class->parse_duration( $data->{claim_timeout} );
  }

  return 1;
}

=head2 validate

Checks a fully merged board config and dies with a C<Board config is invalid:>
message on the first problem, mirroring kanban-md's C<Config.Validate>. Only the
parts karr actually models are checked -- karr keeps C<next_id> in a ref rather
than in the config, has no WIP limits or TUI section yet, and uses its own
C<version> numbering, so those three checks are deliberately absent.

Called from L<App::karr::BoardStore/save_config>, which is the single write
choke point for C<refs/karr/config>, so C<karr config set>, C<karr import> and
C<karr disable> all reject a broken schema instead of writing it (ticket #78).
It is B<not> called on the read path: a board that is already broken has to stay
loadable, or it could not be repaired with karr itself.

    App::karr::Config->validate( $store->load_config );

=cut

sub _has_duplicates {
  my %seen;
  return scalar grep { $seen{$_}++ } @_;
}

sub priority_order {
  my ($class) = @_;
  return (critical => 0, high => 1, medium => 2, low => 3);
}

=head2 priority_order

Returns a hash for sorting tasks by priority.

    my %order = App::karr::Config->priority_order;
    # (critical => 0, high => 1, medium => 2, low => 3)

=cut

sub class_order {
  my ($class) = @_;
  return (expedite => 0, 'fixed-date' => 1, standard => 2, intangible => 3);
}

=head2 class_order

Returns a hash for sorting tasks by class of service.

    my %order = App::karr::Config->class_order;
    # (expedite => 0, 'fixed-date' => 1, standard => 2, intangible => 3)

=cut

sub is_terminal_status {
  my ($class, $status) = @_;
  return 1 if $status eq 'done' || $status eq 'archived';
  return 0;
}

=head2 is_terminal_status

Returns true if the given status is terminal (done or archived).

    if (App::karr::Config->is_terminal_status($task->status)) {
        # task is in a terminal state
    }

=cut

sub terminal_statuses {
  my ($class) = @_;
  return ('done', 'archived');
}

=head2 terminal_statuses

Returns a list of terminal status names.

    my @terminal = App::karr::Config->terminal_statuses;

=cut

sub status_requires_claim {
  my ($self, $status_name) = @_;
  my ($sc) = grep {
    (ref $_ ? $_->{name} : $_) eq $status_name
  } $self->_list('statuses');
  return 0 unless $sc;
  return 0 if !ref $sc;
  return $sc->{require_claim} ? 1 : 0;
}

sub effective_config {
  my ($class, $overrides, %args) = @_;
  my $defaults = $class->default_config(%args);
  return _merge_hashes($defaults, $overrides // {});
}

sub default_config {
  my ($class, %args) = @_;
  return {
    version => 1,
    board => {
      name => $args{name} // 'Kanban Board',
    },
    tasks_dir => 'tasks',
    statuses => [
      'backlog',
      'todo',
      { name => 'in-progress', require_claim => 1 },
      { name => 'review', require_claim => 1 },
      'done',
      'archived',
    ],
    priorities => [qw( low medium high critical )],
    classes => [
      { name => 'expedite', wip_limit => 1, bypass_column_wip => 1 },
      { name => 'fixed-date' },
      { name => 'standard' },
      { name => 'intangible' },
    ],
    claim_timeout => '1h',
    # Deliberately not claim_timeout. A claim says "an agent owns this work"
    # and has to outlive a whole session; a lock only covers the few
    # milliseconds `karr pick` spends deciding on and writing one card, and it
    # is the thing an agent that dies mid-pick leaves behind. Reusing the 1h
    # claim window here would leave that task unpickable for an hour (#45).
    # Accepts Nh / Nm / Ns; an explicit zero (`0s`) disables lock expiry.
    lock_timeout => '5m',
    # Board-level switch for automated agent runs (karr-foundation). Boards are
    # enabled by default; `karr disable` writes enabled => 0 (plus an optional
    # reason) into refs/karr/config so the opt-out syncs with the board.
    foundation => {
      enabled => 1,
    },
    defaults => {
      status   => 'backlog',
      priority => 'medium',
      class    => 'standard',
    },
  };
}

# The config keys kanban-md's Go schema types as `bool`
# (internal/config/config.go): StatusConfig.RequireClaim / .ShowDuration,
# ClassConfig.BypassColumnWIP, TUIConfig.HideEmptyColumns -- plus karr's own
# foundation.enabled, which kanban-md ignores but which is a boolean all the
# same. Listed here, next to default_config, so the two stay in step.
my %BOOLEAN_KEY = map { $_ => 1 }
  qw( require_claim show_duration bypass_column_wip hide_empty_columns enabled );

sub file_view_config {
  my ($class, $effective, %args) = @_;
  my $view = _booleanize($effective);
  # kanban-md validates next_id >= 1 and refuses a config without it. karr keeps
  # the counter in refs/karr/meta/next-id instead, so materialize copies it into
  # the view; import drops it again and leaves the ref authoritative.
  my $next_id = $args{next_id};
  $view->{next_id} = ( defined $next_id && $next_id >= 1 ) ? $next_id : 1;
  return $view;
}

=head2 file_view_config

Returns the effective config reshaped for the materialized kanban-md file view:
boolean-typed keys become real YAML booleans instead of Perl's C<1>/C<0>, and
C<next_id> is filled in from the C<next_id> argument. Both are load-bearing --
go-yaml refuses to unmarshal C<1> into a C<bool> and kanban-md rejects a config
whose C<next_id> is below C<1>, so without either the whole board is unreadable
to kanban-md (ticket #60). The caller has to dump it under
C<local $YAML::XS::Boolean = 'JSON::PP'> for the booleans to survive.

    my $view = App::karr::Config->file_view_config( $effective, next_id => 7 );

=cut

sub _booleanize {
  my ($data, $key) = @_;
  my $ref = ref $data;
  return { map { $_ => _booleanize( $data->{$_}, $_ ) } keys %$data } if $ref eq 'HASH';
  # No key is passed down into array elements: boolean keys only ever name a
  # hash value, and a list member is a status/class hash or a plain string.
  return [ map { _booleanize($_) } @$data ] if $ref eq 'ARRAY';
  return $data if $ref;
  return $data unless defined $key && $BOOLEAN_KEY{$key};
  return $data unless defined $data;
  return $data ? JSON->true : JSON->false;
}

sub _merge_hashes {
  my ($left, $right) = @_;
  my %merged = %{$left // {}};
  for my $key (keys %{$right // {}}) {
    if (ref($merged{$key}) eq 'HASH' && ref($right->{$key}) eq 'HASH') {
      $merged{$key} = _merge_hashes($merged{$key}, $right->{$key});
    } else {
      $merged{$key} = $right->{$key};
    }
  }
  return \%merged;
}

1;
