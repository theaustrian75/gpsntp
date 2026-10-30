# AGENTS.md

## Cursor Cloud specific instructions

This repository builds a single product: **`gpsntp`**, a hardened Alpine-based
Chrony NTP server container image (with optional GPS/PPS/PTP hardware sources).
There is no web UI, database, or language runtime — all logic lives in shell
scripts and everything runs inside one Docker image. Development is entirely
Docker-driven; the authoritative lint/build/test commands live in
`.github/workflows/ci.yml`.

### Starting Docker

Docker Engine, Buildx, and the Compose plugin are installed in the environment
(`docker.io`, `docker-buildx`, `docker-compose-v2`), along with ShellCheck.
There is no systemd in this VM, so the environment start script launches
`dockerd` and makes `/var/run/docker.sock` writable by `ubuntu`. `docker build`
must use BuildKit: `Dockerfile.gpsntp` uses `COPY --chmod`, which the legacy
builder rejects. The storage driver is containerd's `overlayfs`.

If `docker info` fails, read `/tmp/cursor/start-user/start-user.log`, then
start the daemon by hand:

```bash
sudo dockerd >/tmp/dockerd.log 2>&1 &
sleep 5
sudo chmod 666 /var/run/docker.sock
docker info
```

### Container limits

`--memory` and `--pids-limit` both work here. Run `tests/test-container.sh`
unchanged. Do not commit a modified copy of that test.

### Lint / build / test / run (see `.github/workflows/ci.yml`)

```bash
# Lint (shellcheck and jq are installed)
shellcheck -x assets/*.sh assets/lib/*.sh tests/*.sh

# Compose config validation
docker compose --env-file .env.example config --format json > /tmp/cc.json
jq -e '.services.chrony.build.dockerfile=="Dockerfile.gpsntp"' /tmp/cc.json

# Build the image
docker build --tag gpsntp:test --file Dockerfile.gpsntp .

# Smoke tests, including the hardened run with --memory and --pids-limit
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
- Set `ENABLE_SYSCLK=false` in this VM. Chrony would otherwise steer the shared
  host clock, and another time client can log "System clock interference detected".
- GPS/PPS/PTP modes (`ENABLE_GPSD_SOCK=true`, `ENABLE_KERNEL_PPS=true`,
  `ENABLE_PTP=true`) require real serial/PPS/PHC devices (a Raspberry Pi + u-blox
  receiver) and cannot run in this VM.
- Running `docker compose up` locally is not useful here: it requires `.env` with
  real `/dev/ttyAMA0` + `/dev/pps0` devices. Use the `docker run` above instead.
