#!/bin/bash

rm -f ${PWD}/conf/database.conf

if [ "$PWE_PROFILE" == "mariadb" ]; then
    ln -s ${PWD}/conf/mariadb.conf ${PWD}/conf/database.conf
elif [ "$PWE_PROFILE" == "mysql" ]; then
    ln -s ${PWD}/conf/mysql.conf ${PWD}/conf/database.conf
elif [ "$PWE_PROFILE" == "postgres" ]; then
    ln -s ${PWD}/conf/postgres.conf ${PWD}/conf/database.conf
fi

exec "$@"