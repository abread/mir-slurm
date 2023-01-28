#!/usr/bin/env bash

set -e

usage() {
    echo "Usage: $0 -p <protocol> [-f <F, default 0>] [-c <number of clients, default 1>]"
    echo "RUNMIR_CLIENT_ARGS is: $RUNMIR_CLIENT_ARGS"
    echo "RUNMIR_SERVER_ARGS is: $RUNMIR_SERVER_ARGS"
    exit 1
}

case "$RUNMIR_CURRENT_OP" in
    salloc)
        [ -n "$RUNMIR_PROTOCOL" ] || (echo "missing variable RUNMIR_PROTOCOL"; exit 1)
        [ -n "$RUNMIR_BATCH_SIZE" ] || (echo "missing variable RUNMIR_BATCH_SIZE"; exit 1)
        [ -n "$RUNMIR_PORT" ] || (echo "missing variable RUNMIR_PORT"; exit 1)
        [ -n "$RUNMIR_F" ] || (echo "missing variable RUNMIR_F"; exit 1)
        [ -n "$RUNMIR_N_CLIENTS" ] || (echo "missing variable RUNMIR_N_CLIENTS"; exit 1)
        [ -n "$SLURM_JOB_NODELIST_HET_GROUP_0" ] || (echo "missing variable SLURM_JOB_NODELIST_HET_GROUP_0"; exit 1)

        # parse slurm nodelist
        server_nodes="$(eval "echo $(echo "$SLURM_JOB_NODELIST_HET_GROUP_0" | sed -E 's|\],|] |g' | sed -E 's|([^0-9])([0-9]+)-([0-9]+)([^0-9])|\1{\2..\3}\4|g' | sed -E 's/\[/{/g' | sed -E 's/\]/}/g')" | tr ' ' '\n' | tr -d '{}')"

        # generate membership list
        i=0
        for hostname in $server_nodes; do
            echo "${i} /dns4/${hostname}/tcp/${RUNMIR_PORT}" >> membership
            i=$(( i + 1 ))
        done

        # run server nodes
        echo "$(date): starting replicas" >&2
        srun --het-group=0 -- ./run-bench-node.sh -b "$RUNMIR_BATCH_SIZE" -p "$RUNMIR_PROTOCOL" -o - --statPeriod 5s -m membership &

        sleep 5 # give them some time to start up

        echo "$(date): starting clients" >&2
        # run client nodes to completion
        srun --het-group=1 -- ./run-bench-client.sh $RUNMIR_CLIENT_ARGS

        echo "$(date): clients done, cooling down" >&2
        # give it some time to cool down
        sleep 120

        exit 0
        ;;
    *)
        export RUNMIR_PORT=4242
        export RUNMIR_F=0
        export RUNMIR_BATCH_SIZE=1024
        export RUNMIR_N_CLIENTS=1
        export RUNMIR_CLIENT_ARGS
        export RUNMIR_PROTOCOL

        while getopts ':p:f:b:c:' OPTION; do
            case "$OPTION" in
                p)
                    RUNMIR_PROTOCOL="$OPTARG"
                    ;;
                f)
                    RUNMIR_F="$OPTARG"
                    ;;
                b)
                    RUNMIR_BATCH_SIZE="$OPTARG"
                    ;;
                c)
                    RUNMIR_N_CLIENTS="$OPTARG"
                    ;;
                ?)
                    usage
                    ;;
            esac
        done

        if [[ -z "$RUNMIR_PROTOCOL" ]] || [[ $RUNMIR_F -lt 0 ]] || [[ $RUNMIR_N_CLIENTS -le 0 ]]; then
            usage
            exit 1
        fi

        slurm_server_nodes=$(( 3 * RUNMIR_F + 1 ))
        slurm_client_tasks=$RUNMIR_N_CLIENTS

        export RUNMIR_CURRENT_OP=salloc
        exec salloc -x 'lab1p[1-12],lab2p[1-20],lab3p[1-10],lab4p[1-10],lab6p[1-9],lab7p[1-9]' -N $slurm_server_nodes --cpus-per-task=4 --ntasks-per-node=1 --exclusive -t 6 : \
               -x 'lab1p[1-12],lab2p[1-20],lab3p[1-10],lab5p[1-20],lab6p[1-9],lab7p[1-9]' -n "$slurm_client_tasks" --cpus-per-task=1 --ntasks-per-node=4 --exclusive -t 6  -- "$0"
        ;;
esac
