#!/bin/bash

if [ -h "${PWD}/conf/database.conf" ]; then
    rm -f ${PWD}/conf/database.conf
fi

if [ "$PWE_PROFILE" == "mariadb" ]; then
    ln -s --relative ${PWD}/conf/mariadb.conf ${PWD}/conf/database.conf
elif [ "$PWE_PROFILE" == "mysql" ]; then
    ln -s --relative ${PWD}/conf/mysql.conf ${PWD}/conf/database.conf
elif [ "$PWE_PROFILE" == "postgres" ]; then
    ln -s --relative ${PWD}/conf/postgres.conf ${PWD}/conf/database.conf
fi

exec "$@"