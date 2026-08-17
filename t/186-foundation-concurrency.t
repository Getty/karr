use strict;
use warnings;
use Test::More;
use lib 't/lib';
use TestGit qw( require_git_c );
require_git_c();
use Path::Tiny qw( tempdir );
use POSIX ();

use App::karr::Foundation;
use App::karr::Foundation::Limits;
use App::karr::Foundation::ChainStore;
use App::karr::Git;

# Ticket #186, work package 2 of the fleet-execution epic (#194). The runner
# executed one command after another, so every concurrency setting in the
# design was decoration. What is pinned here:
#
#   1. Three levels, tightest wins: the machine ceiling from the local config,
#      the operator's per-agent estimate on an agent definition, and the limits
#      a particular run declares in its chain header.
#   2. The default is still one board at a time. Concurrency is opt-in, like
#      agent execution itself -- a default that quietly started four agents on
#      somebody's laptop would arrive on a machine rather than in a review.
#   3. One agent per repository, whatever knocks. .karr.lock is per repo and
#      stays that way; concurrency is across repositories, never inside one.
#   4. agents.state is shared by every board on the machine, so its
#      read-modify-write is serialised now that several of them run at once
#      (the note #188 left for this ticket).
#   5. The chain header is read AFTER refs/karr-foundation/* has been pulled,
#      or a tick decides from a plan somebody has already replaced (the note
#      #190 left for this ticket).

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

sub foundation_with {
  my ( %cfg ) = @_;
  return App::karr::Foundation->new( _config_data => \%cfg, _chain_store => undef );
}

# Limits holds its foundation weakly (as every other collaborator does -- the
# foundation owns them), so the test has to hold the other end itself.
my @KEEP_ALIVE;
sub limits_with {
  my ( $cfg, %args ) = @_;
  my $f = foundation_with( %$cfg );
  push @KEEP_ALIVE, $f;
  return App::karr::Foundation::Limits->new( foundation => $f, %args );
}

# A fake agent that records how many copies of itself were alive at once. Every
# invocation bumps a counter under its own flock, holds for a moment, and bumps
# it back down, keeping the running maximum per bucket. Serial execution can
# never push a maximum above 1; that is the whole proof.
sub write_counting_agent {
  my ( $dir ) = @_;
  my $script = $dir->child('counting-agent.pl');
  $script->spew_utf8(<<'PERL');
use strict;
use warnings;
use Fcntl qw( :flock );

my $file   = $ENV{KARR_CONC_FILE} or die "no KARR_CONC_FILE\n";
my $bucket = shift @ARGV // 'any';
my $hold   = $ENV{KARR_CONC_HOLD} // 0.4;

bump( $_, 1 )  for ( $bucket, 'TOTAL' );
select undef, undef, undef, $hold;
bump( $_, -1 ) for ( $bucket, 'TOTAL' );
exit 0;

sub bump {
  my ( $key, $delta ) = @_;
  open my $lk, '>>', "$file.lock" or die "lock: $!";
  flock $lk, LOCK_EX or die "flock: $!";
  my %n;
  if ( -e $file ) {
    open my $r, '<', $file or die "read: $!";
    while ( my $line = <$r> ) {
      chomp $line;
      my ( $k, $live, $max ) = split /\s+/, $line;
      $n{$k} = [ $live, $max ] if defined $k;
    }
    close $r;
  }
  my $rec = $n{$key} ||= [ 0, 0 ];
  $rec->[0] += $delta;
  $rec->[1] = $rec->[0] if $rec->[0] > $rec->[1];
  open my $w, '>', $file or die "write: $!";
  print {$w} "$_ $n{$_}[0] $n{$_}[1]\n" for sort keys %n;
  close $w;
  close $lk;
}
PERL
  return $script;
}

sub peak {
  my ( $file, $bucket ) = @_;
  return 0 unless $file->exists;
  for my $line ( split /\n/, $file->slurp_utf8 ) {
    my ( $k, $live, $max ) = split /\s+/, $line;
    return $max + 0 if defined $k && $k eq $bucket;
  }
  return 0;
}

