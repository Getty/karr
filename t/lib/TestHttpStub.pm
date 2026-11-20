package TestHttpStub;
use strict;
use warnings;

# A stand-in for a remote's HTTP front (k333): a forked listener on a free
# local port that answers every request with one status and one body, which is
# all a rate limit or a server error is. Killed when the test process ends.

use Exporter 'import';
use IO::Socket::INET;
use POSIX ();

our @EXPORT_OK = qw( http_stub closed_port );

my @KIDS;
END { kill 'TERM', @KIDS if @KIDS }

# http_stub( $status, $body ) -> port, or undef when none could be started.
sub http_stub {
    my ( $status, $body ) = @_;
    my $listen = IO::Socket::INET->new(
        Listen => 5, LocalAddr => '127.0.0.1', LocalPort => 0, ReuseAddr => 1,
    ) or return;
    my $port = $listen->sockport;
    my $pid  = fork;
    return unless defined $pid;
    if ( !$pid ) {
        local $SIG{TERM} = sub { POSIX::_exit(0) };
        while ( my $c = $listen->accept ) {
            local $/ = "\r\n";
            while ( defined( my $line = <$c> ) ) { last if $line eq "\r\n" }
            print {$c} "HTTP/1.1 $status X\r\n",
                ( $status == 429 ? "Retry-After: 60\r\n" : '' ),
                "Content-Type: text/plain\r\nContent-Length: " . length($body) . "\r\nConnection: close\r\n\r\n$body";
            close $c;
        }
        POSIX::_exit(0);
    }
    push @KIDS, $pid;
    close $listen;
    return $port;
}

# A local port nothing listens on.
sub closed_port {
    my $l = IO::Socket::INET->new( Listen => 1, LocalAddr => '127.0.0.1', LocalPort => 0 ) or return;
    my $port = $l->sockport;
    close $l;
    return $port;
}

1;
