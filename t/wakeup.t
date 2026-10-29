#!/usr/bin/perl
# Light alarm: ramp, hold, end by Loxone, takeover by the lamp channel

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../bin/lib";
use Test::More;
use Lox2Hue::Wakeup;

package FakeController;
sub new { bless { sent => [], types => $_[1] }, $_[0] }
sub channel_type { $_[0]{types}{ $_[1] } }
sub value { push @{ $_[0]{sent} }, [ $_[1], $_[2] ]; }
package main;

my $now = 0;
my $ctl = FakeController->new({ 1 => 'rgb_hs', 2 => 'brightness' });
my $w = Lox2Hue::Wakeup->new(
	controller => $ctl,
	now        => sub { $now },
	wakeups    => [
		{ id => 'w1', channel => '1', ramp_min => 10, r => 100, g => 83, b => 70, enabled => 1 },
		{ id => 'w2', channel => '2', ramp_min => 1, enabled => 1 },
		{ id => 'off', channel => '1', ramp_min => 1, enabled => 0 },
	],
);

ok($w->has('w1'), 'wake-up channel known');
ok(!$w->has('off'), 'disabled wake-up ignored');
ok(!$w->value('1', 50), 'lamp channel is not a wake-up channel');

is(Lox2Hue::Wakeup::output({ r => 100, g => 83, b => 70 }, 'rgb_hs', 1), 70083100, 'full colour in Loxone notation');
is(Lox2Hue::Wakeup::output({ r => 100, g => 83, b => 70 }, 'rgb_hs', 0.5), 35042050, 'half way');
is(Lox2Hue::Wakeup::output({}, 'brightness', 0.25), 25, 'dimmer channel gets percent');

# start: nothing is sent while every colour still rounds to 0
ok($w->value('w1', 1), 'start');
is(scalar @{ $ctl->{sent} }, 0, 'value 0 at the start is not sent');
$now = 3000;
$w->tick;
is_deeply($ctl->{sent}[-1], [ 1, 1 ], 'first step after 3 s: 1 % red, green and blue still 0') or diag explain $ctl->{sent};

# repeated 1 from Loxone does not restart
$w->value('w1', 1);
$now = 300_000;
$w->tick;
is($ctl->{sent}[-1][1], 35042050, 'half of the ramp after 5 of 10 minutes');
my $n = @{ $ctl->{sent} };
$now += 500;
$w->tick;
is(scalar @{ $ctl->{sent} }, $n, 'at most one value per second');

$now = 600_000;
$w->tick;
is($ctl->{sent}[-1][1], 70083100, 'full colour at the end of the ramp');
$n = @{ $ctl->{sent} };
$now = 900_000;
$w->tick;
is(scalar @{ $ctl->{sent} }, $n, 'held without further values');

ok($w->value('w1', 0), 'end');
is_deeply($ctl->{sent}[-1], [ 1, 0 ], 'lamp switched off at the end');
$n = @{ $ctl->{sent} };
$w->value('w1', 0);
is(scalar @{ $ctl->{sent} }, $n, 'second 0 sends nothing');

# Loxone uses the lamp channel during the routine: routine stops, lamp stays
$now = 1_000_000;
$w->value('w2', 1);
$now += 30_000;
$w->tick;
is_deeply($ctl->{sent}[-1], [ 2, 50 ], 'dimmer channel half way after 30 s');
$w->channel_used('2');
ok(!%{ $w->running }, 'routine stopped by lamp channel');
$n = @{ $ctl->{sent} };
$w->value('w2', 0);
is(scalar @{ $ctl->{sent} }, $n, 'end after takeover does not switch off');

# running routines survive a reload
$w->value('w1', 1);
my $w2 = Lox2Hue::Wakeup->new(controller => $ctl, now => sub { $now }, running => $w->running,
	wakeups => [ { id => 'w1', channel => '1', ramp_min => 10, r => 100, g => 83, b => 70 } ]);
ok($w2->running->{w1}, 'routine kept after reload');
my $w3 = Lox2Hue::Wakeup->new(controller => $ctl, now => sub { $now }, running => $w2->running, wakeups => []);
ok(!$w3->running->{w1}, 'routine dropped when its wake-up channel is removed');

$w->value('w1', 1);
$w->stop_all;
ok(!%{ $w->running }, 'alloff stops running routines');

done_testing();
