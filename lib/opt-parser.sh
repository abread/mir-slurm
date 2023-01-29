# shellcheck shell=bash

_opt_usage() {
    echo "Usage: $1"
    for opt in ${OPTS[@]}; do
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
    local opt="$1"

    for idx in "${!OPTS[@]}" -1; do
        [[ $idx -eq -1 ]] && break

        local optshort optlong
        optshort="$(echo "${OPTS[$idx]}" | cut -d/ -f 2)"
        optlong="$(echo "${OPTS[$idx]}" | cut -d/ -f 3)"

        ( [[ "$opt" == "-${optshort}" ]] || [[ "$opt" == "--${optlong}" ]] ) && break
    done

    echo $idx
}

_opt_set_defaults() {
    for opt in "${OPTS[@]}"; do
        local optname optdef
        optname="$(echo "$opt" | cut -d/ -f 1)"
        optdef="$(echo "$opt" | cut -d/ -f 4-)"

        if [[ ! -z "$optdef" ]]; then
            eval "${optname}=\"\$optdef\""
        fi
    done
}

_opt_check_defined() {
    local scriptname="$1"

    for opt in "${OPTS[@]}"; do
        local optname
        optname="$(echo "$opt" | cut -d/ -f 1)"

        if [[ -z "$(eval "echo \"\$${optname}\"")" ]]; then
            echo "missing ${optname}" >&2
            _opt_usage "$scriptname"
            exit 1
        fi
    done
}

_opt_parse() {
    local scriptname getopt_short getopt_long

    scriptname="$1"; shift
    getopt_short="$(echo "${OPTS[@]}" | tr ' ' '\n' | cut -d/ -f2 | sort | uniq | tr '\n' ':')"
    getopt_long="$(echo "${OPTS[@]}" | tr ' ' '\n' | cut -d/ -f3 | sort | uniq | sed -E 's/$/:,/' | tr -d '\n')"

    getopt -a -n "$scriptname" -o "$getopt_short" --long "$getopt_long" -- "$@"
}

_parsed_args="$(_opt_parse "$0" "$@")"
_valid_args=$?

[[ $_valid_args -ne 0 ]] && _opt_usage "$0" && exit 1

_opt_set_defaults

eval set -- "$_parsed_args"
while true; do
    _optidx=$(_opt_lookup "$1")
    if [[ "$_optidx" != "-1" ]]; then
        _optvar="$(echo "${OPTS[$_optidx]}" | cut -d/ -f1)"
        eval "${_optvar}=\"\$2\""
        shift 2
    else
        case "$1" in
            # end of arguments
            --) shift; break ;;
            *)
                echo "Unexpected option: $1" >&2
                _opt_usage "$0"
                exit 1
                ;;
        esac
    fi
done

_opt_check_defined "$0"

unset _opt_usage _opt_lookup _opt_set_defaults _opt_check_defined _opt_parse
unset _parsed_args _valid_args
unset _optidx _optvar
