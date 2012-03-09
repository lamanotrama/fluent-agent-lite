package Fluent::AgentLite;

use strict;
use warnings;
use English;
use Carp;

use Time::Piece;
use Log::Minimal;

use IO::Socket::INET;
use Data::MessagePack;

our $VERSION = '0.01';

use constant READ_WAIT => 0.1; # 0.1sec

use constant SOCKET_TIMEOUT => 5; # 5sec

use constant CONNECTION_KEEPALIVE => 1800; # 30min
use constant CONNECTION_KEEPALIVE_MARGIN_MAX => 30; # max 30sec

use constant RECONNECT_WAIT_MIN => 0.5;  # 0.5sec
use constant RECONNECT_WAIT_MAX => 3600; # 60min
use constant RECONNECT_WAIT_INCR_RATE => 1.5;

use constant SEND_RETRY_MAX => 4;

sub connection_keepalive_time {
    CONNECTION_KEEPALIVE + int(CONNECTION_KEEPALIVE_MARGIN_MAX * 2 * rand()) - CONNECTION_KEEPALIVE_MARGIN_MAX;
}

sub new {
    my $this = shift;
    my ($tag, $primary_servers, $secondary_servers, $configuration) = @_;
    my $self = {
        tag => $tag,
        servers => {
            primary => $primary_servers,
            secondary => $secondary_servers,
        },
        buffer_size => $configuration->{buffer_size},
    };

    srand (time ^ $PID ^ unpack("%L*", `ps axww | gzip`));

    bless $self, $this;
}

sub execute {
    my $self = shift;
    my $args = shift;

    my $fieldname = $args->{fieldname};
    my $tailfd = $args->{tailfd};

    my $check_terminated = ($args->{checker} || {})->{term} || sub { 0 };
    my $check_reconnect = ($args->{checker} || {})->{reconnect} || sub { 0 };

    my $packer = Data::MessagePack->new();

    my $reconnect_wait = RECONNECT_WAIT_MIN;

    my $pending_packed;
    my $continuous_line;

    while(not $check_terminated->()) {
        # at here, connection initialized (after retry wait if required)

        # connect to servers
        my $primary = $self->choose($self->{servers}->{primary});
        my $secondary;

        my $sock = $self->connect($primary);
        if (not $sock and $self->{servers}->{secondary}) {
            $secondary = $self->choose($self->{servers}->{secondary});
            $sock = $self->connect($self->choose($self->{servers}->{secondary}));
        }
        unless ($sock) {
            # failed to connect both of primary / secondary
            warnf 'failed to connect servers, primary: %s, secondary: %s', $primary, ($secondary || 'none');
            warnf 'waiting %s seconds to reconnect', $reconnect_wait;

            sleep $reconnect_wait;
            $reconnect_wait *= RECONNECT_WAIT_INCR_RATE;
            $reconnect_wait = RECONNECT_WAIT_MAX if $reconnect_wait > RECONNECT_WAIT_MAX;
            next;
        }

        # succeed to connect. set keepalive disconnect time
        my $connecting = $secondary || $primary;

        my $expired = time + connection_keepalive_time();
        $reconnect_wait = RECONNECT_WAIT_MIN;

        while(not $check_reconnect->()) {
            if (time > $expired) { # connection keepalive expired
                infof "connection keepalive expired.";
                last;
            }

            # drain (sysread)
            if (not $pending_packed) {
                my $buffered_lines;
                ($buffered_lines, $continuous_line) = $self->drain($tailfd, $continuous_line);
                unless ($buffered_lines) {
                    sleep READ_WAIT;
                    next;
                }
                $pending_packed = $self->pack($packer, $fieldname, $buffered_lines);
            }
            # send
            my $written = $self->send($sock, $pending_packed);
            last unless $written; # failed to write (socket error).

            $pending_packed = undef;
        }
        if ($check_reconnect->()) {
            infof "SIGHUP (or SIGTERM) received";
        }
        infof "disconnecting to current server";
        if ($sock) {
            $sock->close;
            $sock = undef;
        }
        infof "disconnected.";
    }
    if ($check_terminated->()) {
        warnf "SIGTERM received";
    }
    infof "process exit";
}

sub drain {
    # if broken child process (undefined return value of $fd->sysread())
    #   if content exists, return it.
    #   else die
    my ($self,$fd, $continuous_line) = @_;
    my $readlimit = $self->{buffer_size};
    my $readsize = 0;
    my $readlines = 0;
    my @buffered_lines;

    my $chunk;
    while ($readsize < $readlimit) {
        my $bytes = $fd->sysread($chunk, $readlimit);
        if (defined $bytes and $bytes == 0) { # EOF (child process exit)
            last if $readsize > 0;
            warnf "failed to read from child process, maybe killed.";
            confess "give up to read tailing fd, see logs";
        }
        if (not defined $bytes and $! eq "Resource temporarily unavailable") { # I/O Error (no data in fd)
            last;
        }
        if (not defined $bytes) { # Other I/O error... what?
            warnf "I/O error with tail fd: $!";
            last;
        }

        $readsize += $bytes;
        my $terminated_line = chomp $chunk;
        my @lines = split(m!\n!, $chunk);
        if ($continuous_line) {
            $lines[0] = $continuous_line . $lines[0];
            $continuous_line = undef;
        }
        if (not $terminated_line) {
            $continuous_line = pop @lines;
        }
        if (scalar(@lines) > 0) {
            push @buffered_lines, @lines;
            $readlines += scalar(@lines);
        }
    }
    if ($readlines < 1) {
        return undef, $continuous_line;
    }

    return (\@buffered_lines, $continuous_line);
}

# MessagePack 'Forward' object
# see lib/fluent/plugin/in_forward.rb in fluentd
sub pack {
    my ($self,$packer,$fieldname,$lines) = @_;
    my $t = time;
    return $packer->pack([$self->{tag}, [ map { [$t, {$fieldname => $_}] } @$lines ]]);
}

# choose a server [host, port] randomly from arg arrayref
sub choose {
    my ($self,$servers) = @_;
    my $num = scalar(@$servers);
    return $servers->[int(rand() * $num)];
}

sub connect {
    my ($self,$server) = @_;
    my $sock = IO::Socket::INET->new(
        PeerAddr  => $server->[0],
        PeerPort  => $server->[1],
        Proto     => 'tcp',
        Timeout   => SOCKET_TIMEOUT,
        ReuseAddr => 1,
    );
    if ($sock) {
        infof 'connected to server: %s', $server;
    } else {
        warnf 'failed to connect to server %s : %s', $server, $!;
    }
    $sock;
}

sub send {
    my ($self,$sock,$data) = @_;
    my $length = length($data);
    my $written = 0;
    my $retry = 0;

    local $SIG{"PIPE"} = sub { die $! };

    eval {
        while ($written < $length) {
            my $wbytes = $sock->syswrite($data, $length, $written);
            unless ($wbytes) {
                die "failed $retry times to send data: $!" if $retry > SEND_RETRY_MAX;
                $retry += 1;
            }
            $written += $wbytes;
        }
    };
    if ($@) {
        my $error = $@;
        warnf "Cannot send data: $error";
        return undef;
    }
    $written;
}

sub close {
    my ($self,$sock) = @_;
    $sock->close if $sock;
}

1;