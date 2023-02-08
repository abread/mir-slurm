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
	BURST/b/burst/
	DURATION/T/duration/
	REQ_SIZE/s/reqSize/

	MEMBERSHIP_PATH/m/membership/
	VERBOSE/v/verbose/false
)
opt_parse OPTS "$0" "$@"

sync
[[ -x "$BENCH_PATH" ]] || panic "BENCH_PATH does not exist or is not an executable"
[[ -d "$OUTPUT_DIR" ]] || panic "OUTPUT_DIR does not exist or is not a directory"
[[ -f "$MEMBERSHIP_PATH" ]] || panic "MEMBERSHIP_PATH does not exist"

ID="$SLURM_PROCID"
[[ -n "$ID" ]] || panic "missing ID/SLURM_PROCID"

set +e
set -x

"$BENCH_PATH" client -b "$BURST" -T "${DURATION}s" -r "$RATE" -s "$REQ_SIZE" -i "$ID" -m "$MEMBERSHIP_PATH" ${VERBOSE+-v}
exit_code=$?

echo "Exit code: $exit_code" >&2

# try to ensure all files are written before exiting
sync

exit $exit_code
