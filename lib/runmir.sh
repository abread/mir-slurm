#!/usr/bin/env bash
set -e

source "$(dirname "$0")/opt-parser.sh"

MAX_ATTEMPTS="${MAX_ATTEMPTS:-5}"
RETRY_COOLDOWN="${RETRY_COOLDOWN:-30}"
BENCH_PATH="${BENCH_PATH:-$(dirname "$0")/../../mir/bin/bench}"
export BENCH_PATH

DEFAULT_OUTPUT_DIR="$(basename "$0"):$(date +"%F_%R:%S"):$(echo "$@" | tr ' ' ':')"

# OPTS is used by opt_parse
# shellcheck disable=SC2034
OPTS=(
    PROTOCOL/p/replica-protocol/
    F/f/max-byz-faults/
    N_CLIENTS/c/num-clients/8
    LOAD/l/load/
    COOLDOWN/C/cooldown/60
    OUTPUT_DIR/o/outputDir/"$DEFAULT_OUTPUT_DIR"
    BATCH_SIZE/b/replica-batchSize/
    STAT_PERIOD/P/replica-statPeriod/5s
    BURST/B/client-burst/1024
    DURATION/T/client-duration/120
    REQ_SIZE/s/client-reqSize/256
)
opt_parse OPTS "$0" "$@"

[[ $F -lt 0 || $N_CLIENTS -le 0 || $RETRY_COOLDOWN -lt 0 || $COOLDOWN -lt 0 ]] && exit 1

SALLOC_SCRIPT="$(realpath "$(dirname "$0")/run-all-from-salloc.sh")"
BENCH_PATH="$(realpath "$BENCH_PATH")"
cd "$(dirname "$OUTPUT_DIR")"
OUTPUT_DIR="$(basename "$OUTPUT_DIR")"

N_SERVERS=$(( 3 * F + 1 ))

SERVER_NODE_SELECTOR=(-x 'lab1p[1-12],lab2p[1-20],lab3p[1-10],lab4p[1-10],lab6p[1-9],lab7p[1-9]')
CLIENT_NODE_SELECTOR=(-x 'lab1p[1-12],lab2p[1-20],lab3p[1-10],lab5p[1-20],lab6p[1-9],lab7p[1-9]')

check_run_ok() {
    local i="$1"
    local outdir="${i}:${OUTPUT_DIR}"

    (
        [[ -f "$outdir/membership" ]] && \
        [[ $(wc -l < "$outdir/membership") -eq $N_SERVERS ]] && \
        [[ -f "$outdir/run.log" ]] && \
        [[ -f "$outdir/run.err" ]] && \
        [[ $(wc -l < "$outdir/run.err") -gt 10 ]] && \
        (! grep "Usage:" "$outdir/run.err" >/dev/null) && \
        (! grep "Requested" "$outdir/run.err" >/dev/null)
    ) || return 1

    for i in $(seq 0 "$N_SERVERS"); do
        [[ $(wc -l < "$outdir/$i.csv") -gt 2 ]] || return 1
    done
}

EXP_DURATION=$(( ( DURATION + COOLDOWN ) / 60 + 2 ))

try_run() {
    local i="$1"
    local outdir="${i}:${OUTPUT_DIR}"
    local wipdir="WIP.${outdir}"

    mkdir -p "$wipdir"

    salloc \
        "${SERVER_NODE_SELECTOR[@]}" -n "$N_SERVERS" --cpus-per-task=4 --ntasks-per-node=1 --exclusive -t $EXP_DURATION : \
        "${CLIENT_NODE_SELECTOR[@]}" -n "$N_CLIENTS" --cpus-per-task=1 --ntasks-per-node=4 --exclusive -t $EXP_DURATION  -- \
        "$SALLOC_SCRIPT" -l "$LOAD" -C "$COOLDOWN" -o "$(realpath "$wipdir")" -b "$BATCH_SIZE" \
            -p "$PROTOCOL" -P "$STAT_PERIOD" -B "$BURST" -T "${DURATION}s" -s "$REQ_SIZE" \
        > "${wipdir}/run.log" 2> "${wipdir}/run.err"

    mv "$wipdir" "$outdir"
}

for i in $(seq 0 "$MAX_ATTEMPTS"); do
    if try_run "$i" && check_run_ok "$i"; then
        mv "${i}:${OUTPUT_DIR}" "${OUTPUT_DIR}"
        break
    fi

    echo "run for $OUTPUT_DIR failed, retrying in $RETRY_COOLDOWN secs"
    sleep "$RETRY_COOLDOWN"
done
