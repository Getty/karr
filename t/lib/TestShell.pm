package TestShell;
use strict;
use warnings;

# k328: the test files set their repositories up with shell strings written
# for sh -- system("git clone -q '$a' '$b' 2>/dev/null"), `printf ... | git
# hash-object`, perl -e '...'. On MSWin32 perl hands a one-string command to
# cmd.exe, which knows neither single quotes nor /dev/null, so the clone never
# happens and every later step fails on a directory that is not there.
#
# Rather than rewrite those lines (and risk the platforms they work on), this
# sends them to the sh that Git for Windows ships -- git is required by the
# suite anyway. It is loaded through TestEnv, does nothing outside MSWin32,
# and only touches a one-string system() or backtick issued from a file under
# t/: code under lib/ keeps talking to cmd.exe, as it does for a user.
#
# Three more things the test files rely on that perl does differently there
# are put right in the same place, each explained where it is done: quotes
# inside the arguments of a list-form system(), a child's stderr that outgrows
# a 512-byte pipe, and a child's stdin that never reaches EOF under open3.

my $SH;

sub sh_path {
    return $SH if defined $SH;
    my @candidates;
    my $exec = `git --exec-path 2>NUL`;
    if ( defined $exec && $exec =~ m{\A(.+?)[/\\](?:mingw\d+|clang\w+|ucrt\w+)[/\\]}i ) {
        push @candidates, "$1/usr/bin/sh.exe", "$1/bin/sh.exe";
    }
    push @candidates, map { "$_/sh.exe" } split /;/, ( $ENV{PATH} // '' );
    ($SH) = grep { -f } @candidates;
    return $SH //= '';
}

# Does this command line need sh, or would cmd.exe have run it as written?
sub _wants_sh {
    my ($cmd) = @_;
    return $cmd =~ m{ ' | /dev/null | \$\( | \|\| | &&
                     | \A\s*(?:printf|rm|cd|sh|echo|cat|touch|chmod|ln|mkdir|true|false|sleep|kill|env)\b
                     | \|\s*(?:grep|wc|head|tail|sort|sed|tr)\b }x;
}

# The command goes to sh as a script file: perl's Win32 argument quoting does
# not survive a string that carries quotes of its own. Outside single quotes a
# backslash in front of a path character is a Windows path separator, not an
# escape -- File::Temp hands out C:\Users\... and the tests interpolate it.
sub _script_for {
    my ($cmd) = @_;
    my $out = '';
    for my $part ( split /('[^']*')/, $cmd ) {
        # ... unless the test already escaped it for sh with \Q, which shows as
        # an escaped backslash or colon.
        $part =~ s{\\(?=[A-Za-z0-9_~.])}{\\\\}g
            unless $part =~ /\A'/ || $part =~ /\\[\\:]/;
        $out .= $part;
    }
    require File::Temp;
    my ( $fh, $file ) = File::Temp::tempfile( 'karr-sh-XXXXXXXX', TMPDIR => 1, UNLINK => 1 );
    binmode $fh;
    # Started outside Git Bash, sh has no /usr/bin on its PATH and finds
    # neither rm nor printf.
    print {$fh} qq{PATH="/usr/bin:\$PATH"\n}, $out, "\n";
    close $fh;
    return $file;
}

sub _from_test {
    my ($file) = @_;
    return defined $file && $file =~ m{(?:\A|[/\\])t[/\\]};
}

# One argument, quoted the way the Microsoft C runtime parses a command line.
sub _quote_arg {
    my ($arg) = @_;
    return $arg if length $arg && $arg !~ /[ \t"]/;
    $arg =~ s{(\\*)"}{$1$1\\"}g;
    $arg =~ s{(\\+)\z}{$1$1};
    return qq{"$arg"};
}

# A list-form system() whose arguments carry double quotes: perl's own Win32
# spawn wraps an argument with a space in quotes but leaves the quotes inside
# it alone, so `perl -e 'die "x"' {"json":1}` arrives in pieces. Start the
# program with a command line built by the rules it will be parsed with.
sub _spawn_exact {
    my ( $program, @args ) = @_;
    require Win32::Process;
    my ($exe) = grep { -f } $program, "$program.exe",
        map { ( "$_/$program.exe", "$_/$program" ) } split /;/, $ENV{PATH} // '';
    return CORE::system( $program, @args ) unless $exe;
    my $process;
    Win32::Process::Create( $process, $exe,
        join( ' ', map { _quote_arg($_) } $program, @args ),
        1, Win32::Process::NORMAL_PRIORITY_CLASS(), '.' )
        or return $? = -1;
    $process->Wait( Win32::Process::INFINITE() );
    $process->GetExitCode( my $code );
    return $? = ( $code & 0xff ) << 8;
}

# The runners in the test files read a child's stdout to EOF and its stderr
# after that. A pipe perl makes on MSWin32 holds 512 bytes: a child that says
# more than that on stderr blocks in its write while the test still waits for
# stdout to end. So a separate stderr handle gets a file behind it instead of
# a pipe -- written by the child, read back once the test asks for it.
my $ORIG_OPEN3;

sub _open3 {
    return $ORIG_OPEN3->(@_)
        unless ref $_[2] && _from_test( ( caller 0 )[1] );
    require File::Temp;
    my ( $write, $file ) = File::Temp::tempfile( 'karr-err-XXXXXXXX', TMPDIR => 1, UNLINK => 1 );
    binmode $write;

    # The child's stdin: perl's Win32 open3 lets the child inherit the write
    # end of that pipe as well, so closing it here never reads as EOF there and
    # a child that slurps stdin waits for ever. Make the pipe here, with a
    # write end the child cannot inherit.
    my $stdin = $_[0];
    my ( $to_child, $read );
    if ( !defined $_[0] && !Internals::SvREADONLY( $_[0] ) ) {
        require Win32API::File;
        pipe( $read, $to_child ) or die "pipe: $!";
        Win32API::File::SetHandleInformation(
            Win32API::File::FdGetOsFHandle( fileno $to_child ),
            Win32API::File::HANDLE_FLAG_INHERIT(), 0 );
        $stdin = '<&' . fileno($read);
    }

    my $pid = $ORIG_OPEN3->( $stdin, $_[1], '>&' . fileno($write), @_[ 3 .. $#_ ] );
    if ($to_child) {
        close $read;
        select( ( select($to_child), $| = 1 )[0] );
        $_[0] = $to_child;
    }
    close $write;
    open $_[2], '<', $file or die "reopen $file: $!";
    binmode $_[2];
    return $pid;
}

sub _install_open3 {
    require IPC::Open3;
    $ORIG_OPEN3 = \&IPC::Open3::open3;
    no warnings 'redefine';
    *IPC::Open3::open3 = \&_open3;
    return;
}

# A test file that loaded IPC::Open3 before this module already holds the
# original under its own name; by INIT its imports are all in place.
INIT {
    no warnings 'redefine';
    *main::open3 = \&_open3
        if $ORIG_OPEN3 && defined &main::open3 && \&main::open3 == $ORIG_OPEN3;
}

sub install {
    return unless $^O eq 'MSWin32' && sh_path();
    _install_open3();
    no warnings 'once';
    *CORE::GLOBAL::system = sub {
        my $file = ( caller 0 )[1];
        # Looked at through copies: matching the arguments themselves would
        # give the 1 of a system( 1, ... ) spawn a string value, and perl then
        # takes it for the program name.
        my @copy = @_;
        return _spawn_exact(@_)
            if @_ > 1 && _from_test($file) && grep { defined && /"/ } @copy;
        return CORE::system(@_)
            unless @_ == 1 && _from_test($file) && _wants_sh( $_[0] );
        return CORE::system( $SH, _script_for( $_[0] ) );
    };
    *CORE::GLOBAL::readpipe = sub {
        my ($cmd) = @_;
        my $file = ( caller 0 )[1];
        return CORE::readpipe($cmd)
            unless defined $cmd && _from_test($file) && _wants_sh($cmd);
        open my $pipe, '-|', $SH, _script_for($cmd) or return;
        binmode $pipe;
        my @lines = <$pipe>;
        close $pipe;
        return wantarray ? @lines : join '', @lines;
    };
    return 1;
}

install();

1;
