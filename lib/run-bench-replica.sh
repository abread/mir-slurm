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
	OUTPUT_DIR/o/outputDir/

	MEMBERSHIP_PATH/m/membership/
	CONFIG_PATH/c/config/
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
[[ -f "$CONFIG_PATH" ]] || panic "CONFIG_PATH does not exist"

ID="$(cat "${MEMBERSHIP_PATH}" | jq -r '(.validators | map(select(.net_addr == "'"/dns4/$(hostname)/tcp/${MIR_PORT}"'")))[0].addr')"
[[ -n "$ID" ]] || panic "could not compute replica ID for $(hostname)"

echo "$(hostname) has ID $ID" >&2

REAL_OUTPUT_DIR="${OUTPUT_DIR}"
OUTPUT_DIR="$(mktemp -d /tmp/runmir.XXXXXXXXX)"

cp "${BENCH_PATH}" "${OUTPUT_DIR}/"
BENCH_PATH="./$(basename "$BENCH_PATH")"
cp "${CONFIG_PATH}" "${OUTPUT_DIR}/"
CONFIG_PATH="./$(basename "$CONFIG_PATH")"

REPLICA_STATSFILE="replica-${ID}.csv"
CLIENT_STATSFILE="client-${ID}.csv"
NET_STATSFILE="net-${ID}.csv"
RESULTS_FILE="results-${ID}.json"
CPUPROFILE_PATH="replica-${ID}.cpuprof"
MEMPROFILE_PATH="replica-${ID}.memprof"

for f in $REPLICA_STATSFILE $CLIENT_STATSFILE $NET_STATSFILE $RESULTS_FILE $CPUPROFILE_PATH $MEMPROFILE_PATH; do
	[[ -f "${REAL_OUTPUT_DIR}/$f" ]] && panic "output file '${STATSFILE}' already exists"
done


CPUPROFILE="${CPUPROFILE+--cpuprofile '${OUTPUT_DIR}/${CPUPROFILE_PATH}'}"
MEMPROFILE="${MEMPROFILE+--memprofile '${OUTPUT_DIR}/${MEMPROFILE_PATH}'}"
TRACE="${TRACE+--traceFile '${OUTPUT_DIR}/trace-${ID}.csv'}"
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

# set soft mem limit 100MiB lower than the hard max
export GOMEMLIMIT=10140MiB

set +e
set -x

"$BENCH_PATH" node -i "$ID" -c "$CONFIG_PATH" \
	--replica-stat-file "${OUTPUT_DIR}/$REPLICA_STATSFILE" --client-stat-file "${OUTPUT_DIR}/$CLIENT_STATSFILE" --net-stat-file "${OUTPUT_DIR}/$NET_STATSFILE" --summary-stat-file "${OUTPUT_DIR}/$RESULTS_FILE" \
	${VERBOSE+-v} ${CPUPROFILE} ${MEMPROFILE} ${TRACE}
exit_code=$?

set +x
set -e

echo "bench exited with code $exit_code" >&2

rm "${OUTPUT_DIR}/${BENCH_PATH}"
rm "${OUTPUT_DIR}/${CONFIG_PATH}"

sleep $(( ID * 10 )) # stagger writes
sync

if mv "${OUTPUT_DIR}/"* "${REAL_OUTPUT_DIR}/"; then
	rmdir "${OUTPUT_DIR}"
else
	echo "could not save output. stored at ${OUTPUT_DIR}" >&2
	[ "$exit_code" -eq 0 ] && exit_code=1
fi

# try to ensure all files are written before exiting
sync
sleep 15
sync

echo "exiting with $exit_code" >&2
exit $exit_code
