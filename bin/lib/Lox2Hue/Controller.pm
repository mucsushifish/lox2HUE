package Lox2Hue::Controller;

# Lamp logic of the original Pico-C script, independent of input and driver:
#   - converts the Loxone value of a channel into a command
#   - power-on burst: after off->on, a lamp that had no power gets the command
#     again at fixed delays (powermode "cut" and "plug")
#   - watch: lamps behind a smart plug (powermode "plug") are polled one at a
#     time and corrected when the bridge reports a different state
#   - repeated OFF values are not sent again within off_repeat_ms
#   - channels with the same light share one state slot (last command wins)
#
# Times are in milliseconds. The daemon calls value() for every input and
# tick() regularly; now() can be replaced for tests.

use strict;
use warnings;
use Time::HiRes ();
use Lox2Hue::Convert qw(convert);

my %DEFAULTS = (
	transition_ms   => 1000,
	dimmer_min      => 15,
	dimmer_max      => 100,
	burst_ms        => [ 1000, 2000, 3500, 5000, 8000 ],
	watch_step_ms   => 1500,
	watch_settle_ms => 3000,
	watch_max_fixes => 3,
	watch_cut_lamps => 0,
	off_repeat_ms   => 30000,
	enable_burst    => 1,
	enable_watch    => 1,
);

sub new {
	my ($class, %args) = @_;
	my $self = bless {
		driver => $args{driver},
		log    => $args{log} || sub {},
		now    => $args{now} || sub { int(Time::HiRes::time() * 1000) },
		opts   => { %DEFAULTS, %{ $args{options} || {} } },
		channels   => {},
		order      => [],
		# lamp states of a previous controller survive a config reload
		slots      => $args{slots} || {},
		last_watch => 0,
		watch_pos  => 0,
	}, $class;
	$self->set_channels($args{channels} || []);
	return $self;
}

sub _log { my $self = shift; $self->{log}->(@_); }

# Channels: [{ id, type, target, target_id, powermode, sim_min, sim_max, enabled }]
sub set_channels {
	my ($self, $list) = @_;
	my %old_slots = %{ $self->{slots} };
	$self->{channels} = {};
	$self->{order}    = [];
	$self->{slots}    = {};
	for my $ch (@$list) {
		next if !defined $ch->{id} || $ch->{id} eq '';
		next if defined $ch->{enabled} && !$ch->{enabled};
		my %c = %$ch;
		$c{target}    ||= 'light';
		$c{powermode} ||= 'normal';
		$c{slot} = "$c{target}:$c{target_id}";
		$self->{channels}{ $c{id} } = \%c;
		push @{ $self->{order} }, $c{id};
		next if $self->{slots}{ $c{slot} };
		# Keep the state of lamps that are still configured
		my $slot = $old_slots{ $c{slot} } || _new_slot(\%c);
		$slot->{powermode} = $c{powermode};
		$self->{slots}{ $c{slot} } = $slot;
	}
	return;
}

sub _new_slot {
	my ($ch) = @_;
	return {
		target     => $ch->{target},
		target_id  => $ch->{target_id},
		powermode  => $ch->{powermode},
		on         => 0,
		cmd        => undef,
		burst      => undef,
		last_send  => 0,
		last_off   => undef,
		fixes      => 0,
		was_down   => 0,
	};
}

sub channel_ids { return @{ $_[0]{order} }; }

