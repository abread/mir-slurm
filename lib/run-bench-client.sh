#!/usr/bin/env bash
set -e

panic() {
    echo "$@" >&2
    exit 1
}

source "$(dirname "$0")/opt-parser.sh"

# OPTS is used by opt_parse
# shellcheck disable=SC2034
OPTS=(
    BENCH_PATH/M/mirBenchPath/./bench

    RATE/r/rate/
    BURST/b/client-burst/
    DURATION/T/client-duration/
    REQ_SIZE/s/client-reqSize/

    MEMBERSHIP_PATH/m/membership/
)
eval set -- "$(opt_parse OPTS "$0" "$@")"
[[ $# -eq 0 ]] || panic "Unexpected options: $*"

[[ -f "$MEMBERSHIP_PATH" ]] || panic "MEMBERSHIP_PATH does not exist"

ID="$SLURM_PROCID"
[[ -n "$ID" ]] || panic "missing ID/SLURM_PROCID"

exec "$BENCH_PATH" client -b "$BURST" -T "$DURATION" -r "$RATE" -s "$REQ_SIZE" -i "$ID" -m "$MEMBERSHIP_PATH"
