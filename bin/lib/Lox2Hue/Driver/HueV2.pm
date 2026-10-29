package Lox2Hue::Driver::HueV2;

# Driver for the Hue Bridge CLIP API v2 (HTTPS only, square bridge with
# firmware 1948086000 or newer, Bridge Pro).
#
# Same interface as Lox2Hue::Driver::HueV1. Lamps and groups keep their v1
# numbers in the configuration; the driver maps them to v2 resource IDs via
# the id_v1 field. Lamp states are kept up to date from the bridge's event
# stream, so get_light() answers from memory without asking the bridge.
#
# Reference used for paths and fields: the aiohue library
# (github.com/home-assistant-libs/aiohue), because the official API reference
# requires a developer login.

use strict;
use warnings;
use HTTP::Tiny;
use JSON;
use Lox2Hue::Driver::HueV2::EventStream;

sub new {
	my ($class, %args) = @_;
	my $self = bless {
		host   => $args{host},
		user   => $args{user},
		log    => $args{log} || sub {},
		now    => $args{now} || sub { time() },
		http   => HTTP::Tiny->new(
			timeout         => $args{timeout} || 3,
			verify_SSL      => 0,    # the bridge uses its own certificate
			default_headers => { 'hue-application-key' => $args{user} },
		),
		json    => JSON->new->canonical,
		lights  => {},   # v1 number -> uuid
		groups  => {},   # v1 number -> grouped_light uuid
		v1_of   => {},   # light uuid -> v1 number
		device  => {},   # light uuid -> device uuid
		conn    => {},   # device uuid -> zigbee status
		state   => {},   # light uuid -> { on, bri, xy, ct, colormode }
		changed => {},   # v1 numbers with new state since the last changed()
		mapped  => 0,
		next_map_try => 0,
	}, $class;
	$self->{events} = Lox2Hue::Driver::HueV2::EventStream->new(
		host     => $args{host},
		key      => $args{user},
		log      => $self->{log},
		on_event => sub { $self->_event(@_) },
		on_connect => sub { $self->{mapped} = 0; },
	) if !$args{no_events};
	return $self;
}

sub _log { my $self = shift; $self->{log}->(@_); }

# Hue v2 has no hue/sat, the controller sends xy instead
sub color_space { 'xy' }

sub _request {
	my ($self, $method, $path, $data) = @_;
	my %opts;
	$opts{content} = $self->{json}->encode($data) if $data;
	$opts{headers} = { 'Content-Type' => 'application/json' } if $data;
	my $res = $self->{http}->request($method, "https://$self->{host}/clip/v2/$path", \%opts);
	my $out = eval { decode_json($res->{content}) };
	if (!$res->{success}) {
		my @err = $out && ref $out->{errors} eq 'ARRAY' ? map { $_->{description} } @{ $out->{errors} } : ();
		$self->_log(3, "$method $path failed: $res->{status} $res->{reason}" . (@err ? " (@err)" : ''));
		return undef;
	}
	if (!$out) {
		$self->_log(3, "$method $path: invalid JSON from bridge");
		return undef;
	}
	for (@{ $out->{errors} || [] }) {
		$self->_log(4, "$method $path: $_->{description}");
	}
	return $out;
}

