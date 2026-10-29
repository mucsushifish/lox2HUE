#!/bin/bash
# Runs as loxberry before an upgrade removes the old installation: save the config.
# Arguments: $1 temp folder, $2 plugin name, $3 plugin folder, $4 version
PDIR=$3
BACKUP=/tmp/${PDIR}_upgrade
mkdir -p "$BACKUP"
cp -v "$LBPCONFIG/$PDIR/lox2hue.json" "$BACKUP/" || echo "<WARNING> No configuration to back up"
pkill -f "$LBPBIN/$PDIR/lox2hued.pl" 2>/dev/null
exit 0
