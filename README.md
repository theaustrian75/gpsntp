# GPS NTP server

Alpine-based Chrony NTP server with optional GPS, PPS, and PTP hardware
sources. GPSD's Chrony SOCK protocol is the preferred high-precision source.
Direct kernel PPS locked to GPSD's NMEA source is available as an alternative.

Prebuilt `linux/amd64` and `linux/arm64` images are published to:

```text
ghcr.io/theaustrian75/gpsntp
```

## Deploy with Compose

The included Compose file expects `/dev/ttyAMA0` and `/dev/pps0` on the host.
Their basenames are configurable in `.env`. PTP is disabled by default and its
device must be added to the Compose `devices` list before enabling it.

```bash
cp .env.example .env
# Edit .env for your network and time sources.
docker compose up -d --build
docker compose ps
docker compose logs -f chrony
```

The container uses host networking to serve UDP port 123. It has a read-only
root filesystem; generated configuration and runtime state are kept in tmpfs.
Chrony's oscillator drift data persists in the `chrony-data` volume. Compose
drops all capabilities and adds only `CHOWN`, `FOWNER`, `SETUID`, `SETGID`,
`NET_BIND_SERVICE`, `DAC_OVERRIDE`, and `SYS_TIME`.

### Host clock ownership

With `ENABLE_SYSCLK=true` (the Compose / Quadlet default), Chrony steers the
**host** clock via `CAP_SYS_TIME`. Only one NTP client should do that. If a
host daemon such as `systemd-timesyncd` is also adjusting the clock, Chrony
4.8+ may log:

```text
System clock interference detected (another NTP client?)
```

That line is a **warning**, not a fatal error — Chrony does not exit because of
it. The same message can also appear as a false positive around source
selection / `makestep`. With `ENABLE_SYSCLK=false`, Chrony is started with
`-x` and uses a null clock driver, so that warning cannot come from clock
control; if you still see it, the container is not actually running with
`-x` (check startup logs for the `ENABLE_SYSCLK=` line and `ps` for `-x`).

The bare `SHM: shmctl(... IPC_RMID) failed, Operation not permitted` line
(no Chrony timestamp) is GPSD cleaning up NTP SHM segments on shutdown under
the dropped capability set. It is a shutdown side effect, not the reason the
container stopped.

When you do want Chrony to own the host clock, disable other time daemons:

```bash
sudo timedatectl set-ntp false
# or explicitly:
sudo systemctl disable --now systemd-timesyncd
sudo systemctl disable --now chronyd ntp ntpd openntpd 2>/dev/null || true
```

### Podman Compose and reboot

Manual `docker compose up` as root works because you start the stack after the
host is up. Reboot is different: `podman-restart.service` only starts containers
that already have a restart policy **and** still qualify.

A container left `exited` with `restart: unless-stopped` is skipped on boot
even when other stacks come back. Editing YAML to `restart: always` does
nothing until recreate.

```bash
cd /path/to/gpsntp   # your compose project directory
# compose must contain: restart: always
docker compose up -d --force-recreate
podman inspect <chrony-container> --format 'Restart={{.HostConfig.RestartPolicy.Name}} Status={{.State.Status}}'
# expect: Restart=always Status=running
sudo systemctl enable --now podman-restart.service
```

After the next reboot, if policy is `always` but the container is still down,
check whether UART/PPS were missing when Podman tried to bind devices:

```bash
journalctl -u podman-restart.service -b --no-pager | rg -i 'chrony|ttyAMA|pps0|no such file|error'
ls -l /dev/ttyAMA0 /dev/pps0
```

Prefer a unit that waits for those devices instead of racing `podman-restart`.
Either install the Quadlet files (`gpsntp.container` waits on
`dev-ttyAMA0.device` / `dev-pps0.device`) or a compose oneshot:

```ini
# /etc/systemd/system/gpsntp-compose.service
[Unit]
Description=GPS NTP compose stack
After=network-online.target dev-ttyAMA0.device dev-pps0.device
Wants=network-online.target dev-ttyAMA0.device dev-pps0.device

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/path/to/gpsntp
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose stop
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now gpsntp-compose.service
```

With that unit you can leave chrony out of `podman-restart` and still get a
reliable boot start once the GPS devices exist.

Set `NTP_ALLOW` to the network that should be allowed to query this server.
For example, in `.env`:

```dotenv
NTP_ALLOW=192.168.1.0/24
```

The default is `all`. Set it to an empty string to disable remote NTP clients.
The local `.env` file is ignored by Git; `.env.example` contains the tracked
defaults. Use a host firewall even when Chrony access is restricted.

## Configuration

- `NTP_SERVERS`: comma-separated upstream NTP servers; defaults to the four
  `pool.ntp.org` servers.
- `NTP_SOURCE_TYPE`: interpret upstream entries as `pool` or `server`;
  defaults to `pool`.
- `NTP_DIRECTIVES`: additional Chrony directives; defaults to
  `ratelimit\nrtcsync`.
