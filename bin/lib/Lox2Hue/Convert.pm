package Lox2Hue::Convert;

# Converts Loxone values into driver-neutral lamp commands.
#
# Ported from the Pico-C script HUE_MitSchalter_v02_2026. A command is a hash:
#   { on => 0|1, bri => 1..254, hue => 0..65535, sat => 0..254,
#     xy => [x, y], ct => mired, transition_ms => n }
# Only the keys that apply are set. Drivers translate it to their API.

use strict;
use warnings;
use POSIX qw(floor);
use Exporter 'import';

our @EXPORT_OK = qw(
	decode_rgb is_lumitech
	rgb_to_hsb rgb_to_xyb lumitech_to_ctbri
	dimmer_to_bri dimmer_to_bulb onoff
	convert
);

use constant LUMITECH_OFFSET => 200000000;

sub _clamp {
	my ($v, $min, $max) = @_;
	return $min if $v < $min;
	return $max if $v > $max;
	return $v;
}

# Loxone compact RGB: R + G*1000 + B*1000000, each 0-100 %
sub decode_rgb {
	my ($value) = @_;
	my $blue  = floor($value / 1000000);
	my $green = floor(($value - $blue * 1000000) / 1000);
	my $red   = $value - $blue * 1000000 - $green * 1000;
	return ($red, $green, $blue);
}

# Lumitech: 2BBBTTTT (brightness 0-100 %, colour temperature in Kelvin)
sub is_lumitech {
	my ($value) = @_;
	return $value >= LUMITECH_OFFSET ? 1 : 0;
}

sub rgb_to_hsb {
	my ($value, $transition_ms) = @_;
	my ($red, $green, $blue) = decode_rgb($value);
	my ($hue, $sat, $bri) = (0, 0, 0);

	if ($blue > 0 || $green > 0 || $red > 0) {
		# Same case order as the original script, so ties resolve identically
		if ($red >= $green && $green >= $blue) {
			$hue = $red == $blue ? 0 : 60 * ($green - $blue) / ($red - $blue);
			$sat = ($red - $blue) / $red; $bri = $red;
		} elsif ($green > $red && $red >= $blue) {
			$hue = 60 * (2 - ($red - $blue) / ($green - $blue));
			$sat = ($green - $blue) / $green; $bri = $green;
		} elsif ($green >= $blue && $blue > $red) {
			$hue = 60 * (2 + ($blue - $red) / ($green - $red));
			$sat = ($green - $red) / $green; $bri = $green;
		} elsif ($blue > $green && $green > $red) {
			$hue = 60 * (4 - ($green - $red) / ($blue - $red));
			$sat = ($blue - $red) / $blue; $bri = $blue;
		} elsif ($blue > $red && $red >= $green) {
			$hue = 60 * (4 + ($red - $green) / ($blue - $green));
			$sat = ($blue - $green) / $blue; $bri = $blue;
		} elsif ($red >= $blue && $blue > $green) {
			$hue = 60 * (6 - ($blue - $green) / ($red - $green));
			$sat = ($red - $green) / $red; $bri = $red;
		}
		$hue = $hue / 360 * 65535;
		$sat = _clamp($sat * 255, 0, 254);
		$bri = _clamp($bri * 2.55, 0, 254);
	}

	return { on => 0 } if int($bri) == 0;
	return {
		on            => 1,
		bri           => int($bri),
		hue           => int($hue),
		sat           => int($sat),
		transition_ms => $transition_ms,
	};
}

sub _gamma {
	my ($c) = @_;
	# sRGB threshold 0.04045 (the original script used 0.04055)
	return $c > 0.04045 ? (($c + 0.055) / 1.055) ** 2.4 : $c / 12.92;
}

