#!/usr/bin/perl

# HTTP input for Loxone virtual outputs (no login, reachable in the LAN):
#   /plugins/lox2hue/set.cgi?ch=<channel>&v=<value>
#   /plugins/lox2hue/set.cgi?ch=alloff&v=1
# The value is published to <topic>/<channel>; the daemon does the rest.

use strict;
use warnings;
use CGI;
use LoxBerry::System;
use LoxBerry::IO;
use LoxBerry::JSON;

my $cgi = CGI->new;
my $ch  = $cgi->param('ch') // '';
my $v   = $cgi->param('v')  // '';

sub answer {
	my ($status, $text) = @_;
	print $cgi->header(-type => 'text/plain', -status => $status);
	print "$text\n";
	exit;
}

answer(400, 'invalid channel') if $ch !~ /^[A-Za-z0-9_\-]+$/;
answer(400, 'invalid value')   if $v  !~ /^\d+(?:\.\d+)?$/;

my $cfg = LoxBerry::JSON->new->open(filename => "$lbpconfigdir/lox2hue.json", readonly => 1) || {};
my $topic = $cfg->{mqtt}{topic} || 'lox2hue';
LoxBerry::IO::mqtt_publish("$topic/$ch", $v);
answer(200, 'ok');
