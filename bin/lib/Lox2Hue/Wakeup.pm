package Lox2Hue::Wakeup;

# Light alarm (port of Ingbert's "Lichtwecker" Pico-C routine).
#
# A wake-up channel is switched by the output of a Loxone alarm clock block:
#   value <> 0  starts the routine, the linked lamp channel is faded from 0 to
#               the configured colour within ramp_min minutes and then held
#   value 0     ends the routine and switches the lamp off
# How long the light stays on is therefore set by the buzzer duration in
# Loxone. The routine sends ordinary values to the linked lamp channel, so
# conversion, power-on burst and watching of that channel apply as usual.
# A value that Loxone sends to the linked lamp channel itself during the
# routine takes over: the routine stops without switching the lamp off.
# alloff stops all routines.

use strict;
use warnings;
use Time::HiRes ();

sub new {
	my ($class, %args) = @_;
	my $self = bless {
		controller => $args{controller},
		log        => $args{log} || sub {},
		now        => $args{now} || sub { int(Time::HiRes::time() * 1000) },
		min_step_ms => $args{min_step_ms} // 1000,
		wakeups    => {},
		# running routines survive a config reload
		running    => $args{running} || {},
	}, $class;
	$self->set_wakeups($args{wakeups} || []);
	return $self;
}

sub _log { my $self = shift; $self->{log}->(@_); }

# Wake-ups: [{ id, channel, ramp_min, r, g, b, enabled }], colour in % (0..100)
sub set_wakeups {
	my ($self, $list) = @_;
	$self->{wakeups} = {};
	for my $w (@$list) {
		next if !defined $w->{id} || $w->{id} eq '';
		next if defined $w->{enabled} && !$w->{enabled};
		$self->{wakeups}{ $w->{id} } = { %$w };
	}
	for my $id (keys %{ $self->{running} }) {
		delete $self->{running}{$id} if !$self->{wakeups}{$id};
	}
	return;
}

sub has { return exists $_[0]{wakeups}{ $_[1] }; }

sub running { return $_[0]{running}; }

sub value {
	my ($self, $id, $value) = @_;
	my $w = $self->{wakeups}{$id} or return 0;
	if (!defined $value || $value !~ /^\s*-?\d+(?:\.\d+)?\s*$/) {
		$self->_log(4, "Wake-up $id: value is not a number");
		return 1;
	}
	my $run = $self->{running}{$id};
	if ($value != 0) {
		return 1 if $run;    # already running, Loxone repeats the value
		$self->_log(6, "Wake-up $id started, channel $w->{channel}, $w->{ramp_min} min");
		$self->{running}{$id} = { start => $self->{now}->(), last_out => -1, last_send => 0 };
		$self->_step($id);
		return 1;
	}
	return 1 if !$run;
	delete $self->{running}{$id};
	$self->_log(6, "Wake-up $id ended, channel $w->{channel} off");
	$self->{controller}->value($w->{channel}, 0) if $run->{last_out} > 0;
	return 1;
}

# Loxone sent a value to a lamp channel: routines on that channel give way
sub channel_used {
	my ($self, $channel) = @_;
	for my $id (keys %{ $self->{running} }) {
		next if $self->{wakeups}{$id}{channel} ne $channel;
		delete $self->{running}{$id};
		$self->_log(6, "Wake-up $id stopped, channel $channel was set by Loxone");
	}
	return;
}

# All lights off from Loxone: running routines must not switch them on again
sub stop_all {
	my ($self) = @_;
	$self->_log(6, 'Wake-up ' . join(', ', sort keys %{ $self->{running} }) . ' stopped by alloff') if %{ $self->{running} };
	$self->{running} = {};
	return;
}

sub tick {
	my ($self) = @_;
	$self->_step($_) for keys %{ $self->{running} };
	return;
}

# Value of the linked channel at the given part (0..1) of the ramp
sub output {
	my ($w, $type, $f) = @_;
	if ($type eq 'brightness' || $type eq 'bulb') {
		return int($f * 100 + 0.5);
	}
	my ($r, $g, $b) = map { int($f * ($w->{$_} // 0) + 0.5) } qw(r g b);
	return $r + $g * 1000 + $b * 1000000;
}

sub _step {
	my ($self, $id) = @_;
	my $run = $self->{running}{$id};
	my $w   = $self->{wakeups}{$id};
	my $now = $self->{now}->();
	return if $run->{done};
	return if $run->{last_send} && $now - $run->{last_send} < $self->{min_step_ms};

	my $ramp = ($w->{ramp_min} || 0) * 60000;
	my $f = $ramp > 0 ? ($now - $run->{start}) / $ramp : 1;
	$f = 1 if $f > 1;
	my $type = $self->{controller}->channel_type($w->{channel});
	if (!$type) {
		$self->_log(4, "Wake-up $id: channel $w->{channel} is unknown or disabled");
		$run->{done} = 1;
		return;
	}
	my $out = output($w, $type, $f);
	if ($out > 0 && $out != $run->{last_out}) {
		$self->{controller}->value($w->{channel}, $out);
		$run->{last_out}  = $out;
		$run->{last_send} = $now;
	}
	if ($f >= 1) {
		$run->{done} = 1;
		$self->_log(6, "Wake-up $id: full brightness reached");
	}
	return;
}

1;
