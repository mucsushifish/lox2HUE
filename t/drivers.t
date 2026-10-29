#!/usr/bin/perl
# Request bodies of both drivers and the SSE parser of the v2 event stream

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../bin/lib";
use Test::More;
use JSON;
use Lox2Hue::Driver::HueV1;
use Lox2Hue::Driver::HueV2;
use Lox2Hue::Driver::HueV2::EventStream;

my $j = JSON->new->canonical;
my $cmd = { on => 1, bri => 254, xy => [ 0.7236, 0.2609 ], transition_ms => 1000 };

is($j->encode(Lox2Hue::Driver::HueV1::body($cmd)),
	'{"bri":254,"on":true,"transitiontime":10,"xy":[0.7236,0.2609]}', 'v1 body');
is($j->encode(Lox2Hue::Driver::HueV1::body({ on => 1, bri => 100, hue => 30000, sat => 200, transition_ms => 0 })),
	'{"bri":100,"hue":30000,"on":true,"sat":200,"transitiontime":0}', 'v1 body hue/sat');

is($j->encode(Lox2Hue::Driver::HueV2::body($cmd)),
	'{"color":{"xy":{"x":0.7236,"y":0.2609}},"dimming":{"brightness":100},"dynamics":{"duration":1000},"on":{"on":true}}', 'v2 body xy');
is($j->encode(Lox2Hue::Driver::HueV2::body({ on => 1, bri => 1, ct => 370, transition_ms => 0 })),
	'{"color_temperature":{"mirek":370},"dimming":{"brightness":0.4},"dynamics":{"duration":0},"on":{"on":true}}', 'v2 body ct, minimum brightness');
is($j->encode(Lox2Hue::Driver::HueV2::body({ on => 0 })), '{"on":{"on":false}}', 'v2 body off');

# Event stream parser: chunked transfer encoding, split at arbitrary places
my @events;
my $es = Lox2Hue::Driver::HueV2::EventStream->new(host => 'x', key => 'k', on_event => sub { push @events, shift });
my $sse = qq{: hi\n\nid: 1:0\ndata: [{"type":"update","data":[{"id":"L3","type":"light","on":{"on":true}}]}]\n\n}
	. qq{id: 2:0\ndata: [{"type":"update","data":[{"id":"L4","type":"light"}]},{"type":"add","data":[]}]\n\n};
my $body = join '', map { sprintf("%x\r\n%s\r\n", length $_, $_) } (substr($sse, 0, 30), substr($sse, 30));
my $wire = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n$body";
$es->{sock} = 1;    # pretend to be connected
for my $piece ($wire =~ /(.{1,7})/gs) {
	$es->{raw} .= $piece;
	$es->_parse;
}
is(scalar @events, 3, 'three events parsed');
is($events[0]{data}[0]{id}, 'L3', 'first event');
is($events[2]{type}, 'add', 'second message holds two events');
is($es->{last_id}, '2:0', 'last event id kept for reconnect');

# v2 driver: state from events, reachability from zigbee_connectivity
my $d = Lox2Hue::Driver::HueV2->new(host => 'x', user => 'k', no_events => 1);
$d->{mapped} = 1;
$d->{lights} = { 3 => 'L3' };
$d->{v1_of}  = { L3 => 3 };
$d->{device} = { L3 => 'D3' };
$d->{conn}   = { D3 => 'connected' };
$d->_update_state({ id => 'L3', on => { on => JSON::false }, dimming => { brightness => 50 }, color => { xy => { x => 0.3, y => 0.3 } } });
$d->_event({ type => 'update', data => [ { id => 'L3', type => 'light', on => { on => JSON::true }, color_temperature => { mirek => 366, mirek_valid => JSON::true } } ] });
is_deeply([ $d->changed ], [ 3 ], 'light event marks lamp 3 as changed');
my $s = $d->get_light(3);
is_deeply([ @$s{qw(on bri ct colormode reachable)} ], [ 1, 127, 366, 'ct', 1 ], 'state merged from event');
$d->_event({ type => 'update', data => [ { id => 'Z', type => 'zigbee_connectivity', owner => { rid => 'D3' }, status => 'connectivity_issue' } ] });
is($d->get_light(3)->{reachable}, 0, 'connectivity issue -> not reachable');
is_deeply([ $d->changed ], [ 3 ], 'connectivity event marks lamp as changed');

done_testing();
