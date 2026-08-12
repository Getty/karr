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
classifies observable common errors (rate limit, auth, network, 5xx, ...) in
that buffer: a symptom word counts only next to a failure word on the same
line, or inside a phrase an API really emits, and an HTTP status only where
something adjacent marks it as one. The drain asks at all only for a run that
made no progress -- see L<App::karr::Foundation>'s "Drain semantics". A
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

# What the drain scans an agent's transcript for: a failure the agent reports
# while still exiting 0 -- a rate limit, a dead key, a 5xx -- because that run
# produced nothing and starting the next one immediately just spends the next
# window on the same wall.
#
# These were bare case-insensitive substrings (network, quota, credentials,
# 401, 403, 429, 503, ...) matched against the whole transcript. That is not a
# near-miss instrument, it is a word search over everything the agent printed,
# and an agent working a karr board prints the board: a backlog line reading
# "retry the network fetch on 503" tripped it twice over, and "403" tripped on
# a diffstat (#160). So a symptom word on its own never counts here. It counts
# next to a failure word on the same line ($SIGNAL / _near), or inside one of
# the fixed phrases an API really emits. Numbers are the worse half -- 403 is a
# line count, a byte count, a task id -- so an HTTP status counts only where
# something adjacent says it is one (_http).
#
# Every quantifier below is bounded and every gap stays inside one line: this
# runs over megabytes of agent output, and an unbounded gap between two classes
# that share characters backtracks quadratically over a banner rule.

# A word that turns a symptom into a report of failure. Deliberately excludes
# "retry", "limit" and "timeout" on their own: those are what a backlog full of
# networking tickets says, not what a failing API says.
my $SIGNAL = qr/\b(?:
    error | errors | failed | failing | failure | refused | rejected | denied
  | unavailable | unreachable | invalid | missing | expired | revoked | unable
  | exceeded | exhausted
)\b/xi;

# Limits are reported with verbs of their own.
my $LIMIT = qr/\b(?:
    exceed(?:ed|s|ing)? | reach(?:ed|ing)? | hit | hitting | exhausted
  | throttl(?:ed|ing) | error | over
)\b/xi;

# $symptom counts only within one line of a failure word, in either order.
sub _near {
  my ( $symptom, $signal ) = @_;
  $signal //= $SIGNAL;
  return qr/ (?: $symptom [^\n]{0,40}? $signal ) | (?: $signal [^\n]{0,40}? $symptom ) /x;
}

