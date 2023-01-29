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

    PROTOCOL/p/protocol/
    BATCH_SIZE/b/batchSize/
    OUTPUT_DIR/o/outputDir/
    STAT_PERIOD/P/statPeriod/5s

    MEMBERSHIP_PATH/m/membership/
)
opt_parse OPTS "$0" "$@"

[[ -f "$MEMBERSHIP_PATH" ]] || panic "MEMBERSHIP_PATH does not exist"

ID="$(grep -E "/dns4/$(hostname)/" "${MEMBERSHIP_PATH}" | cut -d' ' -f1)"
[[ -n "$ID" ]] || panic "could not compute replica ID for $(hostname)"

echo "$(hostname) has ID $ID" >&2

STATSFILE="${OUTPUT_DIR}/${ID}.csv"
[[ -f "$STATSFILE" ]] && exit 1

# try to ensure all files are written before exiting
trap sync exit

"$BENCH_PATH" node -b "$BATCH_SIZE" -p "$PROTOCOL" -o "$STATSFILE" --statPeriod "$STAT_PERIOD" -i "$ID" -m "$MEMBERSHIP_PATH" \
    |& sed "s|^|Node $ID/$(hostname): |"
