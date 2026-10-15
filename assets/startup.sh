#!/bin/bash

set -Eeuo pipefail

readonly DEFAULT_NTP="0.pool.ntp.org,1.pool.ntp.org,2.pool.ntp.org,3.pool.ntp.org"
readonly DEFAULT_PPS="pps0"
readonly DEFAULT_TTY="ttyAMA0"
readonly DEFAULT_PTP="ptp0"
readonly CHRONY_CONF_FILE="/etc/chrony/chrony.conf"
readonly GPSNTP_LIBDIR="${GPSNTP_LIBDIR:-/usr/local/lib/gpsntp}"

# shellcheck source=assets/lib/identity.sh
. "${GPSNTP_LIBDIR}/identity.sh"
# shellcheck source=assets/lib/devices.sh
. "${GPSNTP_LIBDIR}/devices.sh"
# shellcheck source=assets/lib/chrony-conf.sh
. "${GPSNTP_LIBDIR}/chrony-conf.sh"
# shellcheck source=assets/lib/gpsd-start.sh
. "${GPSNTP_LIBDIR}/gpsd-start.sh"

NTP_SERVERS="${NTP_SERVERS:-${DEFAULT_NTP}}"
NTP_SOURCE_TYPE="${NTP_SOURCE_TYPE:-pool}"
NTP_ALLOW="${NTP_ALLOW-all}"
DEV_PPS="${DEV_PPS:-}"
DEV_TTY="${DEV_TTY:-}"
DEV_PTP="${DEV_PTP:-${DEFAULT_PTP}}"
CHRONY_UID="${CHRONY_UID:-108}"
CHRONY_GID="${CHRONY_GID:-20}"
LOG_LEVEL="${LOG_LEVEL:-0}"
TZ="${TZ:-UTC}"
ENABLE_NTS="${ENABLE_NTS:-false}"
ENABLE_SYSCLK="${ENABLE_SYSCLK:-false}"
NOCLIENTLOG="${NOCLIENTLOG:-false}"
ENABLE_GPSD_SOCK="${ENABLE_GPSD_SOCK:-true}"
ENABLE_KERNEL_PPS="${ENABLE_KERNEL_PPS:-false}"
ENABLE_PTP="${ENABLE_PTP:-false}"
GPS_PREFER="${GPS_PREFER:-true}"
NMEA_OFFSET="${NMEA_OFFSET:-0.5}"
NMEA_DELAY="${NMEA_DELAY:-0.1}"
PTP_OFFSET="${PTP_OFFSET:-0}"

for variable in CHRONY_UID CHRONY_GID; do
  value="${!variable}"
  if [[ ! "${value}" =~ ^[0-9]+$ || "${value}" == "0" ]]; then
    echo "${variable} must be a non-zero numeric ID" >&2
    exit 1
  fi
done

remap_chrony_identity

for variable in ENABLE_NTS ENABLE_SYSCLK NOCLIENTLOG ENABLE_GPSD_SOCK ENABLE_KERNEL_PPS ENABLE_PTP GPS_PREFER; do
  value="${!variable}"
  if [[ "${value}" != "true" && "${value}" != "false" ]]; then
    echo "${variable} must be true or false" >&2
    exit 1
  fi
done

if [[ "${TZ}" == /* || "${TZ}" == *".."* || ! "${TZ}" =~ ^[A-Za-z0-9._+/-]+$ || ! -f "/usr/share/zoneinfo/${TZ}" ]]; then
  echo "TZ must name an installed IANA timezone" >&2
  exit 1
fi
export TZ

if [[ "${ENABLE_GPSD_SOCK}" == "true" && "${ENABLE_KERNEL_PPS}" == "true" ]]; then
  echo "ENABLE_GPSD_SOCK and ENABLE_KERNEL_PPS cannot both be true" >&2
  exit 1
fi

case "${NTP_SOURCE_TYPE}" in
  pool|server|peer) ;;
  *)
    echo "NTP_SOURCE_TYPE must be pool, server, or peer" >&2
    exit 1
    ;;
esac

for variable in NMEA_OFFSET NMEA_DELAY PTP_OFFSET; do
  value="${!variable}"
  if [[ ! "${value}" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
    echo "${variable} must be a number" >&2
    exit 1
  fi
done

mkdir -p /etc/chrony /run/chrony /var/lib/chrony
chown "${CHRONY_UID}:${CHRONY_GID}" /run/chrony /var/lib/chrony
chmod 0750 /run/chrony
rm -f /run/chrony/chronyd.pid

for device in "${DEV_PPS}" "${DEV_TTY}" "${DEV_PTP}"; do
  if [[ -n "${device}" && ! "${device}" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Invalid device name '${device}'; provide a basename under /dev" >&2
    exit 1
  fi
done

resolve_dev_pps
resolve_dev_tty

if [[ "${ENABLE_GPSD_SOCK}" == "true" && ( -z "${DEV_TTY}" || -z "${DEV_PPS}" ) ]]; then
  echo "ENABLE_GPSD_SOCK requires DEV_TTY and DEV_PPS" >&2
  exit 1
fi

if [[ "${ENABLE_KERNEL_PPS}" == "true" && ( -z "${DEV_TTY}" || -z "${DEV_PPS}" ) ]]; then
  echo "ENABLE_KERNEL_PPS requires DEV_TTY and DEV_PPS" >&2
  exit 1
fi

if [[ "${ENABLE_PTP}" == "true" && ! -e "/dev/${DEV_PTP}" ]]; then
  echo "PTP: /dev/${DEV_PTP} does not exist" >&2
  exit 1
fi

case "${LOG_LEVEL}" in
  0|1|2|3) ;;
  *)
    echo "Invalid LOG_LEVEL '${LOG_LEVEL}'; using 0" >&2
    LOG_LEVEL=0
    ;;
esac

gpsd_sockets=()
generate_chrony_conf
/usr/sbin/chronyd -p -f "${CHRONY_CONF_FILE}" >/dev/null

chronyd_args=(-u chrony -d -L "${LOG_LEVEL}" -f "${CHRONY_CONF_FILE}")
if [[ "${ENABLE_SYSCLK}" != "true" ]]; then
  chronyd_args+=(-x)
  echo "ENABLE_SYSCLK=false: chronyd will run with -x (no host clock control)"
else
  echo "ENABLE_SYSCLK=true: chronyd will control the host clock (requires CAP_SYS_TIME)"
fi

pids=()
terminate() {
  local pid
  for pid in "${pids[@]}"; do
    kill -TERM "${pid}" 2>/dev/null || true
  done
}
trap terminate TERM INT

TZ=UTC /usr/sbin/chronyd "${chronyd_args[@]}" &
chronyd_pid="$!"
pids+=("${chronyd_pid}")

if (( ${#gpsd_sockets[@]} > 0 )); then
  start_gpsd
fi

status=0
wait -n "${pids[@]}" || status=$?
terminate
for pid in "${pids[@]}"; do
  wait "${pid}" 2>/dev/null || true
done
exit "${status}"
