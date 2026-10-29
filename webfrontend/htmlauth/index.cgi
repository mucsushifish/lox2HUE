#!/usr/bin/perl

# lox2HUE web interface (LoxBerry Design System, no jQuery Mobile).
#
# Pages:  index.cgi                 settings and channels
#         index.cgi?form=logs       log files
# AJAX:   index.cgi?ajax=config     GET  current configuration
#         index.cgi?ajax=save       POST configuration (JSON body)
#         index.cgi?ajax=pair       POST create a bridge user (link button)
#         index.cgi?ajax=lights     GET  lights known to the bridge
#         index.cgi?ajax=test       POST send a value to a channel via MQTT

use strict;
use warnings;
use CGI;
use JSON;
use LoxBerry::System;
use LoxBerry::Web;
use LoxBerry::JSON;
use LoxBerry::Log;
use LoxBerry::IO;
use lib "$lbpbindir/lib";
use Lox2Hue::Driver::HueV1;
use Lox2Hue::Driver::HueV2;

my $cfgfile = "$lbpconfigdir/lox2hue.json";
my $cgi     = CGI->new;
my $q       = $cgi->Vars;
my $version = LoxBerry::System::pluginversion();

my @TYPES      = qw(rgb_hs rgb_xy brightness bulb onoff);
my @TARGETS    = qw(light group);
my @POWERMODES = qw(normal cut plug);
my @DRIVERS    = qw(huev2 huev1);
my @WAKE_TYPES = qw(rgb_hs rgb_xy brightness bulb);

# Query string parameters; with a JSON POST body CGI->Vars does not contain them
my $ajax = $cgi->url_param('ajax') // $q->{ajax};
if ($ajax) {
	ajax($ajax);
	exit;
}

