# shellcheck shell=bash
set -e

[[ "${BASH_SOURCE[0]}" == "$0" ]] && (
	echo "this is meant to be sourced at the start of your runscript, not be run directly" >&2
	exit 1
)

source "$(dirname "${BASH_SOURCE[0]}")/opt-parser.sh"

RUNMIR="$(dirname "${BASH_SOURCE[0]}")/runmir.sh"
DEFAULT_OUTPUT_DIR="mirbench_$(basename "$0")_$(date +"%F_%R:%S")"
DEFAULT_BENCH_PATH="$(dirname "${BASH_SOURCE[0]}")/../../mir/bin/bench"

panic() {
	echo "$@" >&2
	exit 1
}

# OPTS is used by opt_parse
# shellcheck disable=SC2034
OPTS=(
	OUTPUT_DIR/o/output-dir/"$DEFAULT_OUTPUT_DIR"
	BENCH_PATH/b/bench-path/"$DEFAULT_BENCH_PATH"
	JOBS/j/jobs/32
)

# parse arguments
opt_parse OPTS "$0" "$@"

[[ -e "$OUTPUT_DIR" ]] && panic "OUTPUT_DIR already exists. use retry script instead"
[[ -x "$BENCH_PATH" ]] || panic "BENCH_PATH is not an executable"

echo "Output will be saved in ${OUTPUT_DIR}"
echo "Mir bench to be used is ${BENCH_PATH}"

# prepare output directory
mkdir "$OUTPUT_DIR"

# preserve all used scripts for reproducibility
# and to allow changing scripts mid-run with some safety
cp --reflink=auto -a "$(dirname "${BASH_SOURCE[0]}")" "${OUTPUT_DIR}/scripts-saved"
cp --reflink=auto "$BENCH_PATH" "${OUTPUT_DIR}/scripts-saved/bench"

tee "${OUTPUT_DIR}/Makefile" <<EOF
OUTPUT_DIR := $(realpath "$OUTPUT_DIR")
BENCH_PATH := $(realpath "$BENCH_PATH")
RUNMIR := $(realpath "$OUTPUT_DIR")/scripts-saved/runmir.sh

.PHONY: all
EOF

# hand over execution to generated script when done
run_make() {
	wait # ensure all runones terminated

	# try to hint glusterfs at doing stuff
	sync

	cd "$OUTPUT_DIR"
	exec make -j "$JOBS"
}
trap run_make exit

__TARGET_I=0
RUNONE_OPTS=(
	PROTOCOL/p/replica-protocol/
	F/f/max-byz-faults/
	N_CLIENTS/c/num-clients/8
	LOAD/l/load/
	COOLDOWN/C/cooldown/60
	BATCH_SIZE/b/replica-batchSize/
	STAT_PERIOD/P/replica-statPeriod/1s
	BURST/B/client-burst/1024
	DURATION/T/client-duration/120
	REQ_SIZE/s/client-reqSize/256
	VERBOSE/v/verbose/false
)
runone() {
(
	opt_parse RUNONE_OPTS "runone" "$@"

	local outdirname=""
	for opt in "${RUNONE_OPTS[@]}"; do
		local optvarname optshort
		optvarname="$(echo "$opt" | cut -d/ -f1)"
		optshort="$(echo "$opt" | cut -d/ -f2)"

		[[ "$optvarname" == "VERBOSE" ]] && continue

		local -n optvar="$optvarname"

		outdirname="${outdirname}${optshort}=${optvar},"
	done

	outdirname="${outdirname%,}" # remove trailing comma

	local target="T_${__TARGET_I}"

tee -a "${OUTPUT_DIR}/Makefile" <<END
${target} := $outdirname

all: \$(${target})

\$(${target}):
	"\$(RUNMIR)" -M "\$(BENCH_PATH)" -o "\$@" -p "$PROTOCOL" -f "$F" -c "$N_CLIENTS" -l "$LOAD" -C "$COOLDOWN" -b "$BATCH_SIZE" -P "$STAT_PERIOD" -B "$BURST" -T "$DURATION" -s "$REQ_SIZE" ${VERBOSE+-v} || echo "FAILED ${target}"

END
) &

	__TARGET_I=$(( __TARGET_I + 1 ))

	[[ $(( __TARGET_I % ($(nproc) * 2) )) -eq 0 ]] && wait || true
}
