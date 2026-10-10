# Server Health Monitor

A Bash script that checks CPU, memory and root-disk usage on a Linux server, classifies each metric as `OK`, `WARNING` or `CRITICAL`, prints a formatted report, appends a one-line record to a log file, and exits with a status code that scripts, cron jobs or CI can act on.

Part of my Bash scripting / DevOps portfolio. The focus is on robust shell practice: configurable thresholds, input validation, graceful handling of failed collectors, and meaningful exit codes.

## Features

- **Three checks**: CPU usage, memory usage, disk usage (`/`)
- **Configurable thresholds** through environment variables, no editing the script
- **Per-metric status** plus an **overall status** (the worst one wins)
- **Graceful degradation**: if a collector fails, that metric shows `N/A` / `UNKNOWN` instead of crashing the script
- **Config validation**: bad or inverted thresholds stop the script with a dedicated exit code
- **Persistent log**: every run appends one machine-readable line
- **Source-safe**: functions can be imported into other scripts or tests without running `main`

## Requirements

- Bash 4+
- `mpstat` (from the `sysstat` package) for CPU usage
- `free`, `df`, `awk`, `hostname` (standard on most Linux distros)

Install `sysstat`:

```bash
# Debian / Ubuntu
sudo apt install sysstat

# RHEL / Fedora / CentOS
sudo dnf install sysstat
```

## Usage

```bash
chmod +x health_monitor.sh
./health_monitor.sh
```

Override thresholds for a single run:

```bash
CPU_WARN=70 CPU_CRIT=85 DISK_WARN=75 ./health_monitor.sh
```

Use a different log location:

```bash
LOG_FILE=/var/log/health.log ./health_monitor.sh
```

## Configuration

All settings are environment variables with defaults:

| Variable    | Default                          | Meaning                    |
|-------------|----------------------------------|----------------------------|
| `CPU_WARN`  | `80`                             | CPU % warning threshold    |
| `CPU_CRIT`  | `90`                             | CPU % critical threshold   |
| `MEM_WARN`  | `75`                             | Memory % warning threshold |
| `MEM_CRIT`  | `90`                             | Memory % critical threshold|
| `DISK_WARN` | `80`                             | Disk % warning threshold   |
| `DISK_CRIT` | `95`                             | Disk % critical threshold  |
| `LOG_FILE`  | `$HOME/LinuxLab/logs/health.log` | Where run records are appended |

Each `*_WARN` value must be lower than its `*_CRIT` value, and all values must be numeric.

## How metrics are calculated

- **CPU**: `100 - idle%`, taken from `mpstat 1 1` (a 1-second sample)
- **Memory**: `(total - available) / total * 100`, from `free -m`
- **Disk**: usage percentage of the `/` filesystem, from `df -P /`

## Status logic

For each metric:

| Condition              | Status     |
|------------------------|------------|
| value > CRIT           | `CRITICAL` |
| WARN <= value <= CRIT  | `WARNING`  |
| value < WARN           | `OK`       |
| collector failed (N/A) | `UNKNOWN`  |

The overall status is the worst of the three. `UNKNOWN` counts as `WARNING` for the overall result.

## Exit codes

| Code | Meaning                                     |
|------|---------------------------------------------|
| `0`  | All metrics OK                              |
| `1`  | At least one WARNING or UNKNOWN             |
| `2`  | At least one CRITICAL                       |
| `3`  | Configuration error (invalid thresholds)    |

Example use in a script:

```bash
./health_monitor.sh
case $? in
    0) echo "all good" ;;
    1) echo "needs attention" ;;
    2) echo "page someone" ;;
    3) echo "fix the config" ;;
esac
```

## Example output

Illustrative; your values and hostname will differ.

```
==========================================
 SERVER HEALTH REPORT
 Host: my-server
 Time: 2026-10-10 18:45:00
==========================================

 METRIC     VALUE    WARN/CRIT  STATUS
 ------     -----    ---------  ------
 CPU        12.5%    80/90      OK
 MEMORY     41.3%    75/90      OK
 DISK (/)   82%      80/95      WARNING

------------------------------------------
 OVERALL STATUS: WARNING
==========================================
```

## Log format

Each run appends one line to `LOG_FILE`:

```
2026-10-10T18:45:00 host=my-server cpu=12.5 mem=41.3 disk=82 status=WARNING
```

The key=value format is easy to parse with `awk`, `grep` or a log shipper.

## Run it automatically with cron

Every 5 minutes:

```cron
*/5 * * * * /path/to/health_monitor.sh >/dev/null 2>&1
```

Results go to the log file; use the exit code or the log to drive alerts.

## Design notes

- **`set -uo pipefail` without `-e`**: failed collectors are handled explicitly (`|| cpu="N/A"`) so one broken check never hides the others.
- **`LC_ALL=C`** on every collector so decimal separators and output labels stay consistent regardless of system locale.
- **Floating-point math via `awk`**, since Bash arithmetic is integer-only.
- **Collectors, logic and reporting are separate functions**, which keeps each piece small and testable.
- **`BASH_SOURCE` guard** lets you `source` the file to unit-test individual functions.

## Project structure

```
.
├── health_monitor.sh
└── README.md
```

## Possible improvements

- Check additional mount points, not just `/`
- Add load average and swap checks
- Log rotation or size cap for `health.log`
- Optional alerting (email / webhook) on `CRITICAL`
- Automated tests with `bats`

## License

MIT (add a `LICENSE` file to the repo)
