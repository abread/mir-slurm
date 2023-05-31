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
	CRYPTO_IMPL_TYPE//crypto-impl-type/pseudo
)
opt_parse OPTS "$0" "$@"

sync
[[ -x "$BENCH_PATH" ]] || panic "BENCH_PATH does not exist or is not an executable"
[[ -d "$OUTPUT_DIR" ]] || panic "OUTPUT_DIR does not exist or is not a directory"
[[ -f "$MEMBERSHIP_PATH" ]] || panic "MEMBERSHIP_PATH does not exist"

ID="$(cat "${MEMBERSHIP_PATH}" | jq -r '(.validators | map(select(.net_addr == "'"/dns4/$(hostname)/tcp/${MIR_PORT}"'")))[0].addr')"
[[ -n "$ID" ]] || panic "could not compute replica ID for $(hostname)"

echo "$(hostname) has ID $ID" >&2

REAL_OUTPUT_DIR="${OUTPUT_DIR}"
OUTPUT_DIR="$(mktemp -d /tmp/runmir.XXXXXXXXX)"

cp "${BENCH_PATH}" "${OUTPUT_DIR}/"
BENCH_PATH="$(basename "$BENCH_PATH")"
cp "${MEMBERSHIP_PATH}" "${OUTPUT_DIR}/"
MEMBERSHIP_PATH="$(basename "$MEMBERSHIP_PATH")"

STATSFILE="replica-${ID}.csv"
[[ -f "${REAL_OUTPUT_DIR}/$STATSFILE" ]] && panic "stats file '${STATSFILE}' already exists"

CPUPROFILE_PATH="replica-${ID}.cpuprof"
MEMPROFILE_PATH="replica-${ID}.memprof"

CPUPROFILE="${CPUPROFILE+--cpuprofile $CPUPROFILE_PATH}"
MEMPROFILE="${MEMPROFILE+--memprofile $MEMPROFILE_PATH}"
TRACE="${TRACE+--traceFile trace-$ID.csv}"
#TRACE="${TRACE+--traceFile trace-$ID.csv --enableOTLP}"

export OTEL_SERVICE_NAME="F=$F,node$ID"
export OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://borg.rnl.tecnico.ulisboa.pt:4318/v1/traces

cd "$OUTPUT_DIR"

sync
ls "$REAL_OUTPUT_DIR" >/dev/null || true
sync

(
NODES="$(cat "$MEMBERSHIP_PATH" | jq -r '.validators[].net_addr' | cut -d/ -f3)"
for n in $NODES; do
	echo "$n"
	ping -c 5 "$n"
	echo
done
) > "ping-from-$ID-$(hostname).out"

w > "otherusers-$ID-$(hostname).out"
ps ax > "processes-$ID-$(hostname).out"

set +e
set -x

"./$BENCH_PATH" node -b "$BATCH_SIZE" -p "$PROTOCOL" -o "$STATSFILE" --statPeriod "${STAT_PERIOD}s" -i "$ID" -m "$MEMBERSHIP_PATH" ${VERBOSE+-v} ${CPUPROFILE} ${MEMPROFILE} ${TRACE} --cryptoImplType "${CRYPTO_IMPL_TYPE}" &
bench_pid=$!

set +x
set -e

cleanup() {
	exit_code=$1
	echo "Exit code: $exit_code" >&2

	sync
	ls "$REAL_OUTPUT_DIR" >/dev/null || true
	sync

	rm "${OUTPUT_DIR}/${BENCH_PATH}"
	rm "${OUTPUT_DIR}/${MEMBERSHIP_PATH}"

	sleep "$ID" # stagger writes

	sync
	ls "$REAL_OUTPUT_DIR" >/dev/null || true
	sync

	if mv "${OUTPUT_DIR}/"* "${REAL_OUTPUT_DIR}/"; then
		rmdir "${OUTPUT_DIR}"
	else
		echo "could not save output. stored at ${OUTPUT_DIR}"
		[ "$exit_code" -eq 0 ] && exit_code=1
	fi

	# try to ensure all files are written before exiting
	sync

	trap - EXIT SIGINT SIGTERM
	echo "exiting with $exit_code" >&2
	exit $exit_code
}
stop_bench_and_cleanup() {
	trap '' EXIT SIGINT SIGTERM # ignore during cleanup

	echo "$(date): stopping node" >&2
	kill -TERM $bench_pid || true
	wait
	exit_code=$?
	echo "node stopped" >&2

	cleanup $exit_code
}
trap stop_bench_and_cleanup EXIT SIGINT SIGTERM

wait
exit_code=$?
trap '' EXIT SIGINT SIGTERM # ignore during cleanup
cleanup $exit_code
