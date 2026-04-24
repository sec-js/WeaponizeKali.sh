#!/usr/bin/env bash

set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
CYN='\033[0;36m'
RST='\033[0m'

# ─── Usage ────────────────────────────────────────────────────────────────────
usage() {
    echo -e "\
${YEL}Usage:${RST}
  $(basename "$0") <TIMEOUT> <IP> <PORT> [RESOLVE_FLAG] [THREADS]

${CYN}Arguments:${RST}
  TIMEOUT     Connection timeout in seconds (integer)
  IP          Target host(s) — accepts:
                • Single IP/hostname          192.168.1.1 / host.example.com
                • Comma-separated list        192.168.1.1,192.168.1.2
                • CIDR notation               192.168.1.0/24
                • IP range (dash)             10.0.0.1-10.0.0.20
                • Short range                 192.168.1.1-20
                • File (one target per line)   /path/to/hosts.txt
  PORT        Target port(s) — accepts:
                • Single port                 80
                • Comma-separated             22,80,443
                • Range (dash)                20-25
  RESOLVE     (optional) 'r' or 'resolve' — omit -n from nc to enable DNS resolution
  THREADS     (optional) Number of parallel jobs (requires GNU parallel)

${CYN}Examples:${RST}
  $(basename "$0") 3 192.168.1.1 22
  $(basename "$0") 3 192.168.1.0/24 80,443 r 50
  $(basename "$0") 3 targets.txt 22-25 resolve 20"
    exit 1
}