# Input from Loxone for a channel
sub value {
	my ($self, $id, $value) = @_;
	my $ch = $self->{channels}{$id};
	if (!$ch) {
		$self->_log(4, "Unknown or disabled channel '$id'");
		return;
	}
	if (!defined $value || $value !~ /^\s*-?\d+(?:\.\d+)?\s*$/) {
		$self->_log(4, "Channel $id: value is not a number");
		return;
	}
	my %copts = (%{ $self->{opts} }, sim_min => $ch->{sim_min} // 154, sim_max => $ch->{sim_max} // 500);
	my $type = $ch->{type};
	# drivers without hue/sat (Hue v2) get xy colours
	$type = 'rgb_xy' if $type eq 'rgb_hs' && $self->{driver}->can('color_space') && $self->{driver}->color_space eq 'xy';
	my $cmd = convert($type, $value + 0, \%copts);
	if (!$cmd) {
		$self->_log(4, "Channel $id: unknown type '$ch->{type}'");
		return;
	}
	$self->_log(6, "Channel $id value $value -> $ch->{slot}");
	$self->_send_smart($self->{slots}{ $ch->{slot} }, $cmd);
	return $cmd;
}

sub _send {
	my ($self, $slot, $cmd) = @_;
	my $ok = $slot->{target} eq 'group'
		? $self->{driver}->set_group($slot->{target_id}, $cmd)
		: $self->{driver}->set_light($slot->{target_id}, $cmd);
	$slot->{last_send} = $self->{now}->();
	return $ok;
}

sub _send_smart {
	my ($self, $slot, $cmd) = @_;
	my $now = $self->{now}->();

	if ($slot->{target} eq 'group' || $slot->{powermode} eq 'normal') {
		$self->_send($slot, $cmd);
		return;
	}

	if (!$cmd->{on}) {
		# e.g. a wake-up routine repeating 0 every second
		return if !$slot->{on} && defined $slot->{last_off}
			&& $now - $slot->{last_off} < $self->{opts}{off_repeat_ms};
		$self->_send($slot, $cmd);
		$slot->{last_off} = $now;
		$slot->{on}       = 0;
		$slot->{burst}    = undef;
		$slot->{cmd}      = undef;
		return;
	}

	$slot->{cmd}   = $cmd;
	$slot->{fixes} = 0;
	if (!$slot->{on}) {
		# off -> on: the lamp probably had no power, burst after power-on
		$slot->{on} = 1;
		$self->_start_burst($slot, $now);
	} elsif ($slot->{burst}) {
		# colour change during a burst: restart with the new command
		$self->_start_burst($slot, $now);
	}
	$self->_send($slot, $cmd);
	return;
}

sub _start_burst {
	my ($self, $slot, $now) = @_;
	return if !$self->{opts}{enable_burst};
	$slot->{fixes} = 0;
	$slot->{burst} = { start => $now, step => 0 };
	$self->_log(7, "$slot->{target} $slot->{target_id}: burst started");
	return;
}

# Same command without fading, for a lamp that has just been powered
sub _send_fast {
	my ($self, $slot) = @_;
	return if !$slot->{cmd};
	$self->_send($slot, { %{ $slot->{cmd} }, transition_ms => 0 });
	return;
}

sub all_off {
	my ($self) = @_;
	$self->_log(6, 'All lights off');
	$self->{driver}->all_off();
	for my $slot (values %{ $self->{slots} }) {
		$slot->{on}    = 0;
		$slot->{burst} = undef;
		$slot->{cmd}   = undef;
	}
	return;
}

sub tick {
	my ($self) = @_;
	my $drv = $self->{driver};
	$drv->poll if $drv->can('poll');
	$self->_process_bursts if $self->{opts}{enable_burst};
	if ($self->{opts}{enable_watch}) {
		$self->_check_changed if $drv->can('changed');
		$self->_watch_step;
	}
	return;
}

sub _process_bursts {
	my ($self) = @_;
	my $now   = $self->{now}->();
	my $steps = $self->{opts}{burst_ms};
	for my $slot (values %{ $self->{slots} }) {
		my $b = $slot->{burst} or next;
		next if $now - $b->{start} < $steps->[ $b->{step} ];
		$self->_send_fast($slot);
		$b->{step}++;
		$slot->{burst} = undef if $b->{step} >= @$steps;
	}
	return;
}

sub _watchable {
	my ($self, $slot, $now) = @_;
	return 0 if $slot->{target} ne 'light';
	return 0 if $slot->{powermode} eq 'normal';
	return 0 if $slot->{powermode} eq 'cut' && !$self->{opts}{watch_cut_lamps};
	return 0 if !$slot->{on} || $slot->{burst} || !$slot->{cmd};
	# wait until our own command including its fade is done
	my $settle = $self->{opts}{watch_settle_ms} + ($slot->{cmd}{transition_ms} || 0);
	return 0 if $now - $slot->{last_send} < $settle;
	return 1;
}

# Polls one lamp per call, round robin
sub _watch_step {
	my ($self) = @_;
	my $now = $self->{now}->();
	return if $now - $self->{last_watch} < $self->{opts}{watch_step_ms};
	$self->{last_watch} = $now;

	my @keys = sort keys %{ $self->{slots} };
	for (1 .. @keys) {
		$self->{watch_pos} = ($self->{watch_pos} + 1) % @keys;
		my $slot = $self->{slots}{ $keys[ $self->{watch_pos} ] };
		next if !$self->_watchable($slot, $now);
		$self->_check_slot($slot, $now);
		return;
	}
	return;
}

# Event from the bridge (driver v2): check the affected lamps right away
sub _check_changed {
	my ($self) = @_;
	my @ids = $self->{driver}->changed or return;
	my $now = $self->{now}->();
	for my $id (@ids) {
		my $slot = $self->{slots}{"light:$id"} or next;
		$self->_check_slot($slot, $now) if $self->_watchable($slot, $now);
	}
	return;
}

sub _check_slot {
	my ($self, $slot, $now) = @_;
	my $state = $self->{driver}->get_light($slot->{target_id});
	return if !$state;
	if (!$state->{reachable}) {
		$slot->{was_down} = 1;
		return;
	}
	if ($slot->{was_down}) {
		$slot->{was_down} = 0;
		$self->_log(6, "light $slot->{target_id} back online, burst");
		$self->_start_burst($slot, $now);
		return;
	}
	if (needs_fix($slot->{cmd}, $state)) {
		if ($slot->{fixes} >= $self->{opts}{watch_max_fixes}) {
			# do not resend forever, wait for the next command from Loxone
			if ($slot->{fixes} == $self->{opts}{watch_max_fixes}) {
				$self->_log(4, "light $slot->{target_id} still differs, giving up");
				$slot->{fixes}++;
			}
			return;
		}
		$slot->{fixes}++;
		$self->_log(6, "light $slot->{target_id} differs, resend $slot->{fixes}");
		$self->_send_fast($slot);
	} else {
		$slot->{fixes} = 0;
	}
	return;
}

# Desired command vs. state reported by the bridge; tolerances as in the script
sub needs_fix {
	my ($cmd, $st) = @_;
	return 1 if !$st->{on};
	return 1 if defined $cmd->{bri} && defined $st->{bri} && abs($st->{bri} - $cmd->{bri}) > 6;
	if (defined $cmd->{hue}) {
		return 1 if defined $st->{colormode} && $st->{colormode} ne 'hs';
		return 1 if defined $st->{hue} && abs($st->{hue} - $cmd->{hue}) > 1000;
		return 1 if defined $st->{sat} && defined $cmd->{sat} && abs($st->{sat} - $cmd->{sat}) > 10;
	} elsif ($cmd->{xy}) {
		return 1 if defined $st->{colormode} && $st->{colormode} ne 'xy';
	} elsif (defined $cmd->{ct}) {
		return 1 if defined $st->{colormode} && $st->{colormode} ne 'ct';
		return 1 if defined $st->{ct} && abs($st->{ct} - $cmd->{ct}) > 5;
	}
	return 0;
}

1;