sub rgb_to_xyb {
	my ($value, $transition_ms) = @_;
	my ($red, $green, $blue) = decode_rgb($value);

	my $bri = $blue;
	$bri = $green if $bri < $green;
	$bri = $red   if $bri < $red;
	$bri = _clamp($bri * 2.55, 0, 254);
	return { on => 0 } if int($bri) == 0;

	my $r = _gamma($red / 100);
	my $g = _gamma($green / 100);
	my $b = _gamma($blue / 100);

	# RGB -> XYZ (D65, wide gamut), as in the original script
	my $X = $r * 0.649926 + $g * 0.103455 + $b * 0.197109;
	my $Y = $r * 0.234327 + $g * 0.743075 + $b * 0.022598;
	my $Z = $r * 0.013932 + $g * 0.053077 + $b * 1.035763;
	my $sum = $X + $Y + $Z;
	my ($cx, $cy) = $sum == 0 ? (0, 0) : ($X / $sum, $Y / $sum);

	return {
		on            => 1,
		bri           => int($bri),
		xy            => [ sprintf('%.4f', $cx) + 0, sprintf('%.4f', $cy) + 0 ],
		transition_ms => $transition_ms,
	};
}

sub lumitech_to_ctbri {
	my ($value, $transition_ms) = @_;
	my $raw    = $value - LUMITECH_OFFSET;
	my $bri    = floor($raw / 10000);        # 0-100 %
	my $kelvin = floor($raw - $bri * 10000); # e.g. 2700-6500

	return { on => 0 } if $bri == 0;
	my %cmd = (
		on            => 1,
		bri           => _clamp(sprintf('%.0f', $bri * 2.55), 1, 254) + 0,
		transition_ms => $transition_ms,
	);
	# Hue accepts 153-500 mired; a Kelvin value of 0 would divide by zero
	$cmd{ct} = _clamp(sprintf('%.0f', 1000000 / $kelvin), 153, 500) + 0 if $kelvin > 0;
	return \%cmd;
}

# Loxone dimmer % -> Hue bri, scaled between dimmer_min and dimmer_max
sub _dimmer_scale {
	my ($value, $dmin, $dmax) = @_;
	return 0 if $value <= 0;
	my $bri = ($value - $dmin) / ($dmax - $dmin) * 254 + 1;
	return _clamp($bri, 1, 254);
}

sub dimmer_to_bri {
	my ($value, $opts) = @_;
	my $bri = _dimmer_scale($value, $opts->{dimmer_min}, $opts->{dimmer_max});
	return { on => 0 } if $bri == 0;
	return { on => 1, bri => int($bri), transition_ms => $opts->{transition_ms} };
}

# "als Bulb": warmer colour temperature when dimmed down (log curve)
sub dimmer_to_bulb {
	my ($value, $opts) = @_;
	my $bri = _dimmer_scale($value, $opts->{dimmer_min}, $opts->{dimmer_max});
	return { on => 0 } if $bri == 0;
	my $span = $opts->{sim_max} - $opts->{sim_min};
	my $ct = $opts->{sim_max} - $span * log(1 + (($bri - 1) / 254) * 9) / log(10);
	return {
		on            => 1,
		bri           => int($bri),
		ct            => int($ct),
		transition_ms => $opts->{transition_ms},
	};
}

sub onoff {
	my ($value) = @_;
	return { on => $value == 0 ? 0 : 1 };
}

# Dispatch by channel type. $opts holds transition_ms, dimmer_min/max, sim_min/max.
sub convert {
	my ($type, $value, $opts) = @_;
	my $t = $opts->{transition_ms};
	if ($type eq 'rgb_hs' || $type eq 'rgb_xy') {
		return lumitech_to_ctbri($value, $t) if is_lumitech($value);
		return $type eq 'rgb_hs' ? rgb_to_hsb($value, $t) : rgb_to_xyb($value, $t);
	}
	return dimmer_to_bri($value, $opts)  if $type eq 'brightness';
	return dimmer_to_bulb($value, $opts) if $type eq 'bulb';
	return onoff($value)                 if $type eq 'onoff';
	return undef;
}

1;
