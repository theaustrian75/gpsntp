# shellcheck shell=bash
# shellcheck disable=SC2154
# Wait for Chrony SOCK refclocks, fix dialout permissions, then start GPSD.
# Sourced by startup.sh; gpsd_sockets, chronyd_pid, pids, and device globals
# are assigned there.

wait_for_socket() {
  local socket=$1
  for _ in {1..50}; do
    [[ -S "${socket}" ]] && return 0
    if ! kill -0 "${chronyd_pid}" 2>/dev/null; then
      wait "${chronyd_pid}" || true
      echo "chronyd exited before creating ${socket}" >&2
      exit 1
    fi
    sleep 0.1
  done

  echo "chronyd did not create ${socket}" >&2
  terminate
  wait "${chronyd_pid}" 2>/dev/null || true
  exit 1
}

start_gpsd() {
  local socket gpsd_device dialout_gid
  local -a gpsd_devices

  for socket in "${gpsd_sockets[@]}"; do
    wait_for_socket "${socket}"
  done

  dialout_gid="$(awk -F: '$1 == "dialout" { print $3; exit }' /etc/group)"
  if [[ -z "${dialout_gid}" ]]; then
    echo "dialout group is required for GPSD device access" >&2
    terminate
    wait "${chronyd_pid}" 2>/dev/null || true
    exit 1
  fi

  for socket in "${gpsd_sockets[@]}"; do
    chown "${CHRONY_UID}:${dialout_gid}" "${socket}"
    chmod 660 "${socket}"
  done

  gpsd_devices=("/dev/${DEV_TTY}")
  if [[ "${ENABLE_GPSD_SOCK}" == "true" ]]; then
    gpsd_devices+=("/dev/${DEV_PPS}")
  fi
  for gpsd_device in "${gpsd_devices[@]}"; do
    chown "root:${dialout_gid}" "${gpsd_device}"
    chmod 660 "${gpsd_device}"
  done

  /usr/sbin/gpsd -nbN "${gpsd_devices[@]}" &
  pids+=("$!")
}
