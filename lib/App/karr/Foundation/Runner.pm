# ABSTRACT: karr-foundation command execution — fork/pipe/select tee + error classification

package App::karr::Foundation::Runner;
our $VERSION = '0.500';
use Moo;
use App::karr::Error qw( clean_error user_error );
use Encode ();
use IO::Select;
use IO::Handle ();

=head1 DESCRIPTION

L<App::karr::Foundation::Runner> runs a single agent command for
L<App::karr::Foundation>. It forks the command under C</bin/sh -c>, reads its
combined stdout/stderr over a native pipe, and tees each chunk to the
persistent C<.karr.log>, the terminal (when streaming), and an in-memory buffer
used for error scanning, enforcing the per-run C<max_runtime> timeout. It also
classifies observable common errors (rate limit, auth, network, 5xx, ...). A
weak back-reference to the owning foundation supplies shared options and helpers
(C<dry_run>, C<_stream_to_terminal>, C<_prompt_for>, C<_append_log>,
C<_say_verbose>).

The command is a shell template, not a string karr rewrites: C<PROMPT>,
C<KARR_REPO> and C<KARR_ROLE> are exported into the child's environment and
C</bin/sh> expands them like any other parameter. A prompt's own backticks
therefore stay text, and C<< awk '{print $2}' >> reaches awk intact.

A C<.karr.log> it cannot open ends the run for that board B<before> the command
is started, never after: the agent is refused rather than launched unwatched.
Once the fork has happened the parent owes it a C<waitpid>, so nothing between
the two may throw.

=cut

has foundation => (
  is       => 'ro',
  weak_ref => 1,
  required => 1,
);

# ---------------------------------------------------------------------------
# Command execution
# ---------------------------------------------------------------------------

