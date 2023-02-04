#!/usr/bin/env bash
set -e

source "$(dirname "$0")/opt-parser.sh"

MAX_ATTEMPTS="${MAX_ATTEMPTS:-5}"
RETRY_COOLDOWN="${RETRY_COOLDOWN:-30}"

DEFAULT_OUTPUT_DIR="$(basename "$0"):$(date +"%F_%R:%S"):$(echo "$@" | tr ' ' ':')"
DEFAULT_BENCH_PATH="$(dirname "$0")/../../mir/bin/bench"

# OPTS is used by opt_parse
# shellcheck disable=SC2034
OPTS=(
	BENCH_PATH/M/mirBenchPath/"$DEFAULT_BENCH_PATH"
	OUTPUT_DIR/o/outputDir/"$DEFAULT_OUTPUT_DIR"

	PROTOCOL/p/replica-protocol/
	F/f/max-byz-faults/
	N_CLIENTS/c/num-clients/24
	LOAD/l/load/
	COOLDOWN/C/cooldown/45
	BATCH_SIZE/b/replica-batchSize/
	STAT_PERIOD/P/replica-statPeriod/1s
	BURST/B/client-burst/1024
	DURATION/T/client-duration/120
	REQ_SIZE/s/client-reqSize/256
	REPLICA_VERBOSE/v/replica-verbose/false
	CLIENT_VERBOSE/V/client-verbose/false
)
opt_parse OPTS "$0" "$@"

[[ $F -lt 0 || $N_CLIENTS -le 0 || $RETRY_COOLDOWN -lt 0 || $COOLDOWN -lt 0 ]] && exit 1

SALLOC_SCRIPT="$(dirname "$0")/run-all-from-salloc.sh"

N_SERVERS=$(( 3 * F + 1 ))

SERVER_NODE_SELECTOR=(-x 'lab1p[1-12],lab2p[1-20],lab3p[1-10],lab4p[1-10],lab6p[1-9],lab7p[1-9]')
CLIENT_NODE_SELECTOR=(-x 'lab5p[1-20]')

check_run_ok() {
	local i="$1"
	local outdir
	outdir="$(dirname "$OUTPUT_DIR")/${i},$(basename "$OUTPUT_DIR")"

	(
		[[ -f "$outdir/membership" ]] && \
		[[ $(wc -l < "$outdir/membership") -eq $N_SERVERS ]] && \
		[[ -f "$outdir/run.log" ]] && \
		[[ -f "$outdir/run.err" ]] && \
		[[ $(wc -l < "$outdir/run.err") -gt 10 ]] && \
		(! grep "Usage:" "$outdir"/*.err >/dev/null) && \
		(! grep "Requested" "$outdir/run.err" >/dev/null) && \
		(! grep "failed to CBOR marshal message:" "$outdir"/*.log >/dev/null) && \
		[[ "$(cat "$outdir"/*.csv | cut -d, -f2 | grep -E '^[0-9]+$' | paste -s -d+ - | bc)" -ge $(( ( (LOAD * 99) / 100 ) * N_SERVERS * DURATION )) ]]
	) || return 1

	for i in $(seq 0 $(( N_SERVERS - 1))); do
		[[ -f "$outdir/$i.csv" ]] || return 1
		[[ $(wc -l < "$outdir/$i.csv") -gt 2 ]] || return 1
	done
}

EXP_DURATION=$(( ( DURATION + COOLDOWN ) / 60 + 2 ))

try_run() {
	local i="$1"
	local outdir wipdir
	outdir="$(dirname "$OUTPUT_DIR")/${i},$(basename "$OUTPUT_DIR")"
	wipdir="$(dirname "$OUTPUT_DIR")/WIP.$(basename "$outdir")"

	mkdir "$wipdir"

	salloc \
		"${SERVER_NODE_SELECTOR[@]}" -n "$N_SERVERS" --cpus-per-task=4 --ntasks-per-node=1 --exclusive -t $EXP_DURATION : \
		"${CLIENT_NODE_SELECTOR[@]}" -n "$N_CLIENTS" --cpus-per-task=1 --ntasks-per-node=4 --exclusive -t $EXP_DURATION -- \
		"$SALLOC_SCRIPT" -M "$BENCH_PATH" -o "$(realpath "$wipdir")" -l "$LOAD" -C "$COOLDOWN" -c "$N_CLIENTS" -b "$BATCH_SIZE" \
			-p "$PROTOCOL" -P "$STAT_PERIOD" -B "$BURST" -T "$DURATION" -s "$REQ_SIZE" ${REPLICA_VERBOSE+-v} ${CLIENT_VERBOSE+-V} \
		> "${wipdir}/run.log" 2> "${wipdir}/run.err"
	ret=$?

	mv "$wipdir" "$outdir"
	return $ret
}

for i in $(seq 0 "$MAX_ATTEMPTS"); do
	RUN_OUT_DIR="$(dirname "$OUTPUT_DIR")/${i},$(basename "$OUTPUT_DIR")"
	if try_run "$i" && sync && sleep "$RETRY_COOLDOWN" && check_run_ok "$i"; then
		mv "$RUN_OUT_DIR" "$OUTPUT_DIR"
		exit 0
	else
		FAIL_OUT_DIR="$(dirname "$OUTPUT_DIR")/FAIL.${i},$(date +"%F_%R:%S"),$(basename "$OUTPUT_DIR")"
		mv "$RUN_OUT_DIR" "$FAIL_OUT_DIR"
	fi

	echo "run for $OUTPUT_DIR failed, retrying"
done

exit 1