# N boards, each a plain directory with a .karr file, plus a config file. The
# boards need no git repository: _process_repo skips the pull and the board
# reads when there is none, and --force takes it into the drain regardless,
# which is exactly the part under test here.
sub build_fleet {
  my ( %opt ) = @_;
  my $work    = tempdir( CLEANUP => 1 );
  my $script  = write_counting_agent( $work );
  my $counter = $work->child('conc.txt');

  my @dirs;
  for my $spec ( @{ $opt{boards} } ) {
    my $dir = $work->child( $spec->{name} );
    $dir->mkpath;
    my $karr = "drain: false\n";
    $karr .= defined $spec->{agent}
      ? "agent: $spec->{agent}\n"
      : qq{command: $^X "$script" any\n};
    $dir->child('.karr')->spew_utf8( $karr );
    push @dirs, $dir;
  }

  my $body = "dirs:\n" . join( '', map { "  - $_\n" } @dirs );
  $body .= "concurrent: $opt{concurrent}\n" if defined $opt{concurrent};
  $body .= "hub: $opt{hub}\n"               if defined $opt{hub};
  if ( my $agents = $opt{agents} ) {
    $body .= "agents:\n";
    for my $name ( sort keys %$agents ) {
      $body .= "  $name:\n";
      $body .= qq{    command: $^X "$script" $name\n};
      $body .= "    concurrent: $agents->{$name}\n" if $agents->{$name};
    }
  }
  my $cfg = $work->child('config.yml');
  $cfg->spew_utf8( $body );

  return ( $work, $cfg, $counter );
}

sub run_fleet {
  my ( $cfg, $counter, %opt ) = @_;
  local $ENV{KARR_CONC_FILE} = "$counter";
  local $ENV{KARR_CONC_HOLD} = $opt{hold} // 0.4;
  my @warned;
  my $exit = do {
    local $SIG{__WARN__} = sub { push @warned, $_[0] };
    App::karr::Foundation->new( config => "$cfg", force => 1 )->run;
  };
  return ( $exit, \@warned );
}

# ---------------------------------------------------------------------------
# The three levels
# ---------------------------------------------------------------------------

subtest 'level 1: the machine ceiling, and its default of one' => sub {
  is limits_with( {} )->concurrent, 1,
    'a foundation configured with nothing at all is the serial runner it '
    . 'has always been';
  is limits_with( { concurrent => 4 } )->concurrent, 4,
    'concurrent: raises the ceiling';
  is limits_with( { concurrent => '3' } )->concurrent, 3,
    'a YAML string of digits is a count';
};

subtest 'level 3: the chain header can only tighten' => sub {
  is limits_with( { concurrent => 4 }, chain_limits => { concurrent => 2 } )
    ->concurrent, 2, 'a chain asking for less than the machine gets less';
  is limits_with( { concurrent => 4 }, chain_limits => { concurrent => 8 } )
    ->concurrent, 4,
    'a chain asking for more than the machine still gets the machine: the '
    . 'ceiling protects this box and is not up for negotiation';
  is limits_with( { concurrent => 4 }, chain_limits => {} )->concurrent, 4,
    'a chain with no limits block leaves the ceiling alone';
};

subtest 'level 2 and 3: per-agent, tightest wins' => sub {
  my $cfg = {
    concurrent => 8,
    agents     => {
      minimax => { command => 'run-minimax', concurrent => 3 },
      opus    => { command => 'run-opus' },
    },
  };

  is_deeply limits_with( $cfg )->per_agent, { minimax => 3 },
    'the operator estimate on the definition is the limit; an agent without '
    . 'one is bounded only by the machine ceiling';

  is_deeply limits_with( $cfg,
      chain_limits => { per_agent => { minimax => 2, opus => 5 } } )->per_agent,
    { minimax => 2, opus => 5 },
    'the chain tightens minimax and introduces one for opus';

  is_deeply limits_with( $cfg,
      chain_limits => { per_agent => { minimax => 6 } } )->per_agent,
    { minimax => 3 },
    'a chain asking for more than the operator estimated does not get it';
};

