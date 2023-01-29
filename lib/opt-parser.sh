# shellcheck shell=bash

[[ "${BASH_SOURCE[0]}" == "$0" ]] && (
    echo "this is meant to be sourced, not be run directly" >&2
    exit 1
)

opt_usage() {
    local -n opts="$1"
    local scriptname="$2"

    echo "Usage: $scriptname"
    for opt in "${opts[@]}"; do
        local optname optshort optlong optdef
        optname="$(echo "$opt" | cut -d/ -f 1)"
        optshort="$(echo "$opt" | cut -d/ -f 2)"
        optlong="$(echo "$opt" | cut -d/ -f 3)"
        optdef="$(echo "$opt" | cut -d/ -f 4-)"

        if [[ -z "$optdef" ]]; then
            echo "           -$optshort | --$optlong $optname" >&2
        else
            echo "         [ -$optshort | --$optlong $optname (default: $optdef) ]" >&2
        fi
    done
}

_opt_lookup() {
    local -n opts="$1"
    local opt="$2"

    for idx in "${!opts[@]}" -1; do
        [[ $idx -eq -1 ]] && break

        local optshort optlong
        optshort="$(echo "${opts[$idx]}" | cut -d/ -f 2)"
        optlong="$(echo "${opts[$idx]}" | cut -d/ -f 3)"

        [[ "$opt" == "-${optshort}" || "$opt" == "--${optlong}" ]] && break
    done

    echo "$idx"
}

_opt_set_defaults() {
    local -n opts="$1"

    for opt in "${opts[@]}"; do
        local optvarname optdef
        optvarname="$(echo "$opt" | cut -d/ -f 1)"
        optdef="$(echo "$opt" | cut -d/ -f 4-)"

        if [[ -z "$optdef" ]]; then
            unset "$optname"
        else
            local -n optvar="$optvarname"
            optvar="$optdef"
        fi
    done
}

_opt_check_defined() {
    local optsname="$1"
    local -n opts="$optsname"
    local scriptname="$2"

    for opt in "${opts[@]}"; do
        local optvarname
        optvarname="$(echo "$opt" | cut -d/ -f 1)"
        local -n optvar="$optvarname"

        if [[ -z "$optvar" ]]; then
            echo "missing ${optvarname}" >&2
            opt_usage "$optsname" "$scriptname"
            exit 1
        fi
    done
}

_opt_parse_args() {
    local -n opts="$1"; shift
    local scriptname="$1"; shift
    local getopt_short getopt_long

    getopt_short="$(echo "${opts[@]}" | tr ' ' '\n' | cut -d/ -f2 | sort | uniq | tr '\n' ':')"
    getopt_long="$(echo "${opts[@]}" | tr ' ' '\n' | cut -d/ -f3 | sort | uniq | sed -E 's/$/:,/' | tr -d '\n')"

    getopt -a -n "$scriptname" -o "$getopt_short" --long "$getopt_long" -- "$@"
}

opt_parse() {
    local optsname="$1"; shift
    local scriptname="$1"; shift
    local parsed_args valid_args

    local -n opts="$optsname"

    parsed_args="$(_opt_parse_args "$optsname" "$scriptname" "$@")"
    valid_args=$?

    [[ $valid_args -ne 0 ]] && opt_usage "$optsname" "$scriptname" && exit 1

    eval set -- "$parsed_args"

    _opt_set_defaults "$optsname"

    while true; do
        local optidx
        optidx=$(_opt_lookup "$optsname" "$1")

        if [[ "$optidx" != "-1" ]]; then
            local optvarname
            optvarname="$(echo "${opts[$optidx]}" | cut -d/ -f1)"

            local -n optvar="$optvarname"
            optvar="$2"
            shift 2
        else
            case "$1" in
                # end of arguments
                --) shift; break ;;
                *)
                    echo "Unexpected option: $1" >&2
                    opt_usage "$optsname" "$scriptname"
                    exit 1
                    ;;
            esac
        fi
    done

    [[ $# -gt 0 ]] && panic "Unexpected options: $*"

    _opt_check_defined "$optsname" "$0"
}