# ─── Argument validation ─────────────────────────────────────────────────────
[[ $# -lt 3 ]] && usage

TIMEOUT="$1"
IP_ARG="$2"
PORT_ARG="$3"
RESOLVE_FLAG="${4:-}"
THREADS="${5:-}"

# Validate timeout
if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}[!] Error: TIMEOUT must be a positive integer.${RST}" >&2
    exit 1
fi

# Validate resolve flag
RESOLVE=false
if [[ "${RESOLVE_FLAG,,}" == "r" || "${RESOLVE_FLAG,,}" == "resolve" ]]; then
    RESOLVE=true
elif [[ -n "$RESOLVE_FLAG" && "$RESOLVE_FLAG" =~ ^[0-9]+$ && -z "$THREADS" ]]; then
    # User skipped resolve flag and passed threads as 4th arg
    THREADS="$RESOLVE_FLAG"
elif [[ -n "$RESOLVE_FLAG" && ! "$RESOLVE_FLAG" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}[!] Error: Unrecognised RESOLVE flag '${RESOLVE_FLAG}'. Use 'r', 'resolve', or leave empty.${RST}" >&2
    exit 1
fi

# Validate threads
if [[ -n "$THREADS" ]]; then
    if ! [[ "$THREADS" =~ ^[0-9]+$ ]] || [[ "$THREADS" -eq 0 ]]; then
        echo -e "${RED}[!] Error: THREADS must be a positive integer.${RST}" >&2
        exit 1
    fi
    if ! command -v parallel &>/dev/null; then
        echo -e "${RED}[!] Error: GNU parallel is required when THREADS is specified.${RST}" >&2
        echo -e "${YEL}    Install: sudo apt install parallel  /  brew install parallel${RST}" >&2
        exit 1
    fi
fi

# ─── Dependency check ────────────────────────────────────────────────────────
if ! command -v nc &>/dev/null; then
    echo -e "${RED}[!] Missing dependency: nc (netcat)${RST}" >&2
    echo -e "${YEL}    Install: sudo apt install netcat-openbsd${RST}" >&2
    exit 1
fi

if ! command -v prips &>/dev/null; then
    echo -e "${RED}[!] Missing dependency: prips${RST}" >&2
    echo -e "${YEL}    Install: sudo apt install prips${RST}" >&2
    exit 1
fi

# ─── IP arithmetic helpers ───────────────────────────────────────────────────
_ip_to_int() {
    local IFS='.'
    read -r a b c d <<< "$1"
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

_int_to_ip() {
    local ip="$1"
    printf '%d.%d.%d.%d\n' \
        $(( (ip >> 24) & 255 )) \
        $(( (ip >> 16) & 255 )) \
        $(( (ip >> 8)  & 255 )) \
        $((  ip        & 255 ))
}

# ─── Expand IP targets ───────────────────────────────────────────────────────
expand_ips() {
    local input="$1"
    local items=()

    # Split on commas
    IFS=',' read -ra items <<< "$input"

    for item in "${items[@]}"; do
        item="$(echo "$item" | xargs)"   # trim whitespace
        [[ -z "$item" ]] && continue

        if [[ -f "$item" ]]; then
            # ── File: read each line and recursively expand
            while IFS= read -r line || [[ -n "$line" ]]; do
                line="$(echo "$line" | xargs)"
                [[ -z "$line" || "$line" == \#* ]] && continue
                expand_ips "$line"
            done < "$item"

        elif [[ "$item" == *"/"* ]]; then
            # ── CIDR notation
            prips "$item"

        elif [[ "$item" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)-([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
            # ── Full IP range: 10.0.0.1-10.0.0.20
            local start_int end_int
            start_int=$(_ip_to_int "${BASH_REMATCH[1]}")
            end_int=$(_ip_to_int "${BASH_REMATCH[2]}")
            for (( ip = start_int; ip <= end_int; ip++ )); do
                _int_to_ip "$ip"
            done

        elif [[ "$item" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.)([0-9]+)-([0-9]+)$ ]]; then
            # ── Short range: 192.168.1.1-20
            local prefix="${BASH_REMATCH[1]}"
            local lo="${BASH_REMATCH[2]}"
            local hi="${BASH_REMATCH[3]}"
            for (( i = lo; i <= hi; i++ )); do
                echo "${prefix}${i}"
            done

        else
            # ── Single IP or hostname
            echo "$item"
        fi
    done
}

# ─── Expand ports ────────────────────────────────────────────────────────────
expand_ports() {
    local input="$1"
    local items=()
    IFS=',' read -ra items <<< "$input"

    for item in "${items[@]}"; do
        item="$(echo "$item" | xargs)"
        if [[ "$item" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local lo="${BASH_REMATCH[1]}"
            local hi="${BASH_REMATCH[2]}"
            for (( p = lo; p <= hi; p++ )); do
                echo "$p"
            done
        elif [[ "$item" =~ ^[0-9]+$ ]]; then
            echo "$item"
        else
            echo -e "${RED}[!] Invalid port: $item${RST}" >&2
            exit 1
        fi
    done
}

# ─── Core check function ────────────────────────────────────────────────────
check_port() {
    local timeout="$1"
    local host="$2"
    local port="$3"
    local force_resolve="$4"

    # With resolve:    nc  -vzw<T>  (lets nc do DNS resolution / shows resolved name)
    # Without resolve: nc -nvzw<T>  (-n skips DNS)
    local nc_flags
    if [[ "$force_resolve" == "true" ]] || ! [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        nc_flags="-vzw${timeout}"
    else
        nc_flags="-nvzw${timeout}"
    fi

    local output
    # nc writes connection info to stderr
    if output=$(nc $nc_flags "$host" "$port" 2>&1); then
        echo -e "${GRN}[OPEN]${RST} ${host}:${port}"
    else
        echo -e "${RED}[CLOSED]${RST} ${host}:${port}" >&2
    fi
}

# Export for GNU parallel
export -f check_port 2>/dev/null || true
export RED GRN YEL CYN RST 2>/dev/null || true

# ─── Build target list ───────────────────────────────────────────────────────
RAW_TARGETS="$(expand_ips "$IP_ARG")"
mapfile -t IP_LIST < <(
    {
        { grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' <<< "$RAW_TARGETS" || true; } | sort -u -t'.' -k1,1n -k2,2n -k3,3n -k4,4n
        { grep -vE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' <<< "$RAW_TARGETS" || true; } | sort -u
    } | awk 'NF'
)
mapfile -t PORT_LIST < <(expand_ports "$PORT_ARG" | sort -nu)

TOTAL_IPS=${#IP_LIST[@]}
TOTAL_PORTS=${#PORT_LIST[@]}
TOTAL_CHECKS=$(( TOTAL_IPS * TOTAL_PORTS ))

if [[ "$TOTAL_IPS" -eq 0 ]]; then
    echo -e "${RED}[!] No valid targets resolved from '${IP_ARG}'.${RST}" >&2
    exit 1
fi

# echo -e "${YEL}──────────────────────────────────────────────────${RST}"
# echo -e "${CYN} tnc.sh — TCP Port Checker${RST}"
# echo -e "${YEL}──────────────────────────────────────────────────${RST}"
# echo -e " Targets : ${TOTAL_IPS} host(s)"
# echo -e " Ports   : ${TOTAL_PORTS} port(s)  [${PORT_ARG}]"
# echo -e " Checks  : ${TOTAL_CHECKS} total"
# echo -e " Timeout : ${TIMEOUT}s"
# echo -e " Resolve : ${RESOLVE}"
# [[ -n "$THREADS" ]] && echo -e " Threads : ${THREADS} (GNU parallel)"
# echo -e "${YEL}──────────────────────────────────────────────────${RST}"
# echo ""

# ─── Execute checks ─────────────────────────────────────────────────────────
if [[ -n "$THREADS" ]]; then
    # ── Parallel mode ─────────────────────────────────────────────────────
    job_list=$(mktemp)
    for host in "${IP_LIST[@]}"; do
        for port in "${PORT_LIST[@]}"; do
            echo "$TIMEOUT $host $port $RESOLVE"
        done
    done > "$job_list"

    parallel --will-cite -j "$THREADS" --colsep ' ' \
        check_port {1} {2} {3} {4} < "$job_list"

    rm -f "$job_list"
else
    # ── Sequential mode ───────────────────────────────────────────────────
    for host in "${IP_LIST[@]}"; do
        for port in "${PORT_LIST[@]}"; do
            check_port "$TIMEOUT" "$host" "$port" "$RESOLVE"
        done
    done
fi

# echo ""
# echo -e "${YEL}──────────────────────────────────────────────────${RST}"
# echo -e "${GRN} Done. ${TOTAL_CHECKS} check(s) completed.${RST}"
# echo -e "${YEL}──────────────────────────────────────────────────${RST}"
