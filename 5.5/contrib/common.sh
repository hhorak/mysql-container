#!/bin/bash

# Data directory where MySQL database files live. The data subdirectory is here
# because .bashrc and my.cnf both live in /var/lib/mysql/ and we don't want a
# volume to override it.
export MYSQL_DATADIR=/var/lib/mysql/data

# Configuration settings.
export MYSQL_DEFAULTS_FILE=$HOME/my.cnf
export MYSQL_LOWER_CASE_TABLE_NAMES=${MYSQL_LOWER_CASE_TABLE_NAMES:-0}
export MYSQL_MAX_CONNECTIONS=${MYSQL_MAX_CONNECTIONS:-151}
export MYSQL_FT_MIN_WORD_LEN=${MYSQL_FT_MIN_WORD_LEN:-4}
export MYSQL_FT_MAX_WORD_LEN=${MYSQL_FT_MAX_WORD_LEN:-20}
export MYSQL_AIO=${MYSQL_AIO:-1}

# Be paranoid and stricter than we should be.
# https://dev.mysql.com/doc/refman/5.5/en/identifiers.html
mysql_identifier_regex='^[a-zA-Z0-9_]+$'
mysql_password_regex='^[a-zA-Z0-9_~!@#$%^&*()-=<>,.?;:|]+$'

