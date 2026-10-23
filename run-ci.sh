#!/bin/bash

set -e -x -o pipefail

DC="${DC:-dmd}"
DUB_ARGS="--build-mode=${DUB_BUILD_MODE:-separate} ${DUB_ARGS:-}"
: ${PARTS:=unittests,mongo}

if [[ $PARTS =~ (^|,)unittests(,|$) ]]; then
    dub test --compiler=$DC $DUB_ARGS
    dub clean --all-packages
fi

if [[ $PARTS =~ (^|,)mongo(,|$) ]]; then
    mongod --version

    # Servers up to 5.0 ship the legacy shell, 6.0 and later ship mongosh.
    if command -v mongo &>/dev/null; then
        export MONGO=mongo
    elif command -v mongosh &>/dev/null; then
        export MONGO=mongosh
    else
        echo "Neither mongo nor mongosh is installed to send client commands"
        exit 1
    fi

    for ex in $(\ls -1 tests); do
        if [ -r tests/$ex/run.sh ]; then
            # The test drives its own server, usually because it needs unusual
            # startup options (auth modes, replica sets, a load balancer).
            echo "[INFO] Running mongo test $ex"
            (cd tests/$ex && DUB_INVOKE="dub --compiler=$DC $DUB_ARGS" ./run.sh)
        elif [ -r tests/$ex/dub.json ] || [ -r tests/$ex/dub.sdl ]; then
            # Plain test: start a server here so every test does not repeat it.
            # --fork waits until the database is ready to serve queries.
            MONGOPORT=22824
            rm -f tests/log.txt
            rm -rf tests/$ex/db
            mkdir -p tests/$ex/db
            MONGOPID=$(mongod --logpath tests/log.txt --bind_ip 127.0.0.1 \
                --port $MONGOPORT --dbpath tests/$ex/db --fork \
                | grep -Po 'forked process: \K\d+')

            echo "[INFO] Running mongo test $ex"
            (cd tests/$ex && dub --compiler=$DC $DUB_ARGS -- $MONGOPORT \
                && dub clean && mongodump --port=$MONGOPORT)

            kill $MONGOPID
            while kill -0 $MONGOPID &>/dev/null; do sleep 1; done
        fi
    done
fi
