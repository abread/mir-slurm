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
	STAT_PERIOD/P/statPeriod/1

	MEMBERSHIP_PATH/m/membership/
	VERBOSE/v/verbose/false
	CPUPROFILE//cpuprofile/false
	MEMPROFILE//memprofile/false
	TRACE//trace/false
)
opt_parse OPTS "$0" "$@"

sync
[[ -x "$BENCH_PATH" ]] || panic "BENCH_PATH does not exist or is not an executable"
[[ -d "$OUTPUT_DIR" ]] || panic "OUTPUT_DIR does not exist or is not a directory"
[[ -f "$MEMBERSHIP_PATH" ]] || panic "MEMBERSHIP_PATH does not exist"

ID="$(grep -E "/dns4/$(hostname)/" "${MEMBERSHIP_PATH}" | cut -d' ' -f1)"
[[ -n "$ID" ]] || panic "could not compute replica ID for $(hostname)"

echo "$(hostname) has ID $ID" >&2

STATSFILE="${OUTPUT_DIR}/${ID}.csv"
[[ -f "$STATSFILE" ]] && panic "stats file '${STATSFILE}' already exists"

CPUPROFILE_PATH="${OUTPUT_DIR}/replica-${ID}.cpuprof"
MEMPROFILE_PATH="${OUTPUT_DIR}/replica-${ID}.memprof"

CPUPROFILE="${CPUPROFILE+--cpuprofile $CPUPROFILE_PATH}"
MEMPROFILE="${MEMPROFILE+--memprofile $MEMPROFILE_PATH}"
TRACE="${TRACE+--traceFile ${OUTPUT_DIR}/trace-$ID.csv}"

set +e
set -x

export OTEL_SERVICE_NAME="F=$F,node$ID"
export OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://borg.rnl.tecnico.ulisboa.pt:4318/v1/traces
"$BENCH_PATH" node -b "$BATCH_SIZE" -p "$PROTOCOL" -o "$STATSFILE" --statPeriod "${STAT_PERIOD}s" -i "$ID" -m "$MEMBERSHIP_PATH" ${VERBOSE+-v} ${CPUPROFILE} ${MEMPROFILE} ${TRACE}
exit_code=$?

echo "Exit code: $exit_code" >&2

# try to ensure all files are written before exiting
sync

exit $exit_code
