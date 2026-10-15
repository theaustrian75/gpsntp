# shellcheck shell=bash
# shellcheck disable=SC2154
# Resolve GPS/PPS device basenames. Prefer a live KPPS node over pps0 when
# Ethernet PTP has claimed pps0 (common on Raspberry Pi).
# Sourced by startup.sh; DEV_PPS, DEV_TTY, DEFAULT_* are assigned there.

pps_assert_count() {
  local name=$1
  local assert_file="/sys/class/pps/${name}/assert"
  local count
  [[ -r "${assert_file}" ]] || { echo 0; return 0; }
  count="$(cut -d# -f2 "${assert_file}")"
  if [[ "${count}" =~ ^[0-9]+$ ]]; then
    echo "${count}"
  else
    echo 0
  fi
}

pps_is_live() {
  local name=$1
  local source path count
  count="$(pps_assert_count "${name}")"
  (( count > 0 )) || return 1
  # PTP-backed PPS nodes report the PHC (e.g. "ptp0") in name; some kernels
  # use path instead.
  source="$(cat "/sys/class/pps/${name}/name" 2>/dev/null || true)"
  path="$(cat "/sys/class/pps/${name}/path" 2>/dev/null || true)"
  [[ "${source}" != ptp* && "${path}" != ptp* ]]
}

list_live_pps() {
  local d name
  shopt -s nullglob
  for d in /sys/class/pps/pps*; do
    name="$(basename "${d}")"
    if pps_is_live "${name}"; then
      printf '%s\n' "${name}"
    fi
  done | sort -V
}

resolve_dev_pps() {
  local live
  local -a live_pps=()
  while IFS= read -r live; do
    [[ -n "${live}" ]] || continue
    live_pps+=("${live}")
  done < <(list_live_pps)

  if [[ -z "${DEV_PPS}" ]]; then
    if (( ${#live_pps[@]} > 0 )); then
      DEV_PPS="${live_pps[0]}"
      echo "Using live /dev/${DEV_PPS}"
    elif [[ -e "/dev/${DEFAULT_PPS}" ]]; then
      DEV_PPS="${DEFAULT_PPS}"
      echo "Using /dev/${DEV_PPS}"
    fi
  elif [[ ! -e "/dev/${DEV_PPS}" ]]; then
    echo "PPS: /dev/${DEV_PPS} does not exist"
    exit 1
  fi

  # Refuse pps0 only when it is not itself live; a GPIO pps0 is fine.
  if [[ "${DEV_PPS}" == "pps0" ]] && (( ${#live_pps[@]} > 0 )) && ! pps_is_live pps0; then
    echo "DEV_PPS=pps0 refused; live PPS device(s): ${live_pps[*]} (set DEV_PPS=${live_pps[0]})" >&2
    exit 1
  fi
}

resolve_dev_tty() {
  if [[ -z "${DEV_TTY}" && -e "/dev/${DEFAULT_TTY}" ]]; then
    DEV_TTY="${DEFAULT_TTY}"
    echo "Using /dev/${DEV_TTY}"
  elif [[ -n "${DEV_TTY}" && ! -e "/dev/${DEV_TTY}" ]]; then
    echo "TTY: /dev/${DEV_TTY} does not exist"
    exit 1
  fi
}
