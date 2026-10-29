#!/bin/bash
# Restarts the daemon, e.g. after installation. Runs as user loxberry.
DAEMON=REPLACELBPBINDIR/lox2hued.pl
pkill -f "$DAEMON" 2>/dev/null
sleep 1
nohup "$DAEMON" >/dev/null 2>&1 &
exit 0
