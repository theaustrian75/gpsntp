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
Chrony's oscillator drift data persists in the `chrony-data` volume. The
`SYS_TIME` capability is required when `ENABLE_SYSCLK=true`.

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
- `CHRONY_UID` / `CHRONY_GID`: numeric Chrony service identity compiled into
  the image; defaults to `108:20`.
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
- `ENABLE_SYSCLK`: permit Chrony to adjust the system clock; defaults to
  `false`.
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
receiver settings, so configure the u-blox persistently before deployment
with u-center or a compatible `ubxtool` version:

- Enable UBX binary output needed by GPSD for the receiver model.
- Configure a 1 Hz timepulse aligned to UTC and valid only with a time fix.
- Use a higher serial rate such as 115200 baud where supported.
- In direct PPS mode, retain RMC or ZDA messages for second identification.
- Save settings to the receiver's supported BBR or flash layer.

u-blox configuration keys and protocol messages vary significantly by
generation and firmware. Follow the integration manual for the exact model
instead of applying generic `ubxtool` write commands.

### Log timezone

Chrony timestamps daemon and measurement logs in UTC by design; its log
timezone cannot be changed with `TZ`. The startup script explicitly launches
Chrony with `TZ=UTC` to keep that behavior unambiguous. The configured `TZ` is
validated against the installed IANA timezone database and applies to other
container tools. Convert Chrony timestamps in the log viewer when local-time
display is required.

### Service identity

The image runs Chrony as UID 108 and GID 20 by default. Alpine assigns GID 20
to `dialout`, which provides the expected serial-device group identity. The
published GHCR image uses these defaults.

UID and GID are build-time settings because Chrony drops privileges through
the named `chrony` account. To use different IDs, update `CHRONY_UID` and
`CHRONY_GID` in `.env`, then rebuild:

```bash
docker compose build --pull
docker compose up -d
```

Compose passes the same values to the container. Startup rejects an identity
mismatch with a rebuild instruction instead of silently applying incorrect
volume ownership.

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
