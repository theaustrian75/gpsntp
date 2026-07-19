#!/bin/bash

set -Eeuo pipefail

device="${UBLOX_DEVICE:-/dev/${DEV_TTY:-ttyAMA0}}"
baud="${UBLOX_BAUD:-115200}"
protocol="${UBLOX_PROTOCOL:-14.00}"

usage() {
  cat <<'EOF'
Usage: ublox-config [options] ACTION

Actions:
  identify             Poll receiver firmware and protocol information
  inspect              Poll current timing, rate, navigation, and GNSS settings
  configure-timepulse  Configure u-blox 7 timepulse in RAM and enable TIM-TP
  verify               Show timepulse configuration and watch timing messages
  save                 Persist the current receiver configuration

Options:
  --device PATH         Serial device (default: /dev/ttyAMA0)
  --baud RATE           Current serial rate (default: 115200)
  --protocol VERSION    u-blox protocol version (default: 14.00)
  -h, --help            Show this help

Stop the normal chrony service before using this tool so GPSD releases the
serial device. The configure-timepulse action does not persist changes; run
save separately only after verification.
EOF
}

action=""
while (($#)); do
  case "$1" in
    --device)
      [[ $# -ge 2 ]] || { echo "--device requires a value" >&2; exit 2; }
      device="$2"
      shift 2
      ;;
    --baud)
      [[ $# -ge 2 ]] || { echo "--baud requires a value" >&2; exit 2; }
      baud="$2"
      shift 2
      ;;
    --protocol)
      [[ $# -ge 2 ]] || { echo "--protocol requires a value" >&2; exit 2; }
      protocol="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    identify|inspect|configure-timepulse|verify|save)
      [[ -z "${action}" ]] || { echo "Only one action can be specified" >&2; exit 2; }
      action="$1"
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "${action}" ]] || { usage >&2; exit 2; }
[[ "${device}" == /dev/* && -c "${device}" ]] || {
  echo "Serial device '${device}' is not available in this container" >&2
  exit 1
}
[[ "${baud}" =~ ^[0-9]+$ ]] || { echo "Baud rate must be numeric" >&2; exit 2; }
[[ "${protocol}" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
  echo "Protocol version must be numeric" >&2
  exit 2
}
command -v ubxtool >/dev/null || { echo "ubxtool is not installed" >&2; exit 1; }

ubx=(ubxtool -P "${protocol}" -f "${device}" -s "${baud}")

case "${action}" in
  identify)
    "${ubx[@]}" -p MON-VER -w 5 -v 2
    ;;
  inspect)
    "${ubx[@]}" \
      -p CFG-TP5 \
      -p CFG-RATE \
      -p CFG-NAV5 \
      -p CFG-GNSS \
      -p CFG-TMODE2 \
      -w 8 -v 2
    ;;
  configure-timepulse)
    echo "Configuring volatile u-blox 7 timepulse settings on ${device}" >&2
    "${ubx[@]}" -p 'CFG-TP5,0,,,1000000,1000000,0,100000,0,0x77'
    "${ubx[@]}" -e TP
    echo "Configuration is not persistent; run verify before save." >&2
    ;;
  verify)
    "${ubx[@]}" -p CFG-TP5 -w 3 -v 2
    echo "Watching for UBX-TIM-TP messages and qErr values..." >&2
    "${ubx[@]}" -w 10 -v 2
    ;;
  save)
    echo "Persisting the receiver's current configuration to supported storage" >&2
    "${ubx[@]}" -p SAVE
    ;;
esac
