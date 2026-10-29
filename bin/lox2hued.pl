#!/usr/bin/perl

# lox2hue daemon
#
# Subscribes to <topic>/<channel> on the LoxBerry MQTT broker. Loxone sends the
# raw value of a virtual output there, e.g. via UDP to the MQTT Gateway:
#   lox2hue/1 37042011
# <topic>/alloff with a value other than 0 switches all lights off.
# The daemon converts the value and sends it to the bridge (see Lox2Hue::*).

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Time::HiRes qw(sleep);
use LoxBerry::System;
use LoxBerry::IO;
use LoxBerry::Log;
use LoxBerry::JSON;
use Lox2Hue::Controller;
use Lox2Hue::Driver::HueV1;
use Lox2Hue::Driver::HueV2;

my $cfgfile = "$lbpconfigdir/lox2hue.json";
my $running = 1;

my $log = LoxBerry::Log->new(
	name    => 'daemon',
	package => $lbpplugindir,
	addtime => 1,
	stderr  => 1,
);
LOGSTART('lox2hue daemon started');

# Severity numbers as used by LoxBerry::Log
my %logfn = (3 => \&LOGERR, 4 => \&LOGWARN, 6 => \&LOGINF, 7 => \&LOGDEB);
sub logmsg {
	my ($sev, $msg) = @_;
	($logfn{$sev} || \&LOGINF)->($msg);
}

$SIG{TERM} = $SIG{INT} = sub { $running = 0; };

my ($cfg, $cfg_mtime) = load_config();
my $controller = build_controller($cfg);
my $topic = $cfg->{mqtt}{topic} || 'lox2hue';

my $mqtt = LoxBerry::IO::mqtt_connect();
if (!$mqtt) {
	LOGCRIT('Could not connect to the MQTT broker, exiting');
	LOGEND();
	exit 1;
}
$mqtt->subscribe("$topic/+", \&on_message);
LOGOK("Subscribed to $topic/+");

my $last_cfg_check = 0;
while ($running) {
	my $connected = eval { $mqtt->tick(0.05) };
	LOGERR("MQTT: $@") if $@;
	sleep(0.05) if !$connected;

	eval { $controller->tick; 1 } or LOGERR("Controller: $@");

	# Reload when the web UI saved a new configuration
	if (time() - $last_cfg_check >= 2) {
		$last_cfg_check = time();
		my $mtime = (stat $cfgfile)[9] // 0;
		if ($mtime != $cfg_mtime) {
			LOGINF('Configuration changed, reloading');
			($cfg, $cfg_mtime) = load_config();
			$controller = build_controller($cfg, $controller);
			my $new_topic = $cfg->{mqtt}{topic} || 'lox2hue';
			if ($new_topic ne $topic) {
				$mqtt->unsubscribe("$topic/+");
				$topic = $new_topic;
				$mqtt->subscribe("$topic/+", \&on_message);
				LOGOK("Subscribed to $topic/+");
			}
		}
	}
}

LOGINF('Stopping');
eval { $mqtt->disconnect };
LOGEND('lox2hue daemon stopped');
exit 0;

sub on_message {
	my ($t, $payload) = @_;
	my ($channel) = $t =~ m{/([^/]+)$};
	return if !defined $channel;
	$payload = '' if !defined $payload;
	$payload =~ s/^\s+|\s+$//g;
	LOGDEB("MQTT $t = $payload");
	eval {
		if ($channel eq 'alloff') {
			$controller->all_off if $payload ne '' && $payload != 0;
		} else {
			$controller->value($channel, $payload);
		}
		1;
	} or LOGERR("Channel $channel: $@");
}

sub load_config {
	my $mtime = (stat $cfgfile)[9] // 0;
	my $c = eval { LoxBerry::JSON->new->open(filename => $cfgfile, readonly => 1) };
	if (!$c) {
		LOGERR("Could not read $cfgfile");
		$c = {};
	}
	return ($c, $mtime);
}

sub build_driver {
	my ($c) = @_;
	my $b = $c->{bridge} || {};
	my $driver = $b->{driver} || 'huev2';
	LOGWARN('No bridge address or API user configured') if !$b->{host} || !$b->{user};
	if ($driver eq 'huev1') {
		LOGINF('Driver: Hue API v1');
		return Lox2Hue::Driver::HueV1->new(
			host  => $b->{host} || '',
			user  => $b->{user} || '',
			https => is_enabled($b->{https}),
			log   => \&logmsg,
		);
	}
	LOGERR("Unknown driver '$driver', using huev2") if $driver ne 'huev2';
	LOGINF('Driver: Hue API v2 with event stream');
	return Lox2Hue::Driver::HueV2->new(
		host => $b->{host} || '',
		user => $b->{user} || '',
		log  => \&logmsg,
	);
}

sub build_controller {
	my ($c, $old) = @_;
	my $t = $c->{timing} || {};
	my %opts;
	for my $k (qw(transition_ms dimmer_min dimmer_max watch_step_ms watch_settle_ms watch_max_fixes off_repeat_ms)) {
		$opts{$k} = $t->{$k} + 0 if defined $t->{$k} && $t->{$k} =~ /^\d+$/;
	}
	for my $k (qw(enable_burst enable_watch watch_cut_lamps)) {
		$opts{$k} = is_enabled($t->{$k}) ? 1 : 0 if defined $t->{$k};
	}
	if (defined $t->{burst_ms}) {
		my @steps = grep { /^\d+$/ } split /\s*,\s*/, $t->{burst_ms};
		$opts{burst_ms} = \@steps if @steps;
	}
	my @channels = @{ $c->{channels} || [] };
	$_->{enabled} = is_enabled($_->{enabled}) ? 1 : 0 for @channels;

	my $b = $c->{bridge} || {};
	my $bridge_key = join '|', map { $_ // '' } @$b{qw(driver host user https)};
	my $driver = $old && $old->{bridge_key} eq $bridge_key ? $old->{driver} : build_driver($c);

	my $ctl = Lox2Hue::Controller->new(
		driver   => $driver,
		log      => \&logmsg,
		options  => \%opts,
		slots    => $old ? $old->{slots} : undef,
		channels => \@channels,
	);
	$ctl->{bridge_key} = $bridge_key;
	LOGINF(scalar($ctl->channel_ids) . ' channel(s) active');
	return $ctl;
}