sub _run_command {
  my ( $self, $repo, $karr, $cmd ) = @_;
  my $command      = $cmd // $karr->{command};
  my $max_runtime  = $karr->{max_runtime} // 1800;
  my $stream_terms = $self->foundation->_stream_to_terminal;

  # Environment for the child (and all karr calls it spawns). The child inherits
  # it across the fork/exec below, so a command template — including the
  # synthesized claude command — expands $PROMPT, ${KARR_REPO}, $KARR_ROLE and
  # every other variable foundation itself was started with as ordinary shell
  # parameters.
  local $ENV{KARR_REPO} = "$repo";
  local $ENV{KARR_ROLE} = 'agent';
  local $ENV{PROMPT}    = $self->foundation->_prompt_for($karr);

  # The expansion is the shell's, not ours (#159). Splicing %ENV into the command
  # string here instead meant the shell went on to parse the *values*: a prompt
  # is board content written in Markdown, so its backtick spans and $(...) ran as
  # commands in the board's own directory, and the substitution reached inside
  # single quotes, where sh guarantees a literal — awk '{print $2}' arrived as
  # awk '{print }'. Parameter expansion has neither problem: sh does not rescan
  # an expanded value for substitutions, and it leaves single quotes alone. A
  # template that needs a value the shell cannot see gets it exported above,
  # never spliced.
  #
  # So this logs the template, which is now exactly the string /bin/sh -c is
  # handed. It used to log the substituted result, which after this change is not
  # even computable without reimplementing the shell — and what an operator reads
  # this line for is which command was resolved (--command vs default_command vs
  # .karr vs synthesized claude), not a second copy of the prompt. It also no
  # longer copies whatever an env var held — a wrapper's API key included — into
  # a plaintext .karr.log.
  $self->foundation->_append_log( $repo, "START command=$command" );
  $self->foundation->_say_verbose("exec in $repo: $command");

  if ( $self->foundation->dry_run ) {
    $self->foundation->_append_log( $repo, "DRY-RUN (skipped)" );
    return ( 0, '' );
  }

  my $log_file = $repo->child('.karr.log');

  # Opened before the command is started, not after (#147). Everything from the
  # fork below to the waitpid at the end of this method runs with a live agent
  # on the other side, and the drain loop that calls this catches per repo and
  # moves on to the next board — so a croak in that window releases the board's
  # lock with its agent still running and leaves one behind for the rest of the
  # foundation run. Refusing to start an agent whose log cannot be written is
  # the honest failure, and it is the one the foundation's own
  # _append_log("START ...") above already makes for the same file.
  # A resource the OS refused is the operator's problem, not a bug report, so
  # this and the two below carry the errno and no call site into this file (#77).
  open( my $log_fh, '>>', "$log_file" ) or user_error("open log $log_file: $!");
  $log_fh->autoflush(1);

  # Native pipe: the child writes stdout+stderr, the parent reads. The parent
  # is the tee — it fans each chunk to the persistent log, the terminal (when
  # streaming), and an in-memory buffer for error scanning. No external tee
  # process to race, and the run's output is captured directly (no re-slurping
  # the log via byte offsets).
  pipe( my $reader, my $writer ) or user_error("pipe failed: $!");

  my $pid = fork;
  user_error("fork failed: $!") unless defined $pid;

  if ( $pid == 0 ) {
    # child
    close $reader;
    chdir "$repo" or die "chdir $repo: $!";
    open( STDOUT, '>&', $writer ) or die "dup stdout: $!";
    open( STDERR, '>&STDOUT' )    or die "dup stderr: $!";
    exec( '/bin/sh', '-c', $command ) or die "exec: $!";
  }

  # parent. From here to the waitpid below there is a running agent, so nothing
  # in between may die: no croaking call, and no unguarded call into the
  # foundation (its _append_log throws when the log file is gone). Keep it that
  # way — the tee loop below reports its errors by ending, not by dying.
  close $writer;

  my $started   = time;
  my $output    = '';
  my $timed_out = 0;
  my $sel       = IO::Select->new($reader);

  # The agent's output arrives as raw octets in 64k reads that can split a
  # multi-byte character, while STDOUT carries the :encoding(UTF-8) layer
  # F<karr-foundation> installed and therefore wants characters. FB_QUIET is
  # the streaming decoder: it consumes every complete sequence and leaves a
  # trailing partial one in $pending for the next chunk. The log file and the
  # error-scanning buffer keep the raw octets.
  my $pending = '';

  while (1) {
    my $wait;
    if ( $max_runtime > 0 ) {
      $wait = $max_runtime - ( time - $started );
      if ( $wait <= 0 ) { $timed_out = 1; last }
    }
    # undef $wait => block indefinitely (max_runtime: 0 disables the timeout).
    my @ready = $sel->can_read($wait);
    unless (@ready) {
      # Spurious wakeup (signal) or deadline. Only the deadline ends the loop.
      next unless $max_runtime > 0;
      if ( time - $started >= $max_runtime ) { $timed_out = 1; last }
      next;
    }
    my $chunk;
    my $n = sysread( $reader, $chunk, 65536 );
    last if !defined $n;   # read error
    last if $n == 0;       # EOF — the command closed its output
    print {$log_fh} $chunk;
    if ($stream_terms) {
      $pending .= $chunk;
      print Encode::decode( 'UTF-8', $pending, Encode::FB_QUIET );
    }
    $output .= $chunk;
  }

  my $exit_code;
  if ($timed_out) {
    my $elapsed = time - $started;
    # The one call that has to happen here rather than after the kill: it is the
    # only record of why the agent was stopped, and the kill/waitpid pair below
    # can block for as long as the child stays unkillable. So it runs
    # best-effort — a log the OS took away mid-run (#147) must not cost us the
    # SIGTERM/SIGKILL and the reap, which are all that stop a hung agent. The
    # failure is reported once the child is safely gone, and the END line below
    # raises it for real if the log is still unwritable by then.
    my $log_err;
    eval {
      $self->foundation->_append_log( $repo,
        "TIMEOUT after ${elapsed}s \x{2014} sending SIGTERM to $pid" );
      1;
    } or $log_err = clean_error($@);
    kill 'TERM', $pid;
    sleep 2;
    kill 'KILL', $pid;
    waitpid( $pid, 0 );
    warn "karr-foundation: cannot write $log_file: $log_err\n" if $log_err;
    $exit_code = -1;
  } else {
    waitpid( $pid, 0 );
    $exit_code = $? >> 8;
  }

  close $reader;
  close $log_fh;

  my $elapsed = time - $started;
  $self->foundation->_append_log( $repo, "END elapsed=${elapsed}s exit=$exit_code" );
  return ( $exit_code, $output );
}

# ---------------------------------------------------------------------------
# Common-error detection
# ---------------------------------------------------------------------------

sub _error_patterns {
  my ( $self, $karr ) = @_;
  my @default = (
    'rate limit', 'rate-limit', 'usage limit', 'quota exceeded', 'quota',
    'overloaded', 'too many requests', '429', '529',
    'unauthorized', 'forbidden', 'authentication', 'invalid api key',
    'credentials', '401', '403',
    'connection refused', 'connection reset', 'network', 'timed out',
    'service unavailable', '503', '500 internal',
  );
  return [ @default, @{ $karr->{error_patterns} // [] } ];
}

sub _match_error {
  my ( $self, $text, $patterns ) = @_;
  return undef unless defined $text && length $text;
  for my $p ( @$patterns ) {
    return $p if $text =~ /\Q$p\E/i;
  }
  return undef;
}

1;
