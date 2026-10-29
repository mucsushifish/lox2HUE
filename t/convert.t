#!/usr/bin/perl
# Expected values were generated from the math of the original Pico-C script
# (HUE_MitSchalter_v02_2026), compiled as C with double precision.
# Differences on purpose: bri is clamped to 254 and mired to 153-500.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../bin/lib";
use Test::More;
use Lox2Hue::Convert qw(convert decode_rgb lumitech_to_ctbri);

my %opts = (transition_ms => 1000, dimmer_min => 15, dimmer_max => 100, sim_min => 154, sim_max => 500);

sub check {
	my ($type, $cases) = @_;
	for my $case (@$cases) {
		my ($in, $want) = @$case;
		my $got = convert($type, $in, \%opts);
		delete $got->{transition_ms};
		is_deeply($got, $want, "$type $in");
	}
}

is_deeply([ decode_rgb(37042011) ], [ 11, 42, 37 ], 'decode R + G*1000 + B*1000000');

# RGB -> hue/sat/bri
check('rgb_hs', [
	[0, {on=>0}],
	[100, {on=>1, bri=>254, hue=>0, sat=>254}],
	[100100, {on=>1, bri=>254, hue=>10922, sat=>254}],
	[100100100, {on=>1, bri=>254, hue=>0, sat=>0}],
	[100000, {on=>1, bri=>254, hue=>21845, sat=>254}],
	[100000000, {on=>1, bri=>254, hue=>43690, sat=>254}],
	[50, {on=>1, bri=>127, hue=>0, sat=>254}],
	[37042011, {on=>1, bri=>107, hue=>31005, sat=>188}],
	[10020030, {on=>1, bri=>76, hue=>5461, sat=>170}],
	[100050000, {on=>1, bri=>254, hue=>38228, sat=>254}],
	[1001, {on=>1, bri=>2, hue=>10922, sat=>254}],
	[100000100, {on=>1, bri=>254, hue=>54612, sat=>254}],
	[25025000, {on=>1, bri=>63, hue=>32767, sat=>254}],
	[99001050, {on=>1, bri=>252, hue=>49151, sat=>252}],
	[33066099, {on=>1, bri=>252, hue=>5461, sat=>170}],
	[1, {on=>1, bri=>2, hue=>0, sat=>254}],
	[1000000, {on=>1, bri=>2, hue=>43690, sat=>254}],
]);

# Lumitech -> ct/bri
check('rgb_hs', [
	[200000000, {on=>0}],
	[201002700, {on=>1, bri=>254, ct=>370}],
	[205004000, {on=>1, bri=>254, ct=>250}],
	[210006500, {on=>1, bri=>254, ct=>154}],
	[210002000, {on=>1, bri=>254, ct=>500}],
	[200506500, {on=>1, bri=>127, ct=>154}],
]);

check('rgb_xy', [
	[0, {on=>0}],
]);

check('brightness', [
	[0, {on=>0}],
	[15, {on=>1, bri=>1}],
	[20, {on=>1, bri=>15}],
	[50, {on=>1, bri=>105}],
	[85, {on=>1, bri=>210}],
	[99, {on=>1, bri=>252}],
	[100, {on=>1, bri=>254}],
]);

check('bulb', [
	[0, {on=>0}],
	[15, {on=>1, bri=>1, ct=>500}],
	[20, {on=>1, bri=>15, ct=>436}],
	[50, {on=>1, bri=>105, ct=>267}],
	[85, {on=>1, bri=>210, ct=>179}],
	[99, {on=>1, bri=>252, ct=>155}],
	[100, {on=>1, bri=>254, ct=>154}],
]);

is_deeply(lumitech_to_ctbri(201000000, 0), { on => 1, bri => 254, transition_ms => 0 },
	'Lumitech with 0 Kelvin sends brightness only');

my $xy = convert('rgb_xy', 100, \%opts);
is($xy->{bri}, 254, 'xy: full red brightness');
ok(abs($xy->{xy}[0] - 0.7236) < 0.0002 && abs($xy->{xy}[1] - 0.2609) < 0.0002, 'xy: full red near (0.7236, 0.2609) (matrix of the script)')
	or diag explain $xy;

is_deeply(convert('onoff', 0, \%opts),  { on => 0 }, 'onoff 0');
is_deeply(convert('onoff', 42, \%opts), { on => 1 }, 'onoff 42');

done_testing();