subtest 'a chain limit for an agent this machine does not define is dropped' => sub {
  my $lim = limits_with(
    { concurrent => 4, agents => { opus => { command => 'run-opus' } } },
    chain_limits => { per_agent => { minimax => 2 } } );

  is_deeply $lim->per_agent, {},
    'per_agent names agent definitions, and this machine has no minimax -- '
    . 'which is the normal case, not a broken plan: agent definitions are '
    . 'local and only local';
};

subtest 'a count that is not one is refused locally and ignored from a chain' => sub {
  for my $bad ( 0, -1, 'two', '2.5', '' ) {
    my $err = do { local $@; eval { limits_with( { concurrent => $bad } )->concurrent }; $@ };
    like $err, qr/Config 'concurrent' must be a positive whole number/,
      "config concurrent: '$bad' is a config error, never a quiet default";
  }

  my $err = do {
    local $@;
    eval {
      limits_with( { concurrent => 2, agents => { m => { command => 'c', concurrent => 0 } } } )
        ->per_agent;
    };
    $@;
  };
  like $err, qr/Agent 'm' concurrent must be a positive whole number/,
    'and so is a per-agent estimate of zero';

  my @warned;
  my $lim = limits_with( { concurrent => 4 }, chain_limits => { concurrent => 'lots' } );
  my $got = do {
    local $SIG{__WARN__} = sub { push @warned, $_[0] };
    $lim->concurrent;
  };
  is $got, 4,
    'a bad number in the chain header falls back to the local ceiling: the '
    . 'header was written on another machine and must not stop this one';
  like "@warned", qr/chain header.*concurrent.*ignored/,
    '...and is said out loud rather than swallowed';
};

# ---------------------------------------------------------------------------
# What the runner actually does with them
# ---------------------------------------------------------------------------

subtest 'the runner is serial unless the config says otherwise' => sub {
  my ( $work, $cfg, $counter ) = build_fleet(
    boards => [ map { { name => "b$_" } } 1 .. 3 ] );

  my ( $exit, $warned ) = run_fleet( $cfg, $counter );
  is $exit, 0, 'the run finished';
  is peak( $counter, 'TOTAL' ), 1,
    'three boards, one agent at a time -- the default has not moved'
    or diag "warnings: @$warned";
};

subtest 'concurrent: N runs N boards at once, and never more' => sub {
  my ( $work, $cfg, $counter ) = build_fleet(
    boards     => [ map { { name => "b$_" } } 1 .. 4 ],
    concurrent => 2 );

  my ( $exit, $warned ) = run_fleet( $cfg, $counter );
  is $exit, 0, 'the run finished';
  is peak( $counter, 'TOTAL' ), 2,
    'two agents were live together (the runner is concurrent) and never a '
    . 'third (the ceiling holds)'
    or diag "warnings: @$warned";
};

subtest 'a per-agent limit caps one agent without idling the others' => sub {
  my ( $work, $cfg, $counter ) = build_fleet(
    boards => [
      { name => 'slow1', agent => 'slow' }, { name => 'slow2', agent => 'slow' },
      { name => 'fast1', agent => 'fast' }, { name => 'fast2', agent => 'fast' },
    ],
    concurrent => 4,
    agents     => { slow => 1, fast => 0 },
  );

  my ( $exit, $warned ) = run_fleet( $cfg, $counter );
  is $exit, 0, 'the run finished';
  is peak( $counter, 'slow' ), 1, 'the per-agent estimate for slow held'
    or diag "warnings: @$warned";
  is peak( $counter, 'fast' ), 2, 'fast, which named no limit, ran both boards';
  cmp_ok peak( $counter, 'TOTAL' ), '>', 1,
    'a board held by its own agent limit does not block the boards behind it';
};

# ---------------------------------------------------------------------------
# The rule that does not bend: one agent per repository
# ---------------------------------------------------------------------------

