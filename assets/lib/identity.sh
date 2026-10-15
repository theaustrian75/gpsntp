# shellcheck shell=bash
# shellcheck disable=SC2154
# Chrony identity is baked into the image at build time. Runtime CHRONY_UID
# and CHRONY_GID must match that account (no nss_wrapper remapping).
# Sourced by startup.sh; CHRONY_UID and CHRONY_GID are assigned there.

verify_chrony_identity() {
  local image_uid image_gid
  image_uid="$(id -u chrony)"
  image_gid="$(id -g chrony)"
  if [[ "${image_uid}" != "${CHRONY_UID}" || "${image_gid}" != "${CHRONY_GID}" ]]; then
    echo "CHRONY_UID:CHRONY_GID ${CHRONY_UID}:${CHRONY_GID} must match the image chrony account ${image_uid}:${image_gid}; rebuild with matching --build-arg CHRONY_UID and CHRONY_GID" >&2
    exit 1
  fi
}
