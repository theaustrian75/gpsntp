# AGENTS.md

## Cursor Cloud specific instructions

This repository builds a single product: **`gpsntp`**, a hardened Alpine-based
Chrony NTP server container image (with optional GPS/PPS/PTP hardware sources).
There is no web UI, database, or language runtime — all logic lives in shell
scripts and everything runs inside one Docker image. Development is entirely
Docker-driven; the authoritative lint/build/test commands live in
`.github/workflows/ci.yml`.

### Starting Docker (required first step each session)

Docker is installed in the VM snapshot but the daemon does **not** auto-start,
and running processes do not persist across sessions. At the start of a session,
start it and make the socket usable without `sudo`:

```bash
sudo dockerd >/tmp/dockerd.log 2>&1 &   # or run in a tmux session
sleep 5
sudo chmod 666 /var/run/docker.sock      # daemon recreates the socket root-owned
docker info                              # confirm daemon is up (storage-driver: fuse-overlayfs)
```

The `ubuntu` user is in the `docker` group, but the socket is recreated
root-owned every time `dockerd` starts, so the `chmod 666` is needed each time
until you re-login. Docker uses the `fuse-overlayfs` storage driver
(`/etc/docker/daemon.json`) because the sandbox kernel lacks full overlay2
support; do not change this.

### cgroup v2 limitation (important gotcha)

The sandbox can delegate only the `cpuset`, `cpu`, and `pids` cgroup
controllers. The `memory`, `io`, and `hugetlb` controllers are **not**
delegatable, so `docker run --memory ...` fails with:
`cannot enter cgroupv2 "/sys/fs/cgroup/docker" with domain controllers -- it is in threaded mode`.

`tests/test-container.sh` uses `--pids-limit 128 --memory 256m` for its final
hardened live-container check. The `--pids-limit` part works, but `--memory`
does not in this VM. All 11 env-validation assertions in that script pass
unchanged; only the final live run is blocked by `--memory`. To exercise the
full smoke test here, run a copy with the `--memory 256m` token removed, e.g.:

```bash
cp tests/test-container.sh /tmp/tc.sh
sed -i 's/--pids-limit 128 --memory 256m/--pids-limit 128/' /tmp/tc.sh
sh /tmp/tc.sh gpsntp:test
```

This is a VM constraint only — the unmodified script is correct and passes in
real CI (GitHub `ubuntu-24.04`). Do not commit a modified test.

### Lint / build / test / run (see `.github/workflows/ci.yml`)

```bash
# Lint (shellcheck installed in snapshot; jq preinstalled)
shellcheck assets/*.sh tests/*.sh

# Compose config validation
docker compose --env-file .env.example config --format json > /tmp/cc.json
jq -e '.services.chrony.build.dockerfile=="Dockerfile.gpsntp"' /tmp/cc.json

# Build the image
docker build --tag gpsntp:test --file Dockerfile.gpsntp .

# Smoke tests (see cgroup note above about --memory)
tests/test-container.sh gpsntp:test
```

### Running the app (hello-world)

No GPS hardware exists in the VM, so run with GPS/PPS/PTP disabled and a local
or pool source. Use `--network host` so it binds NTP on UDP/123:

```bash
docker run -d --name gpsntp-hello --network host \
  --cap-drop ALL --cap-add CHOWN --cap-add FOWNER --cap-add SETUID \
  --cap-add SETGID --cap-add NET_BIND_SERVICE --cap-add DAC_OVERRIDE \
  --tmpfs /etc/chrony:rw,mode=1750 --tmpfs /run:rw,mode=0755 \
  --tmpfs /var/lib/chrony:rw,mode=0755 \
  -e ENABLE_GPSD_SOCK=false -e ENABLE_KERNEL_PPS=false -e ENABLE_PTP=false \
  -e ENABLE_SYSCLK=false -e ENABLE_NTS=false \
  -e NTP_SERVERS=0.pool.ntp.org,1.pool.ntp.org,2.pool.ntp.org,3.pool.ntp.org \
  -e NTP_SOURCE_TYPE=pool -e NTP_ALLOW=all -e LOG_LEVEL=0 -e TZ=UTC \
  gpsntp:test

docker exec gpsntp-hello chronyc -n tracking   # shows sync status
```

Notes:
- `ENABLE_SYSCLK=false` is important in the VM: with it `true`, chronyd tries to
  steer the host clock and can log "System clock interference detected" and exit
  because another time client (or the shared host clock) is present.
- GPS/PPS/PTP modes (`ENABLE_GPSD_SOCK=true`, `ENABLE_KERNEL_PPS=true`,
  `ENABLE_PTP=true`) require real serial/PPS/PHC devices (a Raspberry Pi + u-blox
  receiver) and cannot run in this VM.
- Running `docker compose up` locally is not useful here: it requires `.env` with
  real `/dev/ttyAMA0` + `/dev/pps0` devices. Use the `docker run` above instead.