subtest 'one agent per repository, however many ticks knock at once' => sub {
  my $repo  = tempdir( CLEANUP => 1 );
  my $start = $repo->child('go');

  my @kids;
  for my $i ( 1 .. 4 ) {
    my $result = $repo->child("acquired.$i");
    my $pid    = fork;
    die "fork: $!" unless defined $pid;
    if ( $pid ) { push @kids, $pid; next }

    # Child: a foundation of its own, in a process of its own -- which is what
    # the concurrent runner is. flock(2) is per open file description, so an
    # in-process check would prove nothing about this.
    select undef, undef, undef, 0.02 until $start->exists;
    my $f = App::karr::Foundation->new( _config_data => {}, _chain_store => undef );
    my $ok = $f->_acquire_lock( $repo ) ? 1 : 0;
    $result->spew_utf8( $ok );
    select undef, undef, undef, 0.3 if $ok;
    POSIX::_exit( 0 );
  }

  $start->spew_utf8('go');
  waitpid $_, 0 for @kids;

  my $won = grep { $repo->child("acquired.$_")->slurp_utf8 eq '1' } 1 .. 4;
  is $won, 1,
    'exactly one of four simultaneous ticks took the board -- .karr.lock is '
    . 'per repository and concurrency is across repositories, never inside one';
};

subtest 'a signal to the foundation takes every running agent with it' => sub {
  # #163 and #148, once per board. The parent does not reach past its children
  # to their agents: it TERMs the children, and each one runs the same shutdown
  # it would have run serially -- TERM then KILL to its agent's whole process
  # group, then release its lock. Killing the children outright would leave one
  # agent per board reparented to init, which is exactly the bug #163 fixed.
  #
  # The agent here backgrounds a sleep and waits on it, so each board leaves a
  # grandchild that is a child of /bin/sh and not of the runner: it survives
  # anything short of a signal to the process group.
  my $work = tempdir( CLEANUP => 1 );
  my $cmd  = q{echo $$ > "$KARR_REPO/agent.pid"; }
           . q{sleep 300 & echo $! > "$KARR_REPO/grand.pid"; wait};

  my @dirs;
  for my $i ( 1, 2 ) {
    my $dir = $work->child("b$i");
    $dir->mkpath;
    $dir->child('.karr')
      ->spew_utf8( "drain: false\nmax_runtime: 300\ncommand: '$cmd'\n" );
    push @dirs, $dir;
  }
  my $cfg = $work->child('config.yml');
  $cfg->spew_utf8(
    "concurrent: 2\ndirs:\n" . join( '', map { "  - $_\n" } @dirs ) );

  my $driver = fork;
  die "fork: $!" unless defined $driver;
  unless ( $driver ) {
    App::karr::Foundation->new( config => "$cfg", force => 1 )->run;
    POSIX::_exit( 0 );
  }

  my @pids;
  my $deadline = time + 30;
  while ( time < $deadline ) {
    @pids = grep { $_ } map {
      my $file = $_;
      $file->exists && $file->slurp_utf8 =~ /([0-9]+)/ ? $1 : undef;
    } map { ( $_->child('agent.pid'), $_->child('grand.pid') ) } @dirs;
    last if @pids == 4;
    select undef, undef, undef, 0.05;
  }

  unless ( @pids == 4 ) {
    kill 'KILL', $driver;
    waitpid $driver, 0;
    fail 'both boards started an agent with a backgrounded grandchild';
    return;
  }
  is scalar( grep { kill 0, $_ } @pids ), 4,
    'two boards, each with a live agent and a live grandchild';

  kill 'TERM', $driver;
  waitpid $driver, 0;
  my $status = $?;

  my @alive = @pids;
  my $end   = time + 10;
  while ( time < $end ) {
    @alive = grep { kill 0, $_ } @pids;
    last unless @alive;
    select undef, undef, undef, 0.05;
  }
  is scalar @alive, 0,
    'one signal to karr-foundation took every agent and every grandchild of '
    . 'every board with it'
    or diag "still alive: @alive";

  is scalar( grep { $_->child('.karr.lock')->exists } @dirs ), 0,
    'and every board was unlocked on the way out, so the next tick is not '
    . 'locked out by a foundation that no longer exists';

  is $status & 127, 0, 'the foundation exited rather than dying of the signal';
  is $status >> 8, 128 + POSIX::SIGTERM(),
    'with the conventional 128 + signal number cron and systemd read';

  kill 'KILL', @alive if @alive;
};

