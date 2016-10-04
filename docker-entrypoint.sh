#!/bin/bash
set -eu

export SPARK_DIST_CLASSPATH=$(hadoop classpath)
POSTGRES_TIMEOUT=60

if [ "${1:0:1}" = '-' ]; then
	set -- "airflow" "$@"
fi

if [ "$1" = 'airflow' ]; then
    echo "Running as: ${USER}"
    if [ "${USER}" != "root" ]; then
      echo "Changing owner of files in ${AIRFLOW_HOME} to ${USER}"
      chown -R "${USER}" ${AIRFLOW_HOME}
    fi

    set +e
    # Wait for Postgres to be available
    # Strategy from http://superuser.com/a/806331/98716
    DATABASE_DEV="/dev/tcp/${POSTGRES_HOST}/${POSTGRES_PORT}"
    echo "Checking datbase connection ${DATABASE_DEV}"
    timeout ${POSTGRES_TIMEOUT} bash <<EOT
    while ! (echo > "${DATABASE_DEV}") >/dev/null 2>&1; do
        echo "Waiting for database ${DATABASE_DEV}"
        sleep 2;
    done;
EOT
    RESULT=$?

    if [ ${RESULT} -eq 0 ]; then
        echo "Database available"
    else
        echo "Database is not available"
        exit 1
    fi
    set -e

    gosu "${USER}" sed -i "/\(^sql_alchemy_conn = \).*/ s//\1postgresql:\/\/${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}\/${POSTGRES_DB}/" ${AIRFLOW_HOME}/airflow.cfg
    gosu "${USER}" sed -i "/\(^parallelism = \).*/ s//\1${AIRFLOW_PARALLELISM}/" ${AIRFLOW_HOME}/airflow.cfg
    gosu "${USER}" sed -i "/\(^dag_concurrency = \).*/ s//\1${AIRFLOW_DAG_CONCURRENCY}/" ${AIRFLOW_HOME}/airflow.cfg
    gosu "${USER}" sed -i "/\(^max_threads = \).*/ s//\1${AIRFLOW_DAG_CONCURRENCY}/" ${AIRFLOW_HOME}/airflow.cfg
    gosu "${USER}" airflow initdb # https://groups.google.com/forum/#!topic/airbnb_airflow/4ZGWUzKkBbw

    (airflow list_dags | grep '^fn_') | while read fn_dag; do
        echo "Back filling DAG ${fn_dag}"
        gosu "${USER}" airflow backfill -s $(date --date="yesterday-10 days" +%Y-%m-%d) -e $(date --date="yesterday" +%Y-%m-%d) -m ${fn_dag}
    done
    # gosu "${USER}" airflow backfill -s $(date --date="yesterday-10 days" +%Y-%m-%d) -e $(date --date="yesterday" +%Y-%m-%d) -m $(airflow list_dags | tail -n1)

    (while :; do echo 'Starting scheduler'; gosu "${USER}" airflow scheduler -n ${SCHEDULER_RUNS}; sleep 1; done)&
fi

exec gosu "${USER}" "$@"
