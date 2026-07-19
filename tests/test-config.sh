#!/bin/sh
# Run against a live container filesystem to validate generated Chrony config.
set -eu

CONF=/etc/chrony/chrony.conf

test -f "$CONF"

grep -Fq 'server 127.127.1.1' "$CONF"
grep -Fq 'local stratum 10' "$CONF"
grep -Fq 'allow 192.0.2.0/24' "$CONF"
grep -Fq 'noclientlog' "$CONF"
grep -Fq 'driftfile /var/lib/chrony/chrony.drift' "$CONF"
grep -Fq 'makestep 0.1 3' "$CONF"
grep -Fq 'ratelimit' "$CONF"
grep -Fq 'rtcsync' "$CONF"

if grep -Eq 'refclock (SOCK|PPS|PHC)' "$CONF"; then
  echo "Unexpected GPS/PPS/PTP refclock in offline smoke config:" >&2
  cat "$CONF" >&2
  exit 1
fi

/usr/sbin/chronyd -p -f "$CONF" >/dev/null
chronyc -n tracking >/dev/null

echo "Config regression checks passed"
