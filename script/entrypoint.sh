#!/usr/bin/env bash

TRY_LOOP="20"

: "${REDIS_HOST:="redis"}"
: "${REDIS_PORT:="6379"}"
: "${REDIS_PASSWORD:=""}"

: "${DB_SCHEME:="postgresql"}"
: "${DB_DRIVER:="psycopg2"}"
: "${DB_HOST:="postgres"}"
: "${DB_PORT:="5432"}"
: "${DB_USER:="airflow"}"
: "${DB_PASSWORD:="airflow"}"
: "${DB_NAME:="airflow"}"

if [[ ${POSTGRES_HOST} ]] || [[ ${POSTGRES_PORT} ]] || [[ ${POSTGRES_USER} ]] || [[ ${POSTGRES_PASSWORD} ]] || [[ ${POSTGRES_DB} ]]; then
    echo "[DEPRECATION WARNING]: POSTGRES_* variables will be removed from the image at the release of the next Airflow major version (v2.0). Please use DB_* variables."
fi

: "${POSTGRES_HOST:=${DB_HOST}}"
: "${POSTGRES_PORT:=${DB_PORT}}"
: "${POSTGRES_USER:=${DB_USER}}"
: "${POSTGRES_PASSWORD:=${DB_PASSWORD}}"
: "${POSTGRES_DB:=${DB_NAME}}"

# Defaults and back-compat
: "${AIRFLOW__CORE__FERNET_KEY:=${FERNET_KEY:=$(python -c "from cryptography.fernet import Fernet; FERNET_KEY = Fernet.generate_key().decode(); print(FERNET_KEY)")}}"
: "${AIRFLOW__CORE__EXECUTOR:=${EXECUTOR:-Sequential}Executor}"

export \
  AIRFLOW__CELERY__BROKER_URL \
  AIRFLOW__CELERY__RESULT_BACKEND \
  AIRFLOW__CORE__EXECUTOR \
  AIRFLOW__CORE__FERNET_KEY \
  AIRFLOW__CORE__LOAD_EXAMPLES \
  AIRFLOW__CORE__SQL_ALCHEMY_CONN \


# Load DAGs exemples (default: Yes)
if [[ -z "$AIRFLOW__CORE__LOAD_EXAMPLES" && "${LOAD_EX:=n}" == n ]]
then
  AIRFLOW__CORE__LOAD_EXAMPLES=False
fi

# Install custom python package if requirements.txt is present
if [ -e "/requirements.txt" ]; then
    $(which pip) install --user -r /requirements.txt
fi

if [ -n "$REDIS_PASSWORD" ]; then
    REDIS_PREFIX=:${REDIS_PASSWORD}@
else
    REDIS_PREFIX=
fi

wait_for_port() {
  local name="$1" host="$2" port="$3"
  local j=0
  while ! nc -z "$host" "$port" >/dev/null 2>&1 < /dev/null; do
    j=$((j+1))
    if [ $j -ge $TRY_LOOP ]; then
      echo >&2 "$(date) - $host:$port still not reachable, giving up"
      exit 1
    fi
    echo "$(date) - waiting for $name... $j/$TRY_LOOP"
    sleep 5
  done
}

if [ "$AIRFLOW__CORE__EXECUTOR" != "SequentialExecutor" ]; then
  : "${AIRFLOW__CORE__SQL_ALCHEMY_CONN:="${DB_SCHEME}+${DB_DRIVER}://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}"}"
  if [ "$AIRFLOW__CORE__EXECUTOR" = "CeleryExecutor" ]; then
    : "${AIRFLOW__CELERY__RESULT_BACKEND:="db+${DB_SCHEME}://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}"}"
  fi
  wait_for_port "${DB_SCHEME^}" "$DB_HOST" "$DB_PORT"
fi

if [ "$AIRFLOW__CORE__EXECUTOR" = "CeleryExecutor" ]; then
  AIRFLOW__CELERY__BROKER_URL="redis://$REDIS_PREFIX$REDIS_HOST:$REDIS_PORT/1"
  wait_for_port "Redis" "$REDIS_HOST" "$REDIS_PORT"
fi

case "$1" in
  webserver)
    airflow initdb
    if [ "$AIRFLOW__CORE__EXECUTOR" = "LocalExecutor" ]; then
      # With the "Local" executor it should all run in one container.
      airflow scheduler &
    fi
    exec airflow webserver
    ;;
  worker|scheduler)
    # To give the webserver time to run initdb.
    sleep 10
    exec airflow "$@"
    ;;
  flower)
    sleep 10
    exec airflow "$@"
    ;;
  version)
    exec airflow "$@"
    ;;
  *)
    # The command is something like bash, not an airflow subcommand. Just run it in the right environment.
    exec "$@"
    ;;
esac
