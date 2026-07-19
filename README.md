# GPS NTP server

Alpine-based Chrony NTP server with optional GPS, PPS, and PTP hardware
sources. GPSD supplies NMEA time from a serial receiver, while Chrony can use
PPS and PTP devices directly for higher-precision synchronization.

Prebuilt `linux/amd64` and `linux/arm64` images are published to:

```text
ghcr.io/theaustrian75/gpsntp
```

## Deploy with Compose

The included Compose file expects `/dev/ttyAMA0`, `/dev/pps0`, and `/dev/ptp0`
on the host. Remove any device mappings that are not present.

```bash
cp .env.example .env
# Edit .env for your network and time sources.
docker compose up -d --build
docker compose ps
docker compose logs -f chrony
```

The container uses host networking to serve UDP port 123. It has a read-only
root filesystem; generated configuration and runtime state are kept in tmpfs.
The `SYS_TIME` capability is required when `ENABLE_SYSCLK=true`.

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
- `NTP_DIRECTIVES`: additional Chrony directives; defaults to
  `ratelimit\nrtcsync`.
- `NTP_ALLOW`: client network, `all`, or empty to disable clients; defaults
  to `all`.
- `DEV_TTY`: GPS serial device basename; auto-detects `ttyAMA0`.
- `DEV_PPS`: PPS device basename; auto-detects `pps0`.
- `ENABLE_NTS`: enable NTS for configured upstream servers; defaults to
  `false`.
- `ENABLE_SYSCLK`: permit Chrony to adjust the system clock; defaults to
  `false`.
- `NOCLIENTLOG`: disable Chrony client-access logging; defaults to `false`.
- `LOG_LEVEL`: Chrony log level from `0` through `3`; defaults to `0`.
- `TZ`: container timezone; defaults to `America/New_York`.

`/dev/ptp0` is used automatically when it is mapped into the container.
Explicitly configured GPS or PPS devices must exist or startup fails.

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

- ShellCheck validation of the startup script
- Compose configuration validation
- Container image build and embedded startup-script validation
- Image health-check metadata validation
- Native AMD64 and ARM64 builds

Pushes to `main` publish `main`, `sha-*`, and `latest` tags to GHCR. Tags
starting with `v` also publish a matching release tag. Pull requests validate
and build both architectures without publishing.
