#!/bin/bash
#
# Script to create a Hive table with fake data.
#

set -o pipefail

TYPES="ice_orc, ice_prq, orc, prq, txt, man"

TIMESTAMP=$(date "+%s")
TBL_TYPE="${1:-}"
TBL_NAME="${2:-}"
TBL_COLS="${3:-2}"
PRT_COUNT="${4:-0}"
ROW_PART="${5:-10}"
ITERATIONS="${6:-10}"
HQL_FILE="/tmp/createTable.${TIMESTAMP}.hql"
BEELINE_URL="${BEELINE_URL:-jdbc:hive2://$(hostname -f):10000/default}"
BEELINE_USER="${BEELINE_USER:-hive}"
BEELINE_PASSWORD="${BEELINE_PASSWORD:-}"

# Print command usage and describe each positional argument.
usage() {
   echo "createTable.sh table_type table_name cols_number part_number rows partitions"
   echo "table_type  : ${TYPES}"
   echo "table_name  : Hive table name, for example dummy_3_1 or db.dummy_3_1"
   echo "cols_number : number of columns, minimum 2"
   echo "part_number : number of nested partitions, minimum 0"
   echo "rows        : rows per partition/batch, minimum 1"
   echo "partitions  : number of insert batches/partitions, minimum 1"
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

# Validate a Hive table identifier.
# Allows table_name or database.table_name format.
validate_identifier() {
   [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)?$ ]]
}

# Join all remaining arguments using the first argument as separator.
# Used to build comma-separated SQL column/value lists safely.
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

# Validate user input before generating SQL.
# Checks table type, table name format, and numeric argument ranges.
validate_args() {
   [ -n "${TBL_TYPE}" ] || die "table_type needs to be one of: ${TYPES}"
   [ -n "${TBL_NAME}" ] || die "table_name needs to be specified"

   case "${TBL_TYPE}" in
      ice_orc|ice_prq|orc|prq|txt|man) ;;
      *) die "table_type '${TBL_TYPE}' needs to be one of: ${TYPES}" ;;
   esac

   validate_identifier "${TBL_NAME}" || die "invalid table_name: ${TBL_NAME}"

   is_uint "${TBL_COLS}"    || die "cols_number must be a positive integer"
   is_uint "${PRT_COUNT}"   || die "part_number must be a non-negative integer"
   is_uint "${ROW_PART}"    || die "rows must be a positive integer"
   is_uint "${ITERATIONS}"  || die "partitions must be a positive integer"

   [ "${TBL_COLS}" -ge 2 ]    || die "cols_number=${TBL_COLS}, cannot be less than 2"
   [ "${ROW_PART}" -ge 1 ]    || die "rows=${ROW_PART}, cannot be less than 1"
   [ "${ITERATIONS}" -ge 1 ]  || die "partitions=${ITERATIONS}, cannot be less than 1"
}

# Generate a CREATE DATABASE statement when TBL_NAME uses database.table format.
# Example: if TBL_NAME="sales.orders", this emits:
# CREATE DATABASE IF NOT EXISTS sales;
# If TBL_NAME has no database prefix, nothing is emitted.
createDatabase() {
   local db_name=""
   case "${TBL_NAME}" in
      *.*)
         db_name="${TBL_NAME%%.*}"
         printf "CREATE DATABASE IF NOT EXISTS %s;\n" "${db_name}"
         ;;
      *)
         return 0
         ;;
   esac
}

# Generate the CREATE TABLE statement.
# Chooses external/managed table behavior and storage format from TBL_TYPE.
createTbl() {
   local create_prefix="CREATE"
   local storage_clause=""
   local columns=()
   local partitions=()
   local i

   case "${TBL_TYPE}" in
      ice_orc)
         create_prefix="CREATE EXTERNAL"
         storage_clause="STORED BY ICEBERG STORED AS ORC"
         ;;
      ice_prq)
         create_prefix="CREATE EXTERNAL"
         storage_clause="STORED BY ICEBERG STORED AS PARQUET"
         ;;
      orc)
         create_prefix="CREATE EXTERNAL"
         storage_clause="STORED AS ORC"
         ;;
      prq)
         create_prefix="CREATE EXTERNAL"
         storage_clause="STORED AS PARQUET"
         ;;
      txt)
         create_prefix="CREATE EXTERNAL"
         storage_clause="STORED AS TEXTFILE"
         ;;
      man)
         create_prefix="CREATE"
         storage_clause="STORED AS ORC"
         ;;
   esac

   columns+=("c1 int")
   for ((i=2; i<=TBL_COLS; i++)); do
      columns+=("c${i} string")
   done

   printf "%s TABLE IF NOT EXISTS %s ( %s )" \
      "${create_prefix}" \
      "${TBL_NAME}" \
      "$(join_by ", " "${columns[@]}")"

   if [ "${PRT_COUNT}" -gt 0 ]; then
      for ((i=1; i<=PRT_COUNT; i++)); do
         partitions+=("p${i} int")
      done

      printf " PARTITIONED BY ( %s )" "$(join_by ", " "${partitions[@]}")"
   fi

   printf " CLUSTERED BY (c1) SORTED BY (c1 ASC) INTO 128 BUCKETS"

   if [ -n "${storage_clause}" ]; then
      printf " %s" "${storage_clause}"
   fi

   printf ";\n"
}

# Generate a random alphanumeric string of the requested length.
# Used as fake string data for generated table rows.
genRandomStr() {
   local len="$1"
   local s=""
   local chars="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

   while (( ${#s} < len )); do
      s+="${chars:RANDOM%62:1}"
   done

   printf "%s" "${s}"
}

# Generate one INSERT statement with fake row data.
# When partitioning is enabled, all rows in this batch share one partition tuple.
genData() {
   local insert_cols=()
   local partition_values=()
   local rows=()
   local vals=()
   local data
   local i
   local r

   for ((i=1; i<=TBL_COLS; i++)); do
      insert_cols+=("c${i}")
   done

   if [ "${PRT_COUNT}" -gt 0 ]; then
      for ((i=1; i<=PRT_COUNT; i++)); do
         insert_cols+=("p${i}")
         partition_values+=("${RANDOM}")
      done
   fi

   for ((r=1; r<=ROW_PART; r++)); do
      data=$(genRandomStr 15)
      vals=("${r}")

      for ((i=2; i<=TBL_COLS; i++)); do
         vals+=("'${data}'")
      done

      if [ "${PRT_COUNT}" -gt 0 ]; then
         for ((i=0; i<PRT_COUNT; i++)); do
            vals+=("${partition_values[$i]}")
         done
      fi

      rows+=("($(join_by ", " "${vals[@]}"))")
   done

   printf "INSERT INTO %s ( %s ) VALUES %s;\n" \
      "${TBL_NAME}" \
      "$(join_by ", " "${insert_cols[@]}")" \
      "$(join_by ", " "${rows[@]}")"
}

# Main execution flow.
# Validates arguments, creates the table statement, then generates insert batches.
main() {
   local i

   validate_args
   createDatabase
   createTbl

   for ((i=1; i<=ITERATIONS; i++)); do
      genData
   done
}

main | tee "${HQL_FILE}"
beeline -u "${BEELINE_URL}" -n "${BEELINE_USER}" -p "${BEELINE_PASSWORD}" -f "${HQL_FILE}"