# An HTTP status, only where something adjacent marks it as one: an
# http/status/code/error token just before it -- with nothing but punctuation,
# a "code"/"status" word or a protocol version in between -- or its own reason
# phrase directly after it. " | 403 ++++++" and "line 403" mark neither.
my $GAP = qr/[ \t:=,.\-\/\(\[]{0,8}/;

sub _http {
  my ( $code, $phrase ) = @_;
  return qr/
      (?: \b (?: https? | status | code | error | err | response ) \b
          $GAP (?: code | status | \d+\.\d+ )? $GAP \b $code \b )
    | (?: \b $code \b [ \t:,\-\(\[]{0,4} $phrase )
  /xi;
}

# [ name => regex ]. The name is what reaches .karr.log and .karr.state, and it
# keeps the wording of the substring it replaces so an operator's grep for
# "COMMON-ERROR rate limit" still finds it.
# Middle field: lowercase literals the pattern cannot match without. It is a
# pre-filter, not a pattern (see _match_error) -- these regexes are 30x the
# work of the substrings they replace, and a transcript is megabytes.
my @DEFAULT_PATTERNS = (
  # rate limiting / capacity
  [ 'rate limit', ['rate'],
    _near( qr/\brate[_ -]?limit(?:s|ed|ing)?\b/i, $LIMIT ) ],
  [ 'rate limit', ['rate_limit_error'],    qr/\brate_limit_error\b/i ],
  [ 'usage limit', ['usage limit'],        _near( qr/\busage limit\b/i, $LIMIT ) ],
  [ 'quota', ['quota'],                    _near( qr/\bquotas?\b/i, $LIMIT ) ],
  [ 'overloaded', ['overloaded_error'],    qr/\boverloaded_error\b/i ],
  [ 'overloaded', ['overload','overcapacity'],
    _near( qr/\bover(?:loaded|capacity)\b/i ) ],
  [ 'too many requests', ['too many requests'], qr/\btoo many requests\b/i ],
  [ '429', ['429'],                        _http( 429, qr/too many requests/i ) ],
  [ '529', ['529'],                        _http( 529, qr/overloaded/i ) ],
  # authentication
  [ 'invalid api key', ['api'],
    qr/\b(?:invalid|missing|expired|revoked|no)\s+api[_ -]?key\b
     | \bapi[_ -]?key\b [^\n]{0,24}?
       \b(?:invalid|missing|expired|revoked|required|not\s+found)\b/xi ],
  [ 'authentication', ['authentication_error'], qr/\bauthentication_error\b/i ],
  [ 'authentication', ['authenticat'],     _near( qr/\bauthenticat(?:ion|ed|e)\b/i ) ],
  [ 'credentials', ['credential'],         _near( qr/\bcredentials?\b/i ) ],
  [ 'unauthorized', ['unauthori'],         _near( qr/\bunauthori[sz]ed\b/i ) ],
  [ 'forbidden', ['forbidden'],            _near( qr/\bforbidden\b/i ) ],
  [ '401', ['401'],                        _http( 401, qr/unauthori[sz]ed/i ) ],
  [ '403', ['403'],                        _http( 403, qr/forbidden/i ) ],
  # network / transport
  [ 'network', ['network'],                _near( qr/\bnetwork\b/i ) ],
  [ 'connection', ['connection'],
    qr/\bconnection\s+(?:refused|reset|closed|aborted|error|failed)\b/i ],
  [ 'connection',
    [qw( econnrefused econnreset etimedout ehostunreach enetunreach enotfound eai_again )],
    qr/\bE(?:CONNREFUSED|CONNRESET|TIMEDOUT|HOSTUNREACH|NETUNREACH|NOTFOUND|AI_AGAIN)\b/i ],
  [ 'fetch failed', ['fetch failed'],      qr/\bfetch failed\b/i ],
  # /x eats a literal space, so every phrase here spells it \s+.
  [ 'name resolution', ['resolve host','name resolution','service not known'],
    qr/\bcould\s+not\s+resolve\s+host\b
     | \btemporary\s+failure\s+in\s+name\s+resolution\b
     | \bname\s+or\s+service\s+not\s+known\b/xi ],
  [ 'timed out', ['time'],
    qr/\b(?:connection|connect|request|socket|read|write|handshake|operation|upstream)\b
       [^\n]{0,16}? \btimed?[ _-]?out\b/xi ],
  # server side
  [ 'service unavailable', ['service unavailable'],   qr/\bservice unavailable\b/i ],
  [ 'internal server error', ['internal server error'], qr/\binternal server error\b/i ],
  [ 'bad gateway', ['bad gateway'],        qr/\bbad gateway\b/i ],
  [ '500', ['500'],                        _http( 500, qr/internal server error/i ) ],
  [ '502', ['502'],                        _http( 502, qr/bad gateway/i ) ],
  [ '503', ['503'],                        _http( 503, qr/service unavailable/i ) ],
);

sub _error_patterns {
  my ( $self, $karr ) = @_;
  # A board's own error_patterns stay what they were documented as: plain
  # case-insensitive substrings. Somebody who configures one has seen the
  # string their agent prints and means exactly it -- the narrowing above is
  # for the defaults, which have to hold for every board. Such a pattern is
  # its own pre-filter.
  my @custom = map { [ $_, [ lc $_ ], qr/\Q$_\E/i ] }
               @{ $karr->{error_patterns} // [] };
  return [ @DEFAULT_PATTERNS, @custom ];
}

sub _match_error {
  my ( $self, $text, $patterns ) = @_;
  return undef unless defined $text && length $text;
  # The pre-filter earns its keep on the output that has none of this in it,
  # which is nearly all of it: index() over a whole transcript is a memory
  # scan, these patterns are not, and skipping one that cannot match costs a
  # single index instead of a full pass. A trigger that does not occur in what
  # its own pattern matches would silently switch that pattern off, so t/152
  # checks the two against each other over the corpus.
  my $lc;
  for my $p ( @$patterns ) {
    my ( $name, $triggers, $re ) =
      ref $p eq 'ARRAY' ? @$p : ( $p, [ lc $p ], qr/\Q$p\E/i );
    $lc //= lc $text;
    next unless grep { index( $lc, $_ ) >= 0 } @$triggers;
    return $name if $text =~ $re;
  }
  return undef;
}

1;