# Builds the v1 -> v2 ID tables and the current lamp states
sub refresh {
	my ($self) = @_;
	my $lights = $self->_request('GET', 'resource/light') or return 0;
	my $glight = $self->_request('GET', 'resource/grouped_light') or return 0;
	my $conn   = $self->_request('GET', 'resource/zigbee_connectivity') or return 0;

	my (%l, %v1, %dev);
	for my $r (@{ $lights->{data} || [] }) {
		my ($n) = ($r->{id_v1} // '') =~ m{^/lights/(\d+)$} or next;
		$l{$n} = $r->{id};
		$v1{ $r->{id} } = $n;
		$dev{ $r->{id} } = $r->{owner}{rid} if $r->{owner};
		$self->_update_state($r);
	}
	my %g;
	for my $r (@{ $glight->{data} || [] }) {
		my ($n) = ($r->{id_v1} // '') =~ m{^/groups/(\d+)$} or next;
		$g{$n} = $r->{id};
	}
	$self->{conn} = {};
	for my $r (@{ $conn->{data} || [] }) {
		$self->{conn}{ $r->{owner}{rid} } = $r->{status} if $r->{owner};
	}
	@$self{qw(lights v1_of device groups)} = (\%l, \%v1, \%dev, \%g);
	$self->{mapped} = 1;
	$self->_log(6, sprintf('Bridge: %d lights, %d groups', scalar keys %l, scalar keys %g));
	return 1;
}

sub _ensure_mapped {
	my ($self) = @_;
	return 1 if $self->{mapped};
	# do not hammer an unreachable bridge
	return 0 if $self->{now}->() < $self->{next_map_try};
	$self->{next_map_try} = $self->{now}->() + 10;
	return $self->refresh;
}

# Lamp state from a GET answer or an event (events only carry changed fields)
sub _update_state {
	my ($self, $r) = @_;
	my $s = $self->{state}{ $r->{id} } ||= {};
	$s->{on} = $r->{on}{on} ? 1 : 0 if $r->{on};
	if ($r->{dimming} && defined $r->{dimming}{brightness}) {
		my $bri = sprintf('%.0f', $r->{dimming}{brightness} * 2.54);
		$s->{bri} = $bri < 1 ? 1 : $bri > 254 ? 254 : $bri + 0;
	}
	if ($r->{color} && $r->{color}{xy}) {
		$s->{xy} = [ $r->{color}{xy}{x}, $r->{color}{xy}{y} ];
		$s->{colormode} = 'xy';
	}
	if ($r->{color_temperature}) {
		if ($r->{color_temperature}{mirek_valid} && defined $r->{color_temperature}{mirek}) {
			$s->{ct} = $r->{color_temperature}{mirek};
			$s->{colormode} = 'ct';
		} elsif (exists $r->{color_temperature}{mirek_valid}) {
			$s->{colormode} = 'xy' if $r->{color};
		}
	}
	return;
}

sub _event {
	my ($self, $ev) = @_;
	return if ($ev->{type} // '') ne 'update';
	for my $r (@{ $ev->{data} || [] }) {
		my $type = $r->{type} // '';
		if ($type eq 'light' && $self->{state}{ $r->{id} }) {
			$self->_update_state($r);
			my $n = $self->{v1_of}{ $r->{id} };
			$self->{changed}{$n} = 1 if defined $n;
		} elsif ($type eq 'zigbee_connectivity' && $r->{owner} && $r->{status}) {
			$self->{conn}{ $r->{owner}{rid} } = $r->{status};
			for my $light (keys %{ $self->{device} }) {
				next if $self->{device}{$light} ne $r->{owner}{rid};
				my $n = $self->{v1_of}{$light};
				$self->{changed}{$n} = 1 if defined $n;
				$self->_log(7, "light $n: $r->{status}");
			}
		} elsif ($type eq 'light' || $type eq 'grouped_light') {
			# unknown resource, e.g. a lamp added after start
			$self->{mapped} = 0 if $type eq 'light';
		}
	}
	return;
}

# Reads the event stream; call often from the main loop. Never blocks long.
sub poll {
	my ($self) = @_;
	$self->{events}->poll if $self->{events} && $self->{host} && $self->{user};
	return;
}

# v1 numbers of lamps whose state changed since the last call
sub changed {
	my ($self) = @_;
	my @n = keys %{ $self->{changed} };
	$self->{changed} = {};
	return @n;
}

# Lox2Hue command -> v2 body
sub body {
	my ($cmd) = @_;
	my %b;
	$b{on} = { on => $cmd->{on} ? JSON::true : JSON::false } if exists $cmd->{on};
	if (defined $cmd->{bri}) {
		# v2 counts brightness in percent; 0 would mean "lowest", not off
		my $pct = sprintf('%.1f', $cmd->{bri} / 2.54) + 0;
		$b{dimming} = { brightness => $pct < 0.4 ? 0.4 : $pct > 100 ? 100 : $pct };
	}
	$b{color} = { xy => { x => $cmd->{xy}[0] + 0, y => $cmd->{xy}[1] + 0 } } if $cmd->{xy};
	$b{color_temperature} = { mirek => $cmd->{ct} + 0 } if defined $cmd->{ct};
	$b{dynamics} = { duration => $cmd->{transition_ms} + 0 } if defined $cmd->{transition_ms} && $cmd->{on};
	return \%b;
}

sub _put {
	my ($self, $rtype, $uuid, $cmd, $label) = @_;
	my $body = body($cmd);
	my $res = $self->_request('PUT', "resource/$rtype/$uuid", $body);
	$self->_log(7, "PUT $label " . $self->{json}->encode($body) . ($res ? ' -> ok' : ' -> error'));
	return $res ? 1 : 0;
}

sub set_light {
	my ($self, $id, $cmd) = @_;
	$self->_ensure_mapped or return 0;
	my $uuid = $self->{lights}{$id};
	if (!$uuid) {
		$self->_log(4, "Light $id is unknown to the bridge");
		$self->{mapped} = 0;
		return 0;
	}
	return $self->_put('light', $uuid, $cmd, "light $id");
}

sub set_group {
	my ($self, $id, $cmd) = @_;
	$self->_ensure_mapped or return 0;
	my $uuid = $self->{groups}{$id};
	if (!$uuid) {
		$self->_log(4, "Group $id is unknown to the bridge");
		return 0;
	}
	return $self->_put('grouped_light', $uuid, $cmd, "group $id");
}

# Group 0 is the bridge's group of all lights
sub all_off {
	my ($self) = @_;
	return $self->set_group(0, { on => 0 });
}

sub get_light {
	my ($self, $id) = @_;
	$self->_ensure_mapped or return undef;
	my $uuid = $self->{lights}{$id} or return undef;
	my $s = $self->{state}{$uuid} or return undef;
	my $status = $self->{conn}{ $self->{device}{$uuid} // '' } // 'connected';
	return { %$s, reachable => $status eq 'connected' ? 1 : 0 };
}

sub list_lights {
	my ($self) = @_;
	my $res = $self->_request('GET', 'resource/light') or return {};
	my %out;
	for my $r (@{ $res->{data} || [] }) {
		my ($n) = ($r->{id_v1} // '') =~ m{^/lights/(\d+)$} or next;
		$out{$n} = $r->{metadata}{name} // $n;
	}
	return \%out;
}

1;