my $form = ($cgi->url_param('form') // $q->{form} // '') eq 'logs' ? 'logs' : 'main';
my $template = LoxBerry::System::read_file("$lbptemplatedir/" . ($form eq 'logs' ? 'logs.html' : 'index.html'));
my $templateout = HTML::Template->new_scalar_ref(
	\$template,
	global_vars       => 1,
	loop_context_vars => 1,
	die_on_bad_params => 0,
);
my %L = LoxBerry::System::readlanguage($templateout, 'language.ini');

our %navbar;
$navbar{10}{Name}   = $L{'NAV.SETTINGS'};
$navbar{10}{URL}    = 'index.cgi';
$navbar{10}{active} = 1 if $form eq 'main';
$navbar{90}{Name}   = $L{'NAV.LOGS'};
$navbar{90}{URL}    = 'index.cgi?form=logs';
$navbar{90}{active} = 1 if $form eq 'logs';

$templateout->param('LBPPLUGINDIR', $lbpplugindir);
$templateout->param('LOGLIST', LoxBerry::Web::loglist_html()) if $form eq 'logs';

LoxBerry::Web::lbheader("lox2HUE V$version", 'https://github.com/mucsushifish/lox2hue', 'help.html', 'nojqm');
print LoxBerry::Log::get_notifications_html($lbpplugindir);
print $templateout->output();
LoxBerry::Web::lbfooter();
exit;

##########################################################################
# AJAX
##########################################################################

sub reply {
	my ($data, $status) = @_;
	print $cgi->header(-type => 'application/json', -charset => 'utf-8', -status => $status || 200);
	print JSON->new->canonical->encode($data);
	return;
}

sub read_config {
	my $c = LoxBerry::JSON->new->open(filename => $cfgfile, readonly => 1);
	return $c || {};
}

sub post_json {
	my $body = $cgi->param('POSTDATA') // '';
	return eval { decode_json($body) };
}

sub ajax {
	my ($action) = @_;

	if ($action eq 'config') {
		return reply(read_config());
	}

	if ($action eq 'save') {
		my $in = post_json();
		return reply({ error => 'invalid JSON' }, 400) if ref $in ne 'HASH';
		my ($clean, $err) = validate($in);
		return reply({ error => $err }, 400) if $err;
		my $obj = LoxBerry::JSON->new;
		my $cfg = $obj->open(filename => $cfgfile, lockexclusive => 1);
		return reply({ error => 'cannot open configuration' }, 500) if !$cfg;
		%$cfg = %$clean;
		$obj->write;
		return reply({ ok => 1 });
	}

	if ($action eq 'pair') {
		my $in = post_json() || {};
		my $host = $in->{host} // '';
		return reply({ error => 'invalid bridge address' }, 400) if $host !~ /^[A-Za-z0-9.\-:]+$/;
		my ($user, $err) = Lox2Hue::Driver::HueV1->pair(
			host       => $host,
			# API v2 is HTTPS only
			https      => ($in->{driver} // '') eq 'huev1' ? is_enabled($in->{https}) : 1,
			devicetype => 'lox2hue#' . substr(lbhostname(), 0, 19),
		);
		return reply({ error => $err }, 200) if !$user;
		return reply({ user => $user });
	}

	if ($action eq 'lights') {
		my $b = read_config()->{bridge} || {};
		return reply({ error => 'bridge not configured' }) if !$b->{host} || !$b->{user};
		my $drv = ($b->{driver} // '') eq 'huev1'
			? Lox2Hue::Driver::HueV1->new(host => $b->{host}, user => $b->{user}, https => is_enabled($b->{https}))
			: Lox2Hue::Driver::HueV2->new(host => $b->{host}, user => $b->{user}, no_events => 1);
		return reply({ lights => $drv->list_lights });
	}

	if ($action eq 'test') {
		my $in = post_json() || {};
		my $topic = read_config()->{mqtt}{topic} || 'lox2hue';
		return reply({ error => 'invalid channel' }, 400) if ($in->{channel} // '') !~ /^[A-Za-z0-9_\-]+$/;
		return reply({ error => 'invalid value' }, 400)   if ($in->{value} // '') !~ /^\d+(?:\.\d+)?$/;
		LoxBerry::IO::mqtt_publish("$topic/$in->{channel}", $in->{value});
		return reply({ ok => 1 });
	}

	return reply({ error => 'unknown action' }, 404);
}

# Keeps only known keys and checks values, so the daemon never reads garbage
sub validate {
	my ($in) = @_;
	my %out;
	my $b = $in->{bridge} || {};
	return (undef, 'invalid bridge address') if ($b->{host} // '') ne '' && $b->{host} !~ /^[A-Za-z0-9.\-:]+$/;
	return (undef, 'invalid API user') if ($b->{user} // '') =~ /[^A-Za-z0-9\-]/;
	my $driver = $b->{driver} // 'huev2';
	return (undef, 'invalid driver') if !grep { $_ eq $driver } @DRIVERS;
	$out{bridge} = {
		driver => $driver,
		host   => $b->{host} // '',
		user   => $b->{user} // '',
		https  => is_enabled($b->{https}) ? '1' : '0',
	};

	my $topic = $in->{mqtt}{topic} // 'lox2hue';
	return (undef, 'invalid MQTT topic') if $topic !~ m{^[A-Za-z0-9_\-/]+$} || $topic =~ m{^/|/$};
	$out{mqtt} = { topic => $topic };

	my $t = $in->{timing} || {};
	my %timing;
	for my $k (qw(transition_ms dimmer_min dimmer_max watch_step_ms watch_settle_ms watch_max_fixes off_repeat_ms)) {
		my $v = $t->{$k} // '';
		return (undef, "invalid value for $k") if $v !~ /^\d+$/;
		$timing{$k} = $v;
	}
	return (undef, 'dimmer_max must be greater than dimmer_min') if $timing{dimmer_max} <= $timing{dimmer_min};
	my $burst = $t->{burst_ms} // '';
	$burst =~ s/\s+//g;
	return (undef, 'invalid burst times') if $burst !~ /^\d+(?:,\d+)*$/;
	$timing{burst_ms} = $burst;
	$timing{$_} = is_enabled($t->{$_}) ? '1' : '0' for qw(enable_burst enable_watch watch_cut_lamps);
	$out{timing} = \%timing;

	my (@channels, %seen);
	for my $ch (@{ $in->{channels} || [] }) {
		my $id = $ch->{id} // '';
		return (undef, "invalid channel id '$id'") if $id !~ /^[A-Za-z0-9_\-]+$/ || $id eq 'alloff';
		return (undef, "duplicate channel id '$id'") if $seen{$id}++;
		my $type = $ch->{type} // '';
		return (undef, "channel $id: invalid type") if !grep { $_ eq $type } @TYPES;
		my $target = $ch->{target} // 'light';
		return (undef, "channel $id: invalid target") if !grep { $_ eq $target } @TARGETS;
		my $pm = $ch->{powermode} // 'normal';
		return (undef, "channel $id: invalid power mode") if !grep { $_ eq $pm } @POWERMODES;
		my $tid = $ch->{target_id} // '';
		return (undef, "channel $id: invalid lamp/group ID") if $tid !~ /^\d+$/;
		my ($smin, $smax) = ($ch->{sim_min} // 154, $ch->{sim_max} // 500);
		return (undef, "channel $id: colour temperature range must be 153-500") if $smin !~ /^\d+$/ || $smax !~ /^\d+$/ || $smin < 153 || $smax > 500 || $smin >= $smax;
		my $name = $ch->{name} // '';
		$name =~ s/[<>"&\x00-\x1f]//g;
		push @channels, {
			id        => $id,
			name      => substr($name, 0, 40),
			enabled   => is_enabled($ch->{enabled}) ? '1' : '0',
			type      => $type,
			target    => $target,
			target_id => $tid,
			powermode => $pm,
			sim_min   => $smin,
			sim_max   => $smax,
		};
	}
	$out{channels} = \@channels;

	my (@wakeups, %wseen);
	my %lamp_type = map { $_->{id} => $_->{type} } @channels;
	for my $w (@{ $in->{wakeups} || [] }) {
		my $id = $w->{id} // '';
		return (undef, "invalid light alarm id '$id'") if $id !~ /^[A-Za-z0-9_\-]+$/ || $id eq 'alloff';
		return (undef, "light alarm $id: id is already used by a channel") if $seen{$id};
		return (undef, "duplicate light alarm id '$id'") if $wseen{$id}++;
		my $ch = $w->{channel} // '';
		return (undef, "light alarm $id: lamp channel '$ch' does not exist") if !$lamp_type{$ch};
		return (undef, "light alarm $id: channel $ch cannot be dimmed up") if !grep { $_ eq $lamp_type{$ch} } @WAKE_TYPES;
		my $ramp = $w->{ramp_min} // '';
		return (undef, "light alarm $id: fade-up time must be 1-240 minutes") if $ramp !~ /^\d+$/ || $ramp < 1 || $ramp > 240;
		my %col;
		for my $k (qw(r g b)) {
			my $v = $w->{$k} // '';
			return (undef, "light alarm $id: colour values must be 0-100") if $v !~ /^\d+$/ || $v > 100;
			$col{$k} = $v;
		}
		return (undef, "light alarm $id: target colour is black") if $lamp_type{$ch} =~ /^rgb/ && !($col{r} + $col{g} + $col{b});
		my $name = $w->{name} // '';
		$name =~ s/[<>"&\x00-\x1f]//g;
		push @wakeups, {
			id       => $id,
			name     => substr($name, 0, 40),
			enabled  => is_enabled($w->{enabled}) ? '1' : '0',
			channel  => $ch,
			ramp_min => $ramp,
			%col,
		};
	}
	$out{wakeups} = \@wakeups;
	return (\%out, undef);
}