function usage() {
  [ $# == 2 ] && echo "error: $1"
  echo "You must specify following environment variables:"
  echo "  MYSQL_USER (regex: '$mysql_identifier_regex')"
  echo "  MYSQL_PASSWORD (regex: '$mysql_password_regex')"
  echo "  MYSQL_DATABASE (regex: '$mysql_identifier_regex')"
  echo "Optional:"
  echo "  MYSQL_ROOT_PASSWORD (regex: '$mysql_password_regex')"
  echo "Settings:"
  echo "  MYSQL_LOWER_CASE_TABLE_NAMES (default: 0)"
  echo "  MYSQL_MAX_CONNECTIONS (default: 151)"
  echo "  MYSQL_FT_MIN_WORD_LEN (default: 4)"
  echo "  MYSQL_FT_MAX_WORD_LEN (default: 20)"
  echo "  MYSQL_AIO (default: 1)"
  exit 1
}

function validate_variables() {
  if ! [[ -v MYSQL_USER && -v MYSQL_PASSWORD && -v MYSQL_DATABASE ]]; then
    usage
  fi

  [[ "$MYSQL_USER"     =~ $mysql_identifier_regex ]] || usage "Invalid MySQL username"
  [ ${#MYSQL_USER} -le 16 ] || usage "MySQL username too long (maximum 16 characters)"
  [[ "$MYSQL_PASSWORD" =~ $mysql_password_regex   ]] || usage "Invalid password"
  [[ "$MYSQL_DATABASE" =~ $mysql_identifier_regex ]] || usage "Invalid database name"
  [ ${#MYSQL_DATABASE} -le 64 ] || usage "Database name too long (maximum 64 characters)"
  if [ -v MYSQL_ROOT_PASSWORD ]; then
    [[ "$MYSQL_ROOT_PASSWORD" =~ $mysql_password_regex ]] || usage "Invalid root password"
  fi
}

# Make sure env variables don't propagate to mysqld process.
function unset_env_vars() {
  unset MYSQL_USER MYSQL_PASSWORD MYSQL_DATABASE MYSQL_ROOT_PASSWORD
}

# Poll until MySQL responds to our ping.
function wait_for_mysql() {
  pid=$1 ; shift

  while [ true ]; do
    if [ -d "/proc/$pid" ]; then
      mysqladmin --socket=/tmp/mysql.sock ping &>/dev/null && return 0
    else
      return 1
    fi
    echo "Waiting for MySQL to start ..."
    sleep 1
  done
}

function start_local_mysql() {
  # Now start mysqld and add appropriate users.
  echo 'Starting local mysqld server ...'
  /opt/rh/mysql55/root/usr/libexec/mysqld \
    --defaults-file=$MYSQL_DEFAULTS_FILE \
    --skip-networking --socket=/tmp/mysql.sock "$@" &
  mysql_pid=$!
  wait_for_mysql $mysql_pid
}

# Initialize the MySQL database (create user accounts and the initial database)
function initialize_database() {
  echo 'Running mysql_install_db ...'
  mysql_install_db --datadir=$MYSQL_DATADIR
  start_local_mysql "$@"

  mysqladmin $admin_flags -f drop test
  mysqladmin $admin_flags create "${MYSQL_DATABASE}"

  [ -v MYSQL_RUNNING_AS_SLAVE ] && return

  # Save master status into a separate database.
  STATUS_INFO=$(mysql $admin_flags -e 'SHOW MASTER STATUS\G')
  BINLOG_POSITION=$(echo "$STATUS_INFO" | grep 'Position:' | head -n 1 | sed -e 's/^\s*Position: //')
  BINLOG_FILE=$(echo "$STATUS_INFO" | grep 'File:' | head -n 1 | sed -e 's/^\s*File: //')

  mysqladmin $admin_flags create replication
mysql $admin_flags <<EOSQL
  use replication
  CREATE TABLE replication (File VARCHAR(1024), Position VARCHAR(256));
  INSERT INTO replication (File, Position) VALUES ('$BINLOG_FILE', '$BINLOG_POSITION');
EOSQL

mysql $mysql_flags <<EOSQL
    CREATE USER '${MYSQL_USER}'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';
    GRANT ALL ON \`${MYSQL_DATABASE}\`.* TO '${MYSQL_USER}'@'%' ;
    FLUSH PRIVILEGES ;
EOSQL

  if [ -v MYSQL_ROOT_PASSWORD ]; then
mysql $mysql_flags <<EOSQL
    GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
EOSQL
  fi
}

# The 'server_id' number for slave needs to be within 1-4294967295 range.
# This function will take the 'hostname' if the container, hash it and turn it
# into the number.
# See: https://dev.mysql.com/doc/refman/5.5/en/replication-options.html#option_mysqld_server-id
function server_id() {
  checksum=$(sha256sum <<< $(hostname -i))
  checksum=${checksum:0:14}
  echo -n $((0x${checksum}%4294967295))
}

function wait_for_mysql_master() {
  while true; do
    echo "Waiting for MySQL master (${MYSQL_MASTER_SERVICE_NAME}) to accept connections ..."
    mysqladmin --host=${MYSQL_MASTER_SERVICE_NAME} --user="${MYSQL_MASTER_USER}" \
      --password="${MYSQL_MASTER_PASSWORD}" ping &>/dev/null && return 0
    sleep 1
  done
}

function validate_replication_variables() {
  if ! [[ -v MYSQL_DATABASE && -v MYSQL_MASTER_USER && -v MYSQL_MASTER_PASSWORD && \
        ( "${MYSQL_RUNNING_AS_SLAVE:-0}" != "1" || -v MYSQL_MASTER_SERVICE_NAME ) ]]; then
    echo
    echo "For master/slave replication, you have to specify following environment variables:"
    echo "  MYSQL_MASTER_SERVICE_NAME (slave only)"
    echo "  MYSQL_DATABASE"
    echo "  MYSQL_MASTER_USER"
    echo "  MYSQL_MASTER_PASSWORD"
    echo
  fi
  [[ "$MYSQL_DATABASE" =~ $mysql_identifier_regex ]] || usage "Invalid database name"
  [[ "$MYSQL_MASTER_USER"     =~ $mysql_identifier_regex ]] || usage "Invalid MySQL master username"
  [ ${#MYSQL_MASTER_USER} -le 16 ] || usage "MySQL master username too long (maximum 16 characters)"
  [[ "$MYSQL_MASTER_PASSWORD" =~ $mysql_password_regex   ]] || usage "Invalid MySQL master password"
}
