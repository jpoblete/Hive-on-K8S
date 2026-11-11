#!/bin/bash
# Usage Notice: This project is not meant for commercial use without permission and proper credit.
# Author: j.martinez.poblete@gmail.com
#
# Cassandra counterpart of base/createTable.sh: creates a table with columns
# c1 int, c2 text, ..., cN text and loads fake rows in the same style.
#
# Cassandra needs a primary key, so c1 (int) is the partition key. Each generated
# row uses its row number as c1 and 15-char random strings for c2..cN, matching
# createTable.sh's genData().
#
# Run inside a cassandra pod (uses cql.sh, which uses the entrypoint kinit ticket):
#   createCassandraTable.sh keyspace table_name cols_number rows partitions
#
#   keyspace    : existing keyspace, or created with replication from KS_RF (default 3)
#   table_name  : table name, for example dummy_3
#   cols_number : number of columns, minimum 2
#   rows        : rows per INSERT batch, minimum 1
#   partitions  : number of INSERT batches, minimum 1
#
# Example: createCassandraTable.sh demo dummy_3 3 1 10

set -o pipefail

KEYSPACE="${1:-}"
TBL_NAME="${2:-}"
TBL_COLS="${3:-2}"
ROW_PART="${4:-10}"
ITERATIONS="${5:-10}"
KS_RF="${KS_RF:-3}"
CQL_SH="${CQL_SH:-cql.sh}"
TIMESTAMP=$(date "+%s")
CQL_FILE="/tmp/createCassandraTable.${TIMESTAMP}.cql"

# Print command usage and describe each positional argument.
usage() {
   echo "createCassandraTable.sh keyspace table_name cols_number rows partitions"
   echo "Set CREATE_TABLE_VERBOSE=1 to print generated CQL before it runs."
   echo "keyspace    : keyspace name (created if missing, RF from KS_RF, default 3)"
   echo "table_name  : table name, for example dummy_3"
   echo "cols_number : number of columns, minimum 2"
   echo "rows        : rows per INSERT batch, minimum 1"
   echo "partitions  : number of INSERT batches, minimum 1"
}

# Print an error message, show usage, and stop the script.
die() {
   echo "ERROR: $*" >&2
   usage >&2
   exit 1
}

# Return success when the provided value is an unsigned integer.
is_uint() {
   [[ "$1" =~ ^[0-9]+$ ]]
}

# Validate a CQL identifier (unquoted: letters, digits, underscore, starting with a letter).
validate_identifier() {
   [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

# Validate user input before generating CQL.
validate_args() {
   [ -n "${KEYSPACE}" ] || die "keyspace needs to be specified"
   [ -n "${TBL_NAME}" ] || die "table_name needs to be specified"
   validate_identifier "${KEYSPACE}" || die "invalid keyspace: ${KEYSPACE}"
   validate_identifier "${TBL_NAME}" || die "invalid table_name: ${TBL_NAME}"
   is_uint "${KS_RF}"       || die "KS_RF must be a positive integer"
   is_uint "${TBL_COLS}"    || die "cols_number must be a positive integer"
   is_uint "${ROW_PART}"    || die "rows must be a positive integer"
   is_uint "${ITERATIONS}"  || die "partitions must be a positive integer"
   [ "${TBL_COLS}" -ge 2 ]    || die "cols_number=${TBL_COLS}, cannot be less than 2"
   [ "${ROW_PART}" -ge 1 ]    || die "rows=${ROW_PART}, cannot be less than 1"
   [ "${ITERATIONS}" -ge 1 ]  || die "partitions=${ITERATIONS}, cannot be less than 1"
}

# Join all remaining arguments using the first argument as separator.
join_by() {
   local sep="$1"
   shift

   local out=""
   local item

   for item in "$@"; do
      if [ -z "${out}" ]; then
         out="${item}"
      else
         out="${out}${sep}${item}"
      fi
   done

   printf "%s" "${out}"
}

# Generate a random alphanumeric string of the requested length.
genRandomStr() {
   local len="$1"
   local s=""
   local chars="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

   while (( ${#s} < len )); do
      s+="${chars:RANDOM%62:1}"
   done

   printf "%s" "${s}"
}

# CREATE KEYSPACE if it does not exist. Replication is SimpleStrategy with KS_RF.
createKeyspace() {
   printf "CREATE KEYSPACE IF NOT EXISTS %s WITH replication = {'class': 'SimpleStrategy', 'replication_factor': %s};\n" \
      "${KEYSPACE}" "${KS_RF}"
}

# Drop the table so CREATE is not a silent no-op on an old schema (matches createTable.sh dropTbl).
dropTbl() {
   printf "DROP TABLE IF EXISTS %s.%s;\n" "${KEYSPACE}" "${TBL_NAME}"
}

# CREATE TABLE: c1 int (partition key), c2 uuid, c3..cN text.
createTbl() {
   local columns=("c1 int" "c2 uuid")
   local i

   for ((i=3; i<=TBL_COLS; i++)); do
      columns+=("c${i} text")
   done

   printf "CREATE TABLE IF NOT EXISTS %s.%s ( %s, PRIMARY KEY (c1) );\n" \
      "${KEYSPACE}" "${TBL_NAME}" "$(join_by ", " "${columns[@]}")"
}

# Generate a UUID for the c2 uuid column. Uses uuidgen if present, else the kernel's generator.
genUuid() {
   if command -v uuidgen >/dev/null 2>&1; then
      uuidgen
   else
      cat /proc/sys/kernel/random/uuid
   fi
}

# One INSERT per batch. Each row: c1 = row number, c2 = a fresh UUID,
# c3..cN = a fresh random string per column, so every column gets its own value.
genData() {
   local cols=()
   local vals
   local i
   local r

   for ((i=1; i<=TBL_COLS; i++)); do
      cols+=("c${i}")
   done

   for ((r=1; r<=ROW_PART; r++)); do
      vals=("${r}" "$(genUuid)")
      for ((i=3; i<=TBL_COLS; i++)); do
         vals+=("'$(genRandomStr 15)'")
      done
      printf "INSERT INTO %s.%s ( %s ) VALUES ( %s );\n" \
         "${KEYSPACE}" "${TBL_NAME}" \
         "$(join_by ", " "${cols[@]}")" \
         "$(join_by ", " "${vals[@]}")"
   done
}

# Main: keyspace, drop, create, then the insert batches.
main() {
   local i

   createKeyspace
   dropTbl
   createTbl

   for ((i=1; i<=ITERATIONS; i++)); do
      genData
   done
}

validate_args
main > "${CQL_FILE}" || exit 1

if [ "${CREATE_TABLE_VERBOSE:-0}" = "1" ]; then
   cat "${CQL_FILE}"
fi

# cql.sh -f runs each ';'-separated statement via cql-krb.py.
if "${CQL_SH}" -f "${CQL_FILE}"; then
   echo "createCassandraTable: OK (${KEYSPACE}.${TBL_NAME})"
   exit 0
fi

echo "createCassandraTable: FAILED (${KEYSPACE}.${TBL_NAME}), CQL kept at ${CQL_FILE}" >&2
exit 1