# ---------------------------------------------------------------------------
# agents.state: shared by every board, so no longer read-modify-write in the
# open (the note #188 left here)
# ---------------------------------------------------------------------------

subtest 'concurrent updates to agents.state do not lose one another' => sub {
  my $dir = tempdir( CLEANUP => 1 );
  my $cfg = $dir->child('config.yml');
  $cfg->spew_utf8("dirs: []\n");

  my $start   = $dir->child('go');
  my $writers = 4;
  my $each    = 25;

  my @kids;
  for my $w ( 1 .. $writers ) {
    my $pid = fork;
    die "fork: $!" unless defined $pid;
    if ( $pid ) { push @kids, $pid; next }

    select undef, undef, undef, 0.02 until $start->exists;
    my $f = App::karr::Foundation->new( config => "$cfg", _chain_store => undef );
    my $agents = $f->_agents;
    for my $i ( 1 .. $each ) {
      $agents->_mutate( sub { $_[0]->{"w$w-$i"} = { state => 'ok' } } );
    }
    POSIX::_exit( 0 );
  }

  $start->spew_utf8('go');
  waitpid $_, 0 for @kids;

  my $reader = App::karr::Foundation->new( config => "$cfg", _chain_store => undef );
  my $state  = $reader->_agents->_read_state;
  is scalar( keys %$state ), $writers * $each,
    'every update survived: an availability record is shared by every board '
    . 'on the machine, and losing "it works again" parks them all for another '
    . 'probe interval';
};

# ---------------------------------------------------------------------------
# The chain header is the fleet's, not this machine's copy of it (#190's note)
# ---------------------------------------------------------------------------

subtest 'the fleet namespace is pulled before the chain header is read' => sub {
  my $work = tempdir( CLEANUP => 1 );
  system( 'git', 'init', '-q', '--bare', "$work/origin.git" ) == 0
    or plan skip_all => 'cannot create a bare origin';
  for my $name ( qw( hub planner ) ) {
    system( "git clone -q '$work/origin.git' '$work/$name' 2>/dev/null" ) == 0
      or plan skip_all => 'cannot clone';
    system( 'git', '-C', "$work/$name", 'config', 'user.email', "$name\@karr.test" );
    system( 'git', '-C', "$work/$name", 'config', 'user.name',  $name );
  }

  # The planner writes a chain that says "one at a time" and publishes it. The
  # hub clone has never seen it.
  my $planner = App::karr::Foundation::ChainStore->new(
    git => App::karr::Git->new( dir => "$work/planner" ) );
  $planner->write_chain(
    [ { id => 1, kind => 'ticket', repo => "$work/planner", ticket => 1 } ],
    limits => { concurrent => 1 } );
  my $pushed = App::karr::Git->new( dir => "$work/planner" )->push_foundation;
  ok $pushed, 'the chain is published to the remote';

  my $hub = App::karr::Foundation::ChainStore->new(
    git => App::karr::Git->new( dir => "$work/hub" ) );
  is_deeply $hub->header, {},
    'the hub clone has no chain of its own yet -- so a run that reads the '
    . 'header without fetching first reads nothing';

  my ( $fleet, $cfg, $counter ) = build_fleet(
    boards     => [ map { { name => "b$_" } } 1 .. 3 ],
    concurrent => 3,
    hub        => "$work/hub",
  );

  my ( $exit, $warned ) = run_fleet( $cfg, $counter );
  is $exit, 0, 'the run finished';
  is peak( $counter, 'TOTAL' ), 1,
    'the chain header the fleet published won over the local ceiling of 3, '
    . 'which it could only do if the namespace was pulled before it was read'
    or diag "warnings: @$warned";
};

done_testing;
