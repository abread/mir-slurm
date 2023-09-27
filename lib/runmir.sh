#!/usr/bin/env bash
set -e

source "$(dirname "$0")/opt-parser.sh"

MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
RETRY_COOLDOWN="${RETRY_COOLDOWN:-60}"
STAT_PERIOD=5

DEFAULT_OUTPUT_DIR="$(basename "$0"):$(date +"%F_%R:%S"):$(echo "$@" | tr ' ' ':')"
DEFAULT_BENCH_PATH="$(dirname "$0")/../../mir/bin/bench"

# OPTS is used by opt_parse
# shellcheck disable=SC2034
OPTS=(
	BENCH_PATH/M/mirBenchPath/"$DEFAULT_BENCH_PATH"
	OUTPUT_DIR/o/outputDir/"$DEFAULT_OUTPUT_DIR"

	PROTOCOL/p/protocol/
	F/f/max-byz-faults/
	N_CLIENTS/c/num-clients/1
	BATCH_SIZE/b/batchSize/
	DURATION/D/duration/120
	REQ_SIZE/s/reqSize/256
	VERBOSE/v/verbose/false
	CPUPROFILE//cpuprofile/false
	MEMPROFILE//memprofile/false
	TRACE//replica-trace/false
	CRYPTO_IMPL_TYPE//crypto-impl-type/pseudo

	# not used for anything, just useful for running an experiment multiple times
	ID/i/execution-id/-
)
opt_parse OPTS "$0" "$@"

[[ $F -lt 0 || $N_CLIENTS -le 0 || $RETRY_COOLDOWN -lt 0 ]] && exit 1

SALLOC_SCRIPT="$(dirname "$0")/run-all-from-salloc.sh"

N=$(( 3 * F + 1 ))

SERVER_NODE_SELECTOR=( -C 'lab1|lab7' )

check_run_ok() {
	local i="$1"
	local outdir
	outdir="$(dirname "$OUTPUT_DIR")/${i},$(basename "$OUTPUT_DIR")"

	if [[ ! -f "$outdir/membership" ]]; then
		echo "bad run: missing membership" >&2
		return 1
	elif [[ $(cat "$outdir/membership" | jq '.validators | length') -ne $N ]]; then
		echo "bad run: membership contains an unexpected number of replicas" >&2
		return 1
	elif [[ ! -f "$outdir/run.log" ]]; then
		echo "bad run: missing run.log" >&2
		return 1
	elif [[ ! -f "$outdir/run.err" ]]; then
		echo "bad run: missing run.err" >&2
		return 1
	elif [[ $(wc -l < "$outdir/run.err") -lt 6 ]]; then
		echo "bad run: run.err unexpectedly short (<6 lines)" >&2
		return 1
	elif grep "Usage:" "$outdir"/*.err >/dev/null; then
		echo "bad run: found command usage help in stderr" >&2
		return 1
	elif grep "Requested" "$outdir"/run.err >/dev/null; then
		echo "bad run: found slurm allocation problem in run.err" >&2
		return 1
	elif grep "failed to CBOR marshal message:" "$outdir"/*.log >/dev/null; then
		echo "bad run: found message marshalling error in logs/stdout" >&2
		return 1
	elif [[ "$(cat "$outdir"/replica-*.csv | cut -d, -f2 | grep -E '^[0-9]+$' | paste -s -d+ - | bc)" -lt $(( N * 10 )) ]]; then
		echo "bad run: #delivered txs too low (<10/node)" >&2
		return 1
	fi

	for i in $(seq 0 $(( N - 1))); do
		if [[ ! -f "$outdir/replica-$i.csv" ]]; then
			echo "bad run: replica $i has no stats" >&2
			return 1
		elif [[ $(wc -l < "$outdir/replica-$i.csv") -le 2 ]]; then
			echo "bad run: replica $i has almost no stats (<=2 lines) " >&2
			return 1
		elif [[ ! -f "$outdir/client-$i.csv" ]]; then
			echo "bad run: client for replica $i has no stats" >&2
			return 1
		elif [[ $(wc -l < "$outdir/client-$i.csv") -le 2 ]]; then
			echo "bad run: client for replica $i has almost no stats (<=2 lines) " >&2
			return 1
		elif [[ ! -f "$outdir/net-$i.csv" ]]; then
			echo "bad run: net for replica $i has no stats" >&2
			return 1
		elif [[ $(wc -l < "$outdir/net-$i.csv") -le 2 ]]; then
			echo "bad run: net for replica $i has almost no stats (<=2 lines) " >&2
			return 1
		elif [[ ! -f "$outdir/results-$i.json" ]]; then
			echo "bad run: results for replica $i don't exist" >&2
			return 1
		elif [[ $(wc -l < "$outdir/results-$i.csv") -le 10 ]]; then
			echo "bad run: results for replica $i is corrupted (<=10 lines) " >&2
			return 1
		fi
	done
}

EXP_DURATION=$(( ( DURATION + N * 2 ) / 60 + 4 ))

try_run() {
	local i="$1"
	local outdir wipdir
	outdir="$(dirname "$OUTPUT_DIR")/${i},$(basename "$OUTPUT_DIR")"
	wipdir="$(dirname "$OUTPUT_DIR")/WIP.$(basename "$outdir")"

	mkdir "$wipdir"

	export F
	salloc \
		"${SERVER_NODE_SELECTOR[@]}" -n "$N" --cpus-per-task=4 --mem=0 --ntasks-per-node=1 --exclusive -t $EXP_DURATION : \
		"$SALLOC_SCRIPT" -M "$BENCH_PATH" -o "$(realpath "$wipdir")" \
		-c "$N_CLIENTS" -b "$BATCH_SIZE" -p "$PROTOCOL" -D "$DURATION" -s "$REQ_SIZE" --crypto-impl-type "${CRYPTO_IMPL_TYPE}" \
 		${VERBOSE+-v} ${CPUPROFILE:+--cpuprofile} ${MEMPROFILE:+--memprofile} ${TRACE+--trace} ${CLIENT_CPUPROFILE:+--client-cpuprofile} \
		> "${wipdir}/run.log" 2> "${wipdir}/run.err"
	ret=$?

	if [ $ret -ne 0 ]; then
		echo "bad run: salloc exited with non-zero code" >&2
	fi

    sync
    sleep "${RETRY_COOLDOWN}"
    sync

	mv "$wipdir" "$outdir"
	return $ret
}

for i in $(seq 0 "$(( MAX_ATTEMPTS - 1 ))"); do
	RUN_OUT_DIR="$(dirname "$OUTPUT_DIR")/${i},$(basename "$OUTPUT_DIR")"
	if try_run "$i" && check_run_ok "$i"; then
		mv "$RUN_OUT_DIR" "$OUTPUT_DIR"
		exit 0
	else
		FAIL_OUT_DIR="$(dirname "$OUTPUT_DIR")/FAIL.${i},$(date +"%F_%R:%S"),$(basename "$OUTPUT_DIR")"
		mv "$RUN_OUT_DIR" "$FAIL_OUT_DIR"
	fi

	echo "run for $OUTPUT_DIR failed, retrying"
done

exit 1
