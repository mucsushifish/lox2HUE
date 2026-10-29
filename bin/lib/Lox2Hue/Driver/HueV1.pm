package Lox2Hue::Driver::HueV1;

# Driver for the Hue Bridge REST API v1 (round and square bridges).
#
# Every driver offers the same methods, so the daemon does not care which
# bridge or protocol is behind a channel:
#   set_light($id, $cmd)   set_group($id, $cmd)   all_off()
#   get_light($id)  -> { reachable, on, bri, colormode, hue, sat, ct, xy } or undef
# $cmd is a hash from Lox2Hue::Convert.

use strict;
use warnings;
use HTTP::Tiny;
use JSON;

sub new {
	my ($class, %args) = @_;
	my $scheme = $args{https} ? 'https' : 'http';
	my $self = {
		host => $args{host},
		user => $args{user},
		base => "$scheme://$args{host}/api/$args{user}",
		log  => $args{log} || sub {},
		# The bridge uses a self-signed certificate
		http => HTTP::Tiny->new(timeout => $args{timeout} || 3, verify_SSL => 0),
		json => JSON->new->canonical,
	};
	return bless $self, $class;
}

# Lox2Hue command -> v1 body
sub body {
	my ($cmd) = @_;
	my %b;
	$b{on}  = $cmd->{on} ? JSON::true : JSON::false if exists $cmd->{on};
	$b{$_}  = $cmd->{$_} + 0 for grep { defined $cmd->{$_} } qw(bri hue sat ct);
	$b{xy}  = [ map { $_ + 0 } @{ $cmd->{xy} } ] if $cmd->{xy};
	# v1 counts transition time in 100 ms steps
	$b{transitiontime} = int($cmd->{transition_ms} / 100) if defined $cmd->{transition_ms};
	return \%b;
}

sub _request {
	my ($self, $method, $path, $data) = @_;
	my %opts;
	$opts{content} = $self->{json}->encode($data) if $data;
	my $res = $self->{http}->request($method, "$self->{base}/$path", \%opts);
	if (!$res->{success}) {
		$self->{log}->(3, "$method $path failed: $res->{status} $res->{reason}");
		return undef;
	}
	my $out = eval { decode_json($res->{content}) };
	if (!defined $out) {
		$self->{log}->(3, "$method $path: invalid JSON from bridge");
		return undef;
	}
	return $out;
}

# Returns 1 when the bridge answered without an error entry
sub _put {
	my ($self, $path, $cmd) = @_;
	my $body = body($cmd);
	my $res = $self->_request('PUT', $path, $body);
	return 0 if !$res;
	my @errors = ref $res eq 'ARRAY' ? grep { $_->{error} } @$res : ();
	for (@errors) {
		$self->{log}->(4, "PUT $path: $_->{error}{description}");
	}
	$self->{log}->(7, "PUT $path " . $self->{json}->encode($body) . (@errors ? ' -> error' : ' -> ok'));
	return @errors ? 0 : 1;
}

sub set_light {
	my ($self, $id, $cmd) = @_;
	return $self->_put("lights/$id/state", $cmd);
}

sub set_group {
	my ($self, $id, $cmd) = @_;
	return $self->_put("groups/$id/action", $cmd);
}

sub all_off {
	my ($self) = @_;
	return $self->set_group(0, { on => 0 });
}

sub get_light {
	my ($self, $id) = @_;
	my $res = $self->_request('GET', "lights/$id");
	return undef if !$res || ref $res ne 'HASH' || !$res->{state};
	my $s = $res->{state};
	return {
		reachable => $s->{reachable} ? 1 : 0,
		on        => $s->{on} ? 1 : 0,
		map { $_ => $s->{$_} } grep { defined $s->{$_} } qw(bri colormode hue sat ct xy),
	};
}

# All lights of the bridge: { id => name }
sub list_lights {
	my ($self) = @_;
	my $res = $self->_request('GET', 'lights');
	return {} if !$res || ref $res ne 'HASH';
	return { map { $_ => $res->{$_}{name} } keys %$res };
}

# Creates an API user. The link button on the bridge must be pressed first.
# Returns ($user, undef) or (undef, $error).
sub pair {
	my ($class, %args) = @_;
	my $scheme = $args{https} ? 'https' : 'http';
	my $http = HTTP::Tiny->new(timeout => 5, verify_SSL => 0);
	my $res = $http->request('POST', "$scheme://$args{host}/api",
		{ content => encode_json({ devicetype => $args{devicetype} || 'lox2hue#loxberry' }) });
	return (undef, "$res->{status} $res->{reason}") if !$res->{success};
	my $out = eval { decode_json($res->{content}) };
	return (undef, 'invalid answer from bridge') if ref $out ne 'ARRAY' || !$out->[0];
	return ($out->[0]{success}{username}, undef) if $out->[0]{success};
	return (undef, $out->[0]{error}{description} || 'unknown error');
}

1;
