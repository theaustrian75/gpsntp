# shellcheck shell=bash
# shellcheck disable=SC2154
# Remap the named chrony account at runtime when CHRONY_UID/GID differ from
# the image defaults. nss_wrapper avoids writing /etc under a read-only rootfs.
# Sourced by startup.sh; CHRONY_UID and CHRONY_GID are assigned there.

remap_chrony_identity() {
  if [[ "$(id -u chrony)" == "${CHRONY_UID}" && "$(id -g chrony)" == "${CHRONY_GID}" ]]; then
    return 0
  fi

  if awk -F: -v uid="${CHRONY_UID}" \
    '$3 == uid && $1 != "chrony" { found = 1 } END { exit !found }' /etc/passwd
  then
    echo "CHRONY_UID ${CHRONY_UID} is already used by another account" >&2
    exit 1
  fi

  mkdir -p /run/gpsntp
  awk -F: -v uid="${CHRONY_UID}" -v gid="${CHRONY_GID}" '
    BEGIN { OFS = FS }
    $1 == "chrony" { $3 = uid; $4 = gid }
    { print }
  ' /etc/passwd > /run/gpsntp/passwd

  if awk -F: -v gid="${CHRONY_GID}" '$3 == gid { found = 1 } END { exit !found }' /etc/group; then
    cp /etc/group /run/gpsntp/group
  else
    awk -F: -v gid="${CHRONY_GID}" '
      BEGIN { OFS = FS }
      $1 == "chrony" { $3 = gid; found = 1 }
      { print }
      END { if (!found) print "chrony:x:" gid ":" }
    ' /etc/group > /run/gpsntp/group
  fi

  export NSS_WRAPPER_PASSWD=/run/gpsntp/passwd
  export NSS_WRAPPER_GROUP=/run/gpsntp/group
  export LD_PRELOAD=/usr/lib/libnss_wrapper.so

  if [[ "$(id -u chrony)" != "${CHRONY_UID}" || "$(id -g chrony)" != "${CHRONY_GID}" ]]; then
    echo "Failed to apply CHRONY_UID:CHRONY_GID ${CHRONY_UID}:${CHRONY_GID}" >&2
    exit 1
  fi
}
