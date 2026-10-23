# FTWeb Export Tools


| Script            | What it does                                                                                                                                                |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ftweb-export.sh` | Lists tournaments, lets you pick one, then periodically downloads every event's result XML to a local folder or SMB share, replacing each file every cycle. |
| `ftweb-scan.sh`   | Sweeps the local subnet to find which machine is running FTWeb.                                                                                             |

Both run under macOS `/bin/sh`, Linux `dash`/`bash`, and Git Bash / WSL on Windows. The only dependency is `curl`.

**Not tested on Windows, only on Unix!**

## Requirements

- `curl` (required)
- For mounting an SMB share automatically: `mount_smbfs` (macOS, built in) or `mount.cifs` + `sudo` rights (Linux). On Windows, mount the share yourself (`net use`) and pass the mapped path instead.

---

## `ftweb-export.sh`

### Usage

```sh
./ftweb-export.sh [options]
```

| Flag | Meaning | Default |
|---|---|---|
| `-s`, `--server URL` | Server IP or URL; `/ftweb` is added if no path is given | `http://172.20.0.1/ftweb` |
| `-l`, `--location PATH` | Destination: a local dir **or** a share (`//host/share` or `\\host\share`) | `./ftweb-export` |
| `-c`, `--creds USER:PASS` | Credentials for the share (omit for a local path) | *(none)* |
| `-i`, `--interval MIN` | Refresh interval in minutes | `5` |
| `-e`, `--event TID` | Skip the menu, use this tournament id directly | *(interactive)* |
| `-1`, `--once` | Run one cycle and exit (no loop) | *(loops)* |
| `--debug` | Dump raw listing HTML to `/tmp` to help tune the scraper | off |
| `-h`, `--help` | Show help | |

### Examples

```sh
# Local test: write to ./ftweb-export, refresh every 5 minutes
./ftweb-export.sh

# Push to the SMB share with credentials
./ftweb-export.sh -l //172.20.0.251/export -c fencingtime:fencingtime

# Windows-style share path: use single quotes to preserve backslashes
./ftweb-export.sh -l '\\172.20.0.251\export' -c fencingtime:fencingtime

# Skip the menu, 2-minute interval, write to an already-mounted volume
./ftweb-export.sh -i 2 -e 229376 -l /Volumes/export

# One-shot export (no loop)
./ftweb-export.sh -e 229376 --once

# Server IP only: http:// and /ftweb are added automatically
./ftweb-export.sh -s 172.20.0.1 --once
```

An omitted URL scheme is normalized to `http://`. If only a host or IP (with an optional port and trailing slash) is supplied, `/ftweb` is appended.
For example, `172.20.0.1` and `http://172.20.0.1/` both become `http://172.20.0.1/ftweb`. An explicit `/ftweb` is not duplicated; custom application paths and HTTPS URLs are preserved. Also, `-e` takes a **FencingTime tournament ID**, not an individual event ID.

### How it works

1. **Parse & validate** the arguments (bad interval or missing `curl` stops immediately).
2. **Set up the destination.** If `-l` is a share it is mounted to a temp mount point (`mount_smbfs` on macOS, `mount -t cifs` on Linux); a local path is just created with `mkdir -p`. Leading slashes and backslashes are normalized. A mount failure stops the script without attempting to unmount. Successful mounts are unmounted on exit, including `Ctrl-C`; cleanup never prompts for a sudo password and reports any unmount failure.
3. **List tournaments** from `…/Tournaments`, reading tournament IDs from `Events/<tournament-id>` links and names from the table; you pick one. (Skip with `-e`.)
4. **Each cycle:** find every event id in the tournament, download `…/api/v1/events/<id>/xml2019` to a temp file, then atomically `mv` it over `event_<id>.xml` in the destination — so a reader never sees a half-written file.
5. **Sleep** `interval × 60` seconds and repeat (unless `--once`).

A failed export cycle is reported and retried at the next interval.
With `--once`, a failed cycle exits with a nonzero status.

### Output

One file per event in the destination:

```
event_37552128.xml
event_37552129.xml
...
```

### Tuning the tournament/event listing

The per-event XML endpoint is `…/api/v1/events/<event-id>/xml2019`.
The **listing** is scraped from `…/Tournaments`, whose rows link to
`…/Events/<tournament-id>`. That event page lists XML download links containing
the individual event IDs. Duplicate IDs across XML versions are exported only
once. Legacy `Tournaments/<id>` tournament links, event-page routes, and
`Events/<event-id>` event links are also supported.

If fetching the tournament page fails, first check the full `--server` URL.
If the page loads but the menu comes up empty on your install:

```sh
./ftweb-export.sh --debug
```

This writes the raw HTML to `/tmp/ftweb_tournaments.html` (and `/tmp/ftweb_events.html`). Adjust the `grep`/`sed` lines in `list_tournaments()` / `list_event_ids()` to match, or point them at a real listing API if one exists.

---

## `ftweb-scan.sh`

Finds the FTWeb host on the network.

### Usage

```sh
./ftweb-scan.sh [options]
```

| Flag | Meaning | Default |
|---|---|---|
| `-b`, `--base PREFIX` | First three octets to scan, e.g. `172.20.0` | auto-detected |
| `-p`, `--path PATH` | Probe path on each host | `/ftweb/Tournaments` |
| `-f`, `--favorites "A B"` | IPs to check first (space-separated) | `172.20.0.1` |
| `-t`, `--timeout SEC` | Per-host connect timeout | `1` |
| `-h`, `--help` | Show help | |

### Examples

```sh
# Auto-detect the subnet and scan it
./ftweb-scan.sh

# Explicit subnet, two favorites, 2s timeout
./ftweb-scan.sh -b 172.20.0 -f "172.20.0.1 172.20.0.251" -t 2
```

### How it works

1. Auto-detects this machine's IPv4 and derives the `/24` (override with `-b`).
2. Probes the favorite IPs first, then sweeps `.1`–`.254` in parallel batches.
3. For each host, `curl`s `http://<ip><path>` and records the HTTP status code.
4. Prints every host that answered (`200`, `302`, even an app `404`). Hosts with no web server (`000`) are skipped.

Any line in the output is a candidate FTWeb server.

---

## Notes 
- **Credentials on the command line** (`-c user:pass`) are visible in the process list (`ps`) and shell history while running. Fine for a throwaway LAN export; for anything persistent, mount the share out-of-band and pass the mount point as `-l`.
- The scripts are self-contained — no config files, no install step. Just `chmod +x` and run.

## To Do's & tests
- Stresstests 
- Quid if multiple (FT) competitions for same FIE competition ID
- If competition is removed, the XML stays in the export - should it be removed? Extra param?
- Test on Windows
- Test to a Windows share