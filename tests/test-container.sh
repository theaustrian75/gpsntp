#!/bin/sh
# Build-independent container smoke tests. Pass the image reference as $1.
set -eu

IMAGE="${1:?Usage: tests/test-container.sh IMAGE}"
CONTAINER="gpsntp-test-$$"

# Invoked through trap.
# shellcheck disable=SC2317
cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

default_settings=$(docker run --rm --entrypoint /bin/sh "$IMAGE" \
  -c 'printf "%s:%s %s" "$(id -u chrony)" "$(id -g chrony)" "$TZ"')
if [ "$default_settings" != "108:20 America/New_York" ]; then
  echo "Expected defaults '108:20 America/New_York', got '$default_settings'" >&2
  exit 1
fi

assert_failure() {
  expected=$1
  shift
  if output=$("$@" 2>&1); then
    echo "Expected command to fail: $*" >&2
    exit 1
  fi
  case "$output" in
    *"$expected"*) ;;
    *)
      printf 'Expected failure containing %s, got:\n%s\n' "$expected" "$output" >&2
      exit 1
      ;;
  esac
}

assert_failure "CHRONY_UID must be a non-zero numeric ID" \
  docker run --rm -e CHRONY_UID=0 \
  -e ENABLE_GPSD_SOCK=false -e ENABLE_KERNEL_PPS=false -e ENABLE_PTP=false \
  "$IMAGE"

assert_failure "Chrony account does not match 999:20" \
  docker run --rm -e CHRONY_UID=999 \
  -e ENABLE_GPSD_SOCK=false -e ENABLE_KERNEL_PPS=false -e ENABLE_PTP=false \
  "$IMAGE"

assert_failure "ENABLE_GPSD_SOCK must be true or false" \
  docker run --rm -e ENABLE_GPSD_SOCK=maybe \
  -e ENABLE_KERNEL_PPS=false -e ENABLE_PTP=false \
  "$IMAGE"

assert_failure "TZ must name an installed IANA timezone" \
  docker run --rm \
  -e 'TZ=America/New York' \
  -e ENABLE_GPSD_SOCK=false -e ENABLE_KERNEL_PPS=false -e ENABLE_PTP=false \
  "$IMAGE"

assert_failure "NTP_SOURCE_TYPE must be pool or server" \
  docker run --rm -e NTP_SOURCE_TYPE=peer \
  -e ENABLE_GPSD_SOCK=false -e ENABLE_KERNEL_PPS=false -e ENABLE_PTP=false \
  "$IMAGE"

assert_failure "NMEA_OFFSET must be a number" \
  docker run --rm -e NMEA_OFFSET=abc \
  -e ENABLE_GPSD_SOCK=false -e ENABLE_KERNEL_PPS=false -e ENABLE_PTP=false \
  "$IMAGE"

assert_failure "ENABLE_GPSD_SOCK and ENABLE_KERNEL_PPS cannot both be true" \
  docker run --rm \
  -e ENABLE_GPSD_SOCK=true -e ENABLE_KERNEL_PPS=true -e ENABLE_PTP=false \
  -e DEV_TTY=ttyAMA0 -e DEV_PPS=pps0 \
  "$IMAGE"

assert_failure "ENABLE_GPSD_SOCK requires DEV_TTY" \
  docker run --rm \
  -e ENABLE_GPSD_SOCK=true -e ENABLE_KERNEL_PPS=false -e ENABLE_PTP=false \
  "$IMAGE"

assert_failure "ENABLE_KERNEL_PPS requires DEV_TTY and DEV_PPS" \
  docker run --rm \
  -e ENABLE_GPSD_SOCK=false -e ENABLE_KERNEL_PPS=true -e ENABLE_PTP=false \
  "$IMAGE"

assert_failure "Invalid device name" \
  docker run --rm \
  -e ENABLE_GPSD_SOCK=false -e ENABLE_KERNEL_PPS=false -e ENABLE_PTP=false \
  -e 'DEV_TTY=tty AMA0' \
  "$IMAGE"

assert_failure "Invalid NTP server" \
  docker run --rm \
  -e ENABLE_GPSD_SOCK=false -e ENABLE_KERNEL_PPS=false -e ENABLE_PTP=false \
  -e 'NTP_SERVERS=bad server' \
  "$IMAGE"

assert_failure "Invalid NTP_ALLOW network" \
  docker run --rm \
  -e ENABLE_GPSD_SOCK=false -e ENABLE_KERNEL_PPS=false -e ENABLE_PTP=false \
  -e 'NTP_ALLOW=192.168.1.0/24;drop' \
  "$IMAGE"

# Exercise the same read-only/tmpfs constraints used in production, without
# GPS/PPS hardware or SYS_TIME. Local stratum keeps Chrony usable offline.
docker run -d --name "$CONTAINER" \
  --read-only \
  --security-opt no-new-privileges:true \
  --cap-drop ALL --cap-add CHOWN \
  --pids-limit 128 --memory 256m \
  --tmpfs /etc/chrony:rw,mode=1750 \
  --tmpfs /run:rw,mode=0755 \
  --tmpfs /var/lib/chrony:rw,mode=0755 \
  -v "$PWD/tests/test-config.sh:/tests/test-config.sh:ro" \
  -e ENABLE_GPSD_SOCK=false \
  -e ENABLE_KERNEL_PPS=false \
  -e ENABLE_PTP=false \
  -e ENABLE_SYSCLK=false \
  -e ENABLE_NTS=false \
  -e NOCLIENTLOG=true \
  -e NTP_SERVERS=127.127.1.1 \
  -e NTP_SOURCE_TYPE=server \
  -e NTP_ALLOW=192.0.2.0/24 \
  -e NTP_DIRECTIVES='ratelimit\nrtcsync' \
  -e LOG_LEVEL=0 \
  -e TZ=UTC \
  "$IMAGE" >/dev/null

attempt=0
while [ "$attempt" -lt 30 ]; do
  status=$(docker inspect -f '{{.State.Status}}' "$CONTAINER")
  case "$status" in
    running)
      if docker exec "$CONTAINER" chronyc -n tracking >/dev/null 2>&1; then
        docker exec "$CONTAINER" /tests/test-config.sh
        echo "Hardened container smoke test passed"
        exit 0
      fi
      ;;
    exited|dead)
      docker logs "$CONTAINER" >&2
      echo "Container exited before becoming ready" >&2
      exit 1
      ;;
  esac
  attempt=$((attempt + 1))
  sleep 1
done

docker logs "$CONTAINER" >&2
echo "Container did not become ready within 30 seconds" >&2
exit 1
