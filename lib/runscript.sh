# shellcheck shell=bash
set -e

[[ "${BASH_SOURCE[0]}" == "$0" ]] && (
	echo "this is meant to be sourced at the start of your runscript, not be run directly" >&2
	exit 1
)

source "$(dirname "${BASH_SOURCE[0]}")/opt-parser.sh"

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
	# try to hint glusterfs at doing stuff
	sync

	cd "$OUTPUT_DIR"
	exec make -j "$JOBS"
}
trap run_make exit

__TARGET_I=0
runone() {
	local outdirname=""
	local orig_args=("$@")

	while [[ $# -gt 0 ]]; do
		local key="$1"
		shift

		[[ "$key" =~ ^-[a-zA-Z-]+$ ]] || (echo "bad flag $key" >&2; return 1)
		[[ "$key" == "-v" ]] && continue
		[[ "$key" == "--verbose" ]] && continue
		[[ "$key" == "-V" ]] && continue
		[[ "$key" == "--client-verbose" ]] && continue

		key="${key#-}"

		local value="$1"
		shift

		outdirname="${outdirname}${key}=${value},"
	done

	outdirname="${outdirname%,}" # remove trailing comma

	local target="T_${__TARGET_I}"

tee -a "${OUTPUT_DIR}/Makefile" <<END
${target} := $outdirname

all: \$(${target})

\$(${target}):
	"\$(RUNMIR)" -M "\$(BENCH_PATH)" -o "\$@" ${orig_args[@]@Q} || echo "FAILED ${target}"

END

	__TARGET_I=$(( __TARGET_I + 1 ))
}