- `NTP_ALLOW`: client network, `all`, or empty to disable clients; defaults
  to `all`.
- `CHRONY_UID` / `CHRONY_GID`: numeric Chrony service identity; defaults to
  `108:20`. Override at runtime without rebuilding the image.
- `DEV_TTY`: GPS serial device basename; auto-detects `ttyAMA0`.
- `DEV_PPS`: PPS device basename; auto-detects `pps0`.
- `ENABLE_GPSD_SOCK`: use GPSD's high-precision SOCK source; defaults to
  `true`.
- `ENABLE_KERNEL_PPS`: use direct PPS locked to GPSD NMEA instead; defaults
  to `false` and cannot be enabled with `ENABLE_GPSD_SOCK`.
- `GPS_PREFER`: prefer the selected GPS/PPS source when it agrees with the
  other sources; defaults to `true`.
- `NMEA_OFFSET` / `NMEA_DELAY`: receiver-specific NMEA timing adjustments
  used only in direct kernel PPS mode.
- `ENABLE_PTP`: enable a PHC source explicitly; defaults to `false`.
- `DEV_PTP`: PHC device basename; defaults to `ptp0`.
- `PTP_OFFSET`: PHC-to-UTC correction in seconds; defaults to `0`.
- `ENABLE_NTS`: enable NTS for configured upstream servers; defaults to
  `false`.
- `ENABLE_SYSCLK`: permit Chrony to adjust the host system clock; entrypoint
  defaults to `false`, but Compose / Quadlet / `.env.example` set `true`.
  Requires disabling other host NTP clients (see Host clock ownership).
- `NOCLIENTLOG`: disable Chrony client-access logging; defaults to `false`.
- `LOG_LEVEL`: Chrony log level from `0` through `3`; defaults to `0`.
- `TZ`: timezone for container tools; defaults to `America/New_York`.
  Chrony itself always logs in UTC.

Explicitly configured devices must exist or startup fails. Chrony starts first
so its SOCK refclock is ready before GPSD connects. GPSD runs with `-nbN`; it
does not accept receiver time without a current fix.

### GPS source modes

The default `ENABLE_GPSD_SOCK=true` mode lets GPSD provide the corrected PPS
sample through `/run/chrony.<tty>.sock`. This avoids duplicate correlated PPS,
SHM, and SOCK sources.

For direct kernel PPS, set:

```dotenv
ENABLE_GPSD_SOCK=false
ENABLE_KERNEL_PPS=true
```

Chrony then locks `/dev/<DEV_PPS>` to NMEA samples from GPSD. Calibrate
`NMEA_OFFSET` and `NMEA_DELAY` for the receiver and serial baud rate.

PTP is intentionally opt-in because an arbitrary PHC can be free-running or
use TAI rather than UTC. Add its device mapping to Compose, set
`ENABLE_PTP=true`, and configure `PTP_OFFSET` for the clock's timescale.

### u-blox receiver setup

The default mode is optimized for u-blox receivers with a 1 Hz timepulse:

- GPSD's SOCK source is processed every second with `poll 0`.
- The GPS source is marked `prefer`, but not `trust`, so Chrony can still
  reject it when it disagrees with other sources.
- GPSD can use u-blox timing information, including sawtooth correction when
  the receiver and firmware provide it through supported UBX messages.
- Direct PPS mode locks the kernel PPS device to u-blox NMEA time, avoiding
  whole-second ambiguity.

