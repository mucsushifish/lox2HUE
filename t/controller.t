#!/usr/bin/perl
# Burst, watch and off-repeat logic with a fake driver and a fake clock

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../bin/lib";
use Test::More;
use Lox2Hue::Controller;

package FakeDriver {
	sub new { bless { sent => [], state => {} }, shift }
	sub set_light { my ($s, $id, $c) = @_; push @{ $s->{sent} }, [ 'light', $id, {%$c} ]; 1 }
	sub set_group { my ($s, $id, $c) = @_; push @{ $s->{sent} }, [ 'group', $id, {%$c} ]; 1 }
	sub all_off   { my ($s) = @_; push @{ $s->{sent} }, [ 'alloff' ]; 1 }
	sub get_light { my ($s, $id) = @_; $s->{polled}++; $s->{state}{$id} }
	sub take      { my ($s) = @_; my @x = @{ $s->{sent} }; $s->{sent} = []; @x }
}

my $t = 0;
my $drv = FakeDriver->new;
my $c = Lox2Hue::Controller->new(
	driver   => $drv,
	now      => sub { $t },
	channels => [
		{ id => '1', type => 'rgb_hs',     target_id => 3, powermode => 'plug' },
		{ id => '2', type => 'brightness', target_id => 4, powermode => 'cut' },
		{ id => '3', type => 'rgb_hs',     target_id => 5 },
		{ id => '6', type => 'rgb_hs',     target_id => 3, powermode => 'plug' },
		{ id => 'g', type => 'rgb_hs',     target => 'group', target_id => 1 },
		{ id => 'x', type => 'rgb_hs',     target_id => 9, enabled => 0 },
	],
);

sub run_until { my ($end) = @_; while ($t < $end) { $t += 100; $c->tick } }

# normal lamp: one send, no burst
$c->value('3', 100);
my @s = $drv->take;
is(scalar @s, 1, 'normal: sent once');
run_until(10000);
is(scalar $drv->take, 0, 'normal: no burst');

# cut lamp: immediate send + 5 burst sends without transition
$t = 20000;
$c->value('2', 50);
@s = $drv->take;
is(scalar @s, 1, 'cut: immediate send');
run_until(29000);
@s = $drv->take;
is(scalar @s, 5, 'cut: 5 burst sends');
is($s[0][2]{transition_ms}, 0, 'burst sends without transition');

# repeated OFF is suppressed for off_repeat_ms
$c->value('2', 0);
is(scalar $drv->take, 1, 'off sent');
$t += 1000;
$c->value('2', 0);
is(scalar $drv->take, 0, 'repeated off suppressed');
$t += 30000;
$c->value('2', 0);
is(scalar $drv->take, 1, 'off sent again after 30 s');

# group: always direct
$c->value('g', 100);
@s = $drv->take;
is_deeply([ $s[0][0], $s[0][1] ], [ 'group', 1 ], 'group target');

# plug lamp: burst, then watch corrects a differing state, max 3 times
$t = 100000;
$c->value('1', 100);    # red: hue 0, sat 254, bri 254
run_until(109000);
$drv->take;
$drv->{state}{3} = { reachable => 1, on => 0 };
run_until(130000);
@s = grep { $_->[0] eq 'light' && $_->[1] == 3 } $drv->take;
is(scalar @s, 3, 'watch: resent 3 times, then gives up');

# a new command from Loxone allows fixing again; matching state needs no fix
$c->value('1', 100);
$drv->{state}{3} = { reachable => 1, on => 1, bri => 254, colormode => 'hs', hue => 0, sat => 254 };
run_until(160000);
@s = grep { $_->[2]{transition_ms} == 0 } $drv->take;
is(scalar @s, 0, 'watch: no resend when state matches');

# lamp offline then back (found by watching) -> send at once, then 2 confirmations
$drv->{state}{3} = { reachable => 0, on => 0 };
run_until(165000);
$drv->{state}{3} = { reachable => 1, on => 1, bri => 254, colormode => 'hs', hue => 0, sat => 254 };
run_until(175000);
@s = $drv->take;
is(scalar @s, 3, 'back online: immediate send plus 2 confirmations');

# channel 6 shares the slot of channel 1 (same lamp)
$c->value('6', 0);
is(scalar $drv->take, 1, 'shared slot: off sent');
$c->value('1', 0);
is(scalar $drv->take, 0, 'shared slot: second off suppressed');

# disabled and unknown channels are ignored
is($c->value('x', 100), undef, 'disabled channel ignored');
is($c->value('nope', 100), undef, 'unknown channel ignored');
is($c->value('1', 'abc'), undef, 'non-numeric value ignored');

# all off resets the state, so a later burst does not switch lamps on again
$c->value('2', 100);
$c->all_off;
$drv->take;
run_until($t + 10000);
is(scalar $drv->take, 0, 'all off cancels running bursts');

# Driver with events (API v2), as in the log of 2026-10-29: a lamp whose power
# Loxone switches is unreachable when switched on and reported back ~2.7 s later
package EventDriver {
	our @ISA = ('FakeDriver');
	sub changed { my ($s) = @_; my @c = @{ $s->{changed} || [] }; $s->{changed} = []; @c }
}
my $ed = EventDriver->new;
$t = 0;
my $ec = Lox2Hue::Controller->new(
	driver   => $ed,
	now      => sub { $t },
	channels => [ { id => '3', type => 'rgb_xy', target_id => 2, powermode => 'cut' } ],
);
$ed->{state}{2} = { reachable => 0, on => 0 };
$ec->value('3', 64078084);
is(scalar $ed->take, 1, 'event driver: first send at once');
for (1 .. 27) { $t += 100; $ec->tick }
$ed->take;
$ed->{state}{2} = { reachable => 1, on => 0 };
$ed->{changed} = [ 2 ];
$t += 100;
$ec->tick;
my @now = $ed->take;
is(scalar @now, 1, 'event driver: command sent on the connected event');
is($now[0][2]{transition_ms}, 0, 'without transition');
$t += 900;  $ec->tick;
is(scalar $ed->take, 0, 'remaining power-on burst replaced');
$t += 100;  $ec->tick;
is(scalar $ed->take, 1, 'confirmation after 1 s');
for (1 .. 50) { $t += 100; $ec->tick }
is(scalar $ed->take, 1, 'second confirmation, then quiet');

done_testing();
