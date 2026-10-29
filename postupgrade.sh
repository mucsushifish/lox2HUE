#!/bin/bash
# Runs as loxberry after an upgrade: restore the saved config.
PDIR=$3
BACKUP=/tmp/${PDIR}_upgrade
if [ -f "$BACKUP/lox2hue.json" ]; then
	cp -v "$BACKUP/lox2hue.json" "$LBPCONFIG/$PDIR/lox2hue.json"
	echo "<OK> Configuration restored"
fi
rm -rf "$BACKUP"
exit 0