GPSD runs with `-nbN`. The `-b` option deliberately prevents it from changing
receiver settings, so configure the u-blox persistently before deployment.
For protocol 14 u-blox 7 receivers, use the
[u-blox 7 timing optimization](#u-blox-7-timing-optimization) procedure below
(or u-center / a matching `ubxtool` for other generations).

In direct PPS mode, retain RMC or ZDA messages for second identification.
u-blox configuration keys and protocol messages vary significantly by
generation and firmware; follow the integration manual for the exact model.

### Receiver debugging tools

This debug build includes `ubxtool`, the Python `gps` module, and Python
`serial` support. It also provides an `ublox-config` wrapper for protocol 14
u-blox 7 receivers.

The wrapper defaults to `/dev/ttyAMA0`, 115200 baud, and protocol 14.00.
Override them with `--device`, `--baud`, and `--protocol`. Run
`ublox-config --help` for all actions. GPSD runs in read-only mode (`-b`), so
stop the normal Chrony service before any one-off configuration container uses
the serial device.

Factory u-blox 7 modules often speak **9600** baud until a higher rate is
saved. Pass `--baud 9600` (or `-s 9600` for raw `ubxtool`) until the receiver
has been switched and persisted at 115200. The Raspberry Pi UART itself does
not need a baud setting in `config.txt`; GPSD sets the line speed when it
opens the port.

### u-blox 7 timing optimization

Use this sequence on a Pi with a protocol 14 u-blox 7 to optimize GPSD SOCK /
PPS timing. Keep Chrony stopped for every step that talks to the serial port.

```bash
docker compose build chrony
docker compose stop chrony
```

**1. Inspect current settings**

```bash
docker compose run --rm --no-deps \
  --entrypoint /usr/local/bin/ublox-config chrony \
  --baud 9600 inspect
```

**2. Configure 1 Hz TIMEPULSE (UTC, pulse only when locked) and enable TIM-TP**

`configure-timepulse` writes volatile RAM settings: 1 Hz UTC-aligned
timepulse, rising edge, unlocked pulse length 0 / locked pulse length 10%,
and enables `UBX-TIM-TP` so GPSD can apply sawtooth (`qErr`) correction.

```bash
docker compose run --rm --no-deps \
  --entrypoint /usr/local/bin/ublox-config chrony \
  --baud 9600 configure-timepulse
```

**3. Set stationary navigation mode**

Stationary `dynModel` reduces timing jitter for a fixed antenna. Confirm or
set it with `ubxtool`:

```bash
docker compose run --rm --no-deps --entrypoint ubxtool chrony \
  -P 14.00 -f /dev/ttyAMA0 -s 9600 -p CFG-NAV5 -v 2

# Only if dynModel is not already Stationary (2):
docker compose run --rm --no-deps --entrypoint ubxtool chrony \
  -P 14.00 -f /dev/ttyAMA0 -s 9600 -p MODEL,2
```

**4. Verify before saving**

```bash
docker compose run --rm --no-deps \
  --entrypoint /usr/local/bin/ublox-config chrony \
  --baud 9600 verify
```

Healthy output includes:

- `CFG-TP5` at 1 Hz with `gridToGps (UTC)`, `Active`, `alignToTow`, `RisingEdge`
- `UBX-TIM-TP` with `UTC:OK`, `qErr:Valid`, `TP:Locked`, and changing `qErr`
- `CFG-NAV5` with `dynModel (Stationary)`
- A 3D fix with several satellites in use

**5. Raise the serial rate to 115200 (optional but recommended)**

```bash
docker compose run --rm --no-deps --entrypoint ubxtool chrony \
  -P 14.00 -f /dev/ttyAMA0 -s 9600 -S 115200
```

After this command, use `--baud 115200` / `-s 115200` for all further tool
invocations.

```bash
docker compose run --rm --no-deps \
  --entrypoint /usr/local/bin/ublox-config chrony \
  --baud 115200 verify
```

**6. Persist to BBR/flash**

Save only after verify looks correct. This stores TIMEPULSE, TIM-TP enable,
stationary mode, and baud (if changed) across power loss.

```bash
docker compose run --rm --no-deps \
  --entrypoint /usr/local/bin/ublox-config chrony \
  --baud 115200 save
```

If you skipped the baud change, save with `--baud 9600` instead.

**7. Restart Chrony and confirm the GPS source**

```bash
docker compose up -d chrony
docker compose exec chrony chronyc sources -v
docker compose exec chrony chronyc tracking
```

After a few minutes the GPS SOCK source should be selected (`*`) with good
reach. Optionally power-cycle the Pi and re-run `inspect` / `verify` at the
saved baud to confirm the configuration persisted.

Antenna sky view still dominates accuracy. Keep `CHRONY_GID=20` (`dialout`)
when the GPS UART is group-owned by that group on the host.

### Log timezone

Chrony timestamps daemon and measurement logs in UTC by design; its log
timezone cannot be changed with `TZ`. The startup script explicitly launches
Chrony with `TZ=UTC` to keep that behavior unambiguous. The configured `TZ` is
validated against the installed IANA timezone database and applies to other
container tools. Convert Chrony timestamps in the log viewer when local-time
display is required.

### Service identity

The image defaults to UID 108 and GID 20. Alpine assigns GID 20 to `dialout`,
which matches typical serial-device group ownership. The published GHCR image
bakes those defaults into the `chrony` account.

Set `CHRONY_UID` and `CHRONY_GID` in `.env` to run as a different identity
without rebuilding. Startup remaps the named `chrony` account at runtime via
`nss_wrapper` (so it works with the read-only root filesystem) and owns
runtime/state paths accordingly. Keep `CHRONY_GID=20` when the GPS serial
device is group-owned by `dialout`.

Build arguments remain available for images that should bake a non-default
identity as their baseline.

## Health check

The image runs:

```bash
chronyc waitsync 1
```

This checks that Chrony has synchronized to a usable source without parsing
human-readable command output. A two-minute start period allows time for an
initial GPS fix.

## Build and release pipeline

GitHub Actions performs the following checks:

- ShellCheck validation of the startup and test scripts
- Compose configuration validation
- Container image build
- Startup validation, generated-config, and hardened smoke tests
- Image health-check metadata validation
- Native AMD64 and ARM64 builds

Run the container suite locally after building an image:

```bash
docker build --tag gpsntp:test --file Dockerfile.gpsntp .
tests/test-container.sh gpsntp:test
```

Pushes to `main` publish `main`, `sha-*`, and `latest` tags to GHCR. Tags
starting with `v` also publish a matching release tag. Pull requests validate
and build both architectures without publishing.
