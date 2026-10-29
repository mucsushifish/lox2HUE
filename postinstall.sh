#!/bin/bash
# Runs as loxberry after installation and upgrade: (re)start the daemon.
PDIR=$3
"$LBPBIN/$PDIR/restart.sh"
echo "<OK> lox2hue daemon started"
exit 0
