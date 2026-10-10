#!/usr/bin/env bash
set -uo pipefail

# --- Config (env-overridable) ---
CPU_WARN=${CPU_WARN:-80}
CPU_CRIT=${CPU_CRIT:-90}
MEM_WARN=${MEM_WARN:-75}
MEM_CRIT=${MEM_CRIT:-90}
DISK_WARN=${DISK_WARN:-80}
DISK_CRIT=${DISK_CRIT:-95}
LOG_FILE=${LOG_FILE:-$HOME/LinuxLab/logs/health.log}

# --- Collectors ---

get_cpu_usage() {
    if ! command -v mpstat >/dev/null 2>&1; then
        echo "get_cpu_usage: mpstat not found (install sysstat)" >&2
        return 1
    fi

    local idle
    idle=$(LC_ALL=C mpstat 1 1 | awk '/^Average:/ && $2 == "all" {print $NF}')

    if [[ ! "$idle" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        echo "get_cpu_usage: could not parse idle value" >&2
        return 1
    fi

    awk -v idle="$idle" 'BEGIN { printf "%.1f\n", 100 - idle }'
}

get_memory_usage() {
    local usage
    usage=$(LC_ALL=C free -m | awk '/^Mem:/ {printf "%.1f", ($2 - $7)/$2 * 100}')

    if [[ -z $usage ]]; then
        echo "get_memory_usage: failed to read memory" >&2
        return 1
    fi
    echo "$usage"
}

get_disk_usage() {
    local usage
    usage=$(LC_ALL=C df -P / | awk 'NR==2 {print $5}' | tr -d '%')

    if [[ -z $usage ]]; then
        echo "get_disk_usage: failed to read disk" >&2
        return 1
    fi
    echo "$usage"
}

# --- Logic ---

classify() {
    local value=${1:-}
    local warn=${2:-}
    local crit=${3:-}
    local n order

    for n in "$value" "$warn" "$crit"; do
        if [[ ! $n =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            echo "classify: '$n' is not a number" >&2
            return 1
        fi
    done

    order=$(awk -v w="$warn" -v c="$crit" 'BEGIN { if (w < c) print "good"; else print "bad" }')
    if [[ $order == "bad" ]]; then
        echo "classify: warn ($warn) must be less than crit ($crit)" >&2
        return 1
    fi

    awk -v v="$value" -v w="$warn" -v c="$crit" 'BEGIN {
        if (v > c)       print "CRITICAL"
        else if (v >= w) print "WARNING"
        else             print "OK"
    }'
}

status_to_num() {
    case ${1:-} in
        OK)        echo 0 ;;
        WARNING)   echo 1 ;;
        UNKNOWN)   echo 1 ;;
        CRITICAL)  echo 2 ;;
        *)  echo "status_to_num: unknown status '${1:-}'" >&2; return 1 ;;
    esac
}

# Turns a number back into a word
num_to_status() {
    case ${1:-} in
        0) echo OK ;;
        1) echo WARNING ;;
        2) echo CRITICAL ;;
        *) echo "num_to_status: bad number '${1:-}'" >&2; return 1 ;;
    esac
}

# Gives a status word for one metric. A failed collector shows up as "N/A".
get_status() {
    local value=$1 warn=$2 crit=$3
    if [[ $value == "N/A" ]]; then
        echo UNKNOWN
    else
        classify "$value" "$warn" "$crit" || echo UNKNOWN
    fi
}

# --- Report ---

# Prints one table row
print_row() {
    local label=$1 value=$2 limits=$3 status=$4
    local shown="N/A"
    if [[ $value != "N/A" ]]; then
        shown="${value}%"
    fi
    printf " %-10s %-8s %-10s %s\n" "$label" "$shown" "$limits" "$status"
}

show_report() {
    local cpu=$1 mem=$2 disk=$3
    local cpu_s=$4 mem_s=$5 disk_s=$6 overall=$7

    echo "=========================================="
    echo " SERVER HEALTH REPORT"
    echo " Host: $(hostname)"
    echo " Time: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "=========================================="
    echo
    printf " %-10s %-8s %-10s %s\n" "METRIC" "VALUE" "WARN/CRIT" "STATUS"
    printf " %-10s %-8s %-10s %s\n" "------" "-----" "---------" "------"
    print_row "CPU"      "$cpu"  "$CPU_WARN/$CPU_CRIT"   "$cpu_s"
    print_row "MEMORY"   "$mem"  "$MEM_WARN/$MEM_CRIT"   "$mem_s"
    print_row "DISK (/)" "$disk" "$DISK_WARN/$DISK_CRIT" "$disk_s"
    echo
    echo "------------------------------------------"
    echo " OVERALL STATUS: $overall"
    echo "=========================================="
}

# --- Log ---

write_log() {
    local cpu=$1 mem=$2 disk=$3 overall=$4
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "$(date +%Y-%m-%dT%H:%M:%S) host=$(hostname) cpu=$cpu mem=$mem disk=$disk status=$overall" >> "$LOG_FILE"
}

# --- Entry point ---

main() {
    local cpu mem disk
    local cpu_s mem_s disk_s
    local s n worst=0 overall

    # 1. Bad thresholds are a config error: stop with exit code 3
    classify 0 "$CPU_WARN"  "$CPU_CRIT"  > /dev/null || exit 3
    classify 0 "$MEM_WARN"  "$MEM_CRIT"  > /dev/null || exit 3
    classify 0 "$DISK_WARN" "$DISK_CRIT" > /dev/null || exit 3

    # 2. Collect. If a collector fails, the value becomes "N/A"
    cpu=$(get_cpu_usage)    || cpu="N/A"
    mem=$(get_memory_usage) || mem="N/A"
    disk=$(get_disk_usage)  || disk="N/A"

    # 3. Judge each metric
    cpu_s=$(get_status "$cpu"  "$CPU_WARN"  "$CPU_CRIT")
    mem_s=$(get_status "$mem"  "$MEM_WARN"  "$MEM_CRIT")
    disk_s=$(get_status "$disk" "$DISK_WARN" "$DISK_CRIT")

    # 4. Keep the worst status number seen
    for s in "$cpu_s" "$mem_s" "$disk_s"; do
        n=$(status_to_num "$s")
        if (( n > worst )); then
            worst=$n
        fi
    done
    overall=$(num_to_status "$worst")

    # 5. Report, log, exit with the worst number
    show_report "$cpu" "$mem" "$disk" "$cpu_s" "$mem_s" "$disk_s" "$overall"
    write_log "$cpu" "$mem" "$disk" "$overall"
    exit "$worst"
}

# Run main only when the file is executed, not when it is sourced
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
