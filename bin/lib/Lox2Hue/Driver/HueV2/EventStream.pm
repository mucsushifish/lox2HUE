package Lox2Hue::Driver::HueV2::EventStream;

# Reads the Server-Sent Events stream of a Hue bridge (GET /eventstream/clip/v2)
# without blocking the daemon's main loop.
#
# Each "data:" line carries a JSON array of events, e.g.
#   [{"type":"update","data":[{"id":"...","type":"light","on":{"on":true}}]}]
# The bridge sends no keepalive, so after idle_timeout seconds without data
# the stream is reconnected (and the driver re-reads all states).

use strict;
use warnings;
use IO::Socket::SSL;
use JSON;
use Errno qw(EAGAIN EWOULDBLOCK EINTR);

sub new {
	my ($class, %args) = @_;
	return bless {
		host         => $args{host},
		key          => $args{key},
		log          => $args{log} || sub {},
		on_event     => $args{on_event},
		on_connect   => $args{on_connect} || sub {},
		now          => $args{now} || sub { time() },
		idle_timeout => $args{idle_timeout} || 300,
		sock         => undef,
		buf          => '',
		headers_done => 0,
		chunked      => 0,
		chunk_left   => 0,
		raw          => '',
		last_data    => 0,
		next_try     => 0,
		failures     => 0,
		last_id      => undef,
	}, $class;
}

sub _log { my $self = shift; $self->{log}->(@_); }

sub connected { return $_[0]{sock} ? 1 : 0; }

sub _connect {
	my ($self) = @_;
	my $now = $self->{now}->();
	return if $now < $self->{next_try};

	# "host" or "host:port"
	my ($host, $port) = $self->{host} =~ /^(.+?)(?::(\d+))?$/;
	my $sock = IO::Socket::SSL->new(
		PeerHost        => $host,
		PeerPort        => $port || 443,
		SSL_verify_mode => SSL_VERIFY_NONE,    # the bridge uses its own certificate
		Timeout         => 3,
	);
	if (!$sock) {
		$self->{failures}++;
		my $wait = 2 * $self->{failures};
		$wait = 60 if $wait > 60;
		$self->{next_try} = $now + $wait;
		$self->_log(4, "Event stream: connect failed ($SSL_ERROR), retry in $wait s");
		return;
	}
	my $req = "GET /eventstream/clip/v2 HTTP/1.1\r\n"
		. "Host: $self->{host}\r\n"
		. "hue-application-key: $self->{key}\r\n"
		. "Accept: text/event-stream\r\n"
		. "Cache-Control: no-cache\r\n"
		. ($self->{last_id} ? "Last-Event-ID: $self->{last_id}\r\n" : '')
		. "\r\n";
	print $sock $req;
	$sock->blocking(0);

	@$self{qw(sock buf raw headers_done chunked chunk_left)} = ($sock, '', '', 0, 0, 0);
	$self->{last_data} = $now;
	return;
}

sub _close {
	my ($self, $reason) = @_;
	$self->_log(4, "Event stream closed: $reason") if $reason;
	close $self->{sock} if $self->{sock};
	$self->{sock} = undef;
	$self->{failures}++;
	my $wait = 2 * $self->{failures};
	$wait = 60 if $wait > 60;
	$self->{next_try} = $self->{now}->() + $wait;
	return;
}

# Reads everything that is available right now and dispatches complete events
sub poll {
	my ($self) = @_;
	if (!$self->{sock}) {
		$self->_connect;
		return if !$self->{sock};
	}

	my $got = 0;
	while (1) {
		my $n = sysread($self->{sock}, my $chunk, 16384);
		if (!defined $n) {
			last if $! == EAGAIN || $! == EWOULDBLOCK || $! == EINTR;
			return $self->_close("read error: $!");
		}
		return $self->_close('closed by bridge') if $n == 0;
		$self->{raw} .= $chunk;
		$got = 1;
	}

	my $now = $self->{now}->();
	if (!$got) {
		$self->_close('no data, reconnecting') if $now - $self->{last_data} > $self->{idle_timeout};
		return;
	}
	$self->{last_data} = $now;
	$self->_parse;
	return;
}

sub _parse {
	my ($self) = @_;
	if (!$self->{headers_done}) {
		my $end = index($self->{raw}, "\r\n\r\n");
		return if $end < 0;
		my $head = substr($self->{raw}, 0, $end);
		$self->{raw} = substr($self->{raw}, $end + 4);
		my ($status) = $head =~ m{^HTTP/\S+\s+(\d+)};
		if (!$status || $status != 200) {
			return $self->_close('bridge answered ' . ($status // 'nothing') . ($status && $status == 403 ? ' (API user not accepted)' : ''));
		}
		$self->{chunked} = $head =~ /^Transfer-Encoding:\s*chunked/mi ? 1 : 0;
		$self->{headers_done} = 1;
		$self->{failures} = 0;
		$self->_log(6, 'Event stream connected');
		$self->{on_connect}->();
	}

	# undo chunked transfer encoding
	if ($self->{chunked}) {
		while (length $self->{raw}) {
			if ($self->{chunk_left} == 0) {
				my $eol = index($self->{raw}, "\r\n");
				last if $eol < 0;
				my $size = substr($self->{raw}, 0, $eol);
				$size =~ s/;.*//;
				if ($size =~ /^\s*$/) {    # CRLF after a chunk
					$self->{raw} = substr($self->{raw}, $eol + 2);
					next;
				}
				$self->{chunk_left} = hex($size);
				$self->{raw} = substr($self->{raw}, $eol + 2);
				return $self->_close('stream ended') if $self->{chunk_left} == 0;
			}
			my $take = length $self->{raw} < $self->{chunk_left} ? length $self->{raw} : $self->{chunk_left};
			$self->{buf} .= substr($self->{raw}, 0, $take);
			$self->{raw} = substr($self->{raw}, $take);
			$self->{chunk_left} -= $take;
		}
	} else {
		$self->{buf} .= $self->{raw};
		$self->{raw} = '';
	}

	# one SSE message ends with an empty line
	$self->{buf} =~ s/\r\n/\n/g;
	while ((my $end = index($self->{buf}, "\n\n")) >= 0) {
		my $msg = substr($self->{buf}, 0, $end);
		$self->{buf} = substr($self->{buf}, $end + 2);
		$self->_message($msg);
	}
	return;
}

sub _message {
	my ($self, $msg) = @_;
	my $data = '';
	for my $line (split /\n/, $msg) {
		next if $line =~ /^:/;    # comment
		my ($key, $value) = $line =~ /^([^:]+):\s?(.*)$/ or next;
		$self->{last_id} = $value if $key eq 'id';
		$data .= $value if $key eq 'data';
	}
	return if $data eq '';
	my $events = eval { decode_json($data) };
	if (ref $events ne 'ARRAY') {
		$self->_log(4, 'Event stream: invalid data');
		return;
	}
	$self->{on_event}->($_) for @$events;
	return;
}

1;
