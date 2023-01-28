# shellcheck shell=bash
set -e # fail on errors

[[ "${BASH_SOURCE[0]}" == "$0" ]] && (
    echo "this is meant to be sourced at the start of your runscript, not be run directly" >&2
    exit 1
)

_runscript_usage() {
    echo "Usage: $0 [ -o | --output-dir <path to non-existing directory> ]
                   [ -b | --bench-path <path to bench executable> ]" >&2
    echo >&2
    echo "Default output dir: $OUTPUT_DIR" >&2
    echo "Default bench path: $BENCH_PATH" >&2

    exit 2
}

_runscript_main() {
    OUTPUT_DIR="mirbench_$(basename "$0")_$(date +"%F_%R:%S")"
    BENCH_PATH="$(dirname "$0")/../mir/bin/bench"

    # parse arguments
    local parsed_args valid_args
    parsed_args="$(getopt -a -n "$0" -o ho:b: --long help,output-dir:,bench-path: -- "$@")"
    valid_args=$?

    [[ $valid_args -ne 0 ]] && _runscript_usage

    eval set -- "$parsed_args"
    while true; do
        case "$1" in
            -h | --help)
                _runscript_usage
                ;;
            -o | --output-dir)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            -b | --bench-path)
                BENCH_PATH="$2"
                shift 2
                ;;
            --) # end of arguments
                shift
                break
                ;;
            *)
                echo "Unexpected option: $1" >&2
                _runscript_usage
                ;;
        esac
    done

    [[ -e "$OUTPUT_DIR" ]] && (
        echo "Output directory already exists: ${OUTPUT_DIR}" >&2
        echo "Specify a different one with -o / --output-dir" >&2
        echo >&2
        _runscript_usage
    )

    [[ -x "$BENCH_PATH" ]] || (
        echo "Mir bench executable does not exist at ${BENCH_PATH}" >&2
        echo "Specify it with -b / --bench-path" >&2
        echo >&2
        _runscript_usage
    )

    echo "Output will be saved in ${OUTPUT_DIR}"
    echo "Mir bench to be used is ${BENCH_PATH}"

    # prepare output directory
    mkdir "$OUTPUT_DIR"

    # preserve all used scripts for reproducibility
    # and to allow changing scripts mid-run with some safety
    cp --reflink=auto -a "$(dirname "${BASH_SOURCE[0]}")" "${OUTPUT_DIR}/scripts-saved"
    cp --reflink=auto "$BENCH_PATH" "${OUTPUT_DIR}/scripts-saved/bench"

    # preserve run script
    cp --reflink=auto "$0" "${OUTPUT_DIR}/scripts-saved/_run.sh"
    sed -i -E "s|^(\\s*)source (.*/)?runscript.sh(['\"\\s]*)$|source ./runscript.sh|" "${OUTPUT_DIR}/scripts-saved/_run.sh"

    # hand over execution to preserved scripts
    OUTPUT_DIR="$(realpath "$OUTPUT_DIR")"
    cd "${OUTPUT_DIR}/scripts-saved"

    chmod +x _run.sh
    export OUTPUT_DIR
    exec ./_run.sh
}

_runscript_run_ok() {
    local outfile="$1"
    local errfile="$2"

    [[ -f "$outfile" ]] && \
    [[ -f "$errfile" ]] && \
    [[ $(wc -l < "$outfile") -gt 40 ]] && \
    [[ $(wc -l < "$errfile") -gt 10 ]] && \
    (! grep "Usage:" "$errfile" >/dev/null) && \
    (! grep "Requested" "$errfile" >/dev/null)
}

runone() {
    local p=$1
    local f=$2
    local l=$3
    local n_cli=$4
    local b=$5
    local burst=$6

    r="$(( l / n_cli ))"

    local out_name="${p}_f${f}_l${l}_b${b}_ncli${n_cli}_burst${burst}_120s"
    export RUNMIR_CLIENT_ARGS="-T 120s -b $burst -r $r -s 256"

    echo "RUNNING: runone $*"
    echo "./runmir.sh -p $p -c $n_cli -b $b -f $f with client args: ${RUNMIR_CLIENT_ARGS} -> $out_name"

    local outfile="${OUTPUT_DIR}/${out_name}.csv"
    local errfile="${OUTPUT_DIR}/${out_name}.err"

    local attempt=0
    while (! ./runmir.sh -p "$p" -c "$n_cli" -b "$b" -f "$f" > "$outfile" 2> "$errfile") || (! _runscript_run_ok "$outfile" "$errfile"); do
        if [[ $attempt -gt 5 ]]; then
            echo "RUNMIR_CLIENT_ARGS=\"${RUNMIR_CLIENT_ARGS}\" ./runmir-saved.sh -p $p -c $n_cli -b $b -f $f > \"./${out_name}.csv\" 2> \"./${out_name}.err\"" >> "${OUTPUT_DIR}/scripts-saved/_retry_failed.sh"
            echo "FAILED: runone $*" >&2
        fi

        sleep 30
        echo "RETRYING: runone $*" >&2
        mv "$outfile"{,.bak}
        mv "$errfile"{,.bak}

        attempt=$((attempt + 1))
    done
}

if [[ -z "$OUTPUT_DIR" ]] && [[ "$(pwd)" != "${OUTPUT_DIR}/scripts-saved" ]]; then
    # first run: we'll copy things over, then execute
    _runscript_main "$@"
    exit 0
else
    # we're executing stuff

    # kill all child processes when exiting
    trap 'trap - SIGINT SIGTERM && kill -- -$$' SIGINT SIGTERM EXIT
fi
