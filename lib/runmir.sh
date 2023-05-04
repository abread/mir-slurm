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
	CLIENT_TYPE//client-type/dummy
	F/f/max-byz-faults/
	N_CLIENTS/c/num-clients/24
	LOAD/l/load/
	COOLDOWN/C/cooldown/45
	BATCH_SIZE/b/replica-batchSize/
	STAT_PERIOD/P/replica-statPeriod/1
	BURST/B/client-burst/1024
	DURATION/T/client-duration/120
	REQ_SIZE/s/client-reqSize/256
	REPLICA_VERBOSE/v/replica-verbose/false
	CLIENT_VERBOSE/V/client-verbose/false
	REPLICA_CPUPROFILE//replica-cpuprofile/false
	REPLICA_MEMPROFILE//replica-memprofile/false
	REPLICA_TRACE//replica-trace/false
	CLIENT_CPUPROFILE//client-cpuprofile/false
	CLIENT_MEMPROFILE//client-memprofile/false
	CRYPTO_IMPL_TYPE//crypto-impl-type/pseudo

	# not used for anything, just useful for running an experiment multiple times
	ID/i/execution-id/-
)
opt_parse OPTS "$0" "$@"

[[ $F -lt 0 || $N_CLIENTS -le 0 || $RETRY_COOLDOWN -lt 0 || $COOLDOWN -lt 0 ]] && exit 1

SALLOC_SCRIPT="$(dirname "$0")/run-all-from-salloc.sh"

N_SERVERS=$(( 3 * F + 1 ))

SERVER_NODE_SELECTOR=( -C lab5 )
CLIENT_NODE_SELECTOR=( -x 'lab5p[1-20]' )

# limit number of clients based on load
[[ "$N_CLIENTS" -gt $(( LOAD / 256 + 1 )) ]] && N_CLIENTS=$(( LOAD / 256 + 1 ))

check_run_ok() {
	local i="$1"
	local outdir
	outdir="$(dirname "$OUTPUT_DIR")/${i},$(basename "$OUTPUT_DIR")"

	if [[ ! -f "$outdir/membership" ]]; then
		echo "bad run: missing membership" >&2
		return 1
	elif [[ $(cat "$outdir/membership" | jq '.validators | length') -ne $N_SERVERS ]]; then
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
	fi

	case "$CLIENT_TYPE" in
		dummy)
			if [[ "$(cat "$outdir"/*.csv | cut -d, -f2 | grep -E '^[0-9]+$' | paste -s -d+ - | bc)" -lt $(( ( LOAD * N_SERVERS * DURATION * 99 ) / 100 )) ]]; then
				echo "bad run: #received txs lower than expected" >&2
				return 1
			fi
			;;
		rr)
			if [[ "$(cat "$outdir"/*.csv | cut -d, -f2 | grep -E '^[0-9]+$' | paste -s -d+ - | bc)" -lt $(( ( LOAD * DURATION * 99 ) / 100 )) ]]; then
				echo "bad run: #received txs lower than expected" >&2
				return 1
			fi
			;;
		*)
			echo "WARNING: unknown CLIENT_TYPE ${CLIENT_TYPE}. Not checking real load for ${outdir}" >&2
			;;
	esac

	for i in $(seq 0 $(( N_SERVERS - 1))); do
		if [[ ! -f "$outdir/$i.csv" ]]; then
			echo "bad run: replica $i has no stats" >&2
			return 1
		elif [[ $(wc -l < "$outdir/$i.csv") -le 2 ]]; then
			echo "bad run: replica $i has almost no stats (<=2 lines) " >&2
			return 1
		fi
	done
}

EXP_DURATION=$(( ( DURATION + COOLDOWN + 80 + N_SERVERS ) / 60 + 3 ))

try_run() {
	local i="$1"
	local outdir wipdir
	outdir="$(dirname "$OUTPUT_DIR")/${i},$(basename "$OUTPUT_DIR")"
	wipdir="$(dirname "$OUTPUT_DIR")/WIP.$(basename "$outdir")"

	mkdir "$wipdir"

	export F
	salloc \
		"${SERVER_NODE_SELECTOR[@]}" -n "$N_SERVERS" --cpus-per-task=4 --ntasks-per-node=1 --exclusive -t $EXP_DURATION : \
		"${CLIENT_NODE_SELECTOR[@]}" -n "$N_CLIENTS" --cpus-per-task=1 --ntasks-per-node=4 --exclusive -t $EXP_DURATION -- \
		"$SALLOC_SCRIPT" -M "$BENCH_PATH" -o "$(realpath "$wipdir")" -l "$LOAD" -C "$COOLDOWN" -c "$N_CLIENTS" -b "$BATCH_SIZE" \
			-p "$PROTOCOL" --client-type "$CLIENT_TYPE" -P "$STAT_PERIOD" -B "$BURST" -T "$DURATION" -s "$REQ_SIZE" ${REPLICA_VERBOSE+-v} ${CLIENT_VERBOSE+-V} ${REPLICA_CPUPROFILE:+--replica-cpuprofile} ${REPLICA_MEMPROFILE:+--replica-memprofile} ${REPLICA_TRACE+--replica-trace} ${CLIENT_CPUPROFILE:+--client-cpuprofile} ${CLIENT_MEMPROFILE:+--client-memprofile} --crypto-impl-type "${CRYPTO_IMPL_TYPE}" \
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

for i in $(seq 0 "$MAX_ATTEMPTS"); do
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
