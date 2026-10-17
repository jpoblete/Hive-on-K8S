#!/bin/bash
# Usage Notice: This project is not meant for commercial use without permission and proper credit.
#
# Archive Hive process logs (and optional Tez local paths) to HDFS for llap.
# Used by HiveServer2 and LLAP daemons when HIVE_LOG_HDFS_BASE is set.
#
set -o pipefail

HIVE_HOME="${HIVE_HOME:-/opt/hive}"
HIVE_LOG_DIR="${HIVE_LOG_DIR:-${HIVE_HOME}/log}"
HIVE_LOG_HDFS_BASE="${HIVE_LOG_HDFS_BASE:-}"
HIVE_LOG_HDFS_SYNC_INTERVAL_SEC="${HIVE_LOG_HDFS_SYNC_INTERVAL_SEC:-300}"
SERVICE="${SERVICE:-hive}"
HOST_ID="${HOSTNAME:-unknown}"
LOCK_FILE="/tmp/hdfs-log-sync.lock"

hdfs_dest() {
   printf '%s/%s/%s' "${HIVE_LOG_HDFS_BASE}" "${SERVICE}" "${HOST_ID}"
}

# Paths under HIVE_HOME to include in the tarball (relative to HIVE_HOME).
collect_archive_paths() {
   local paths=()

   if [ -d "${HIVE_LOG_DIR}" ]; then
      paths+=("log")
   fi
   if [ "${SERVICE}" = "hiveserver2" ] && [ -d "${HIVE_HOME}/scratch_dir/hive/_tez_session_dir" ]; then
      paths+=("scratch_dir/hive/_tez_session_dir")
   fi
   if [ "${#paths[@]}" -eq 0 ]; then
      return 1
   fi
   printf '%s\n' "${paths[@]}"
}

do_push() {
   local dest stamp tmp paths=()

   [ -n "${HIVE_LOG_HDFS_BASE}" ] || return 0

   mapfile -t paths < <(collect_archive_paths) || return 0

   dest="$(hdfs_dest)"
   stamp="$(date -u +%Y%m%d-%H%M%S)"
   tmp="/tmp/hive-logs-${HOST_ID}-${stamp}.tgz"

   if ! hdfs dfs -mkdir -p "${dest}"; then
      echo "hdfs-log-sync: failed to create ${dest}" >&2
      return 1
   fi

   if ! tar -C "${HIVE_HOME}" -czf "${tmp}" "${paths[@]}" 2>/dev/null; then
      echo "hdfs-log-sync: tar failed for ${paths[*]}" >&2
      rm -f "${tmp}"
      return 1
   fi

   if ! hdfs dfs -put -f "${tmp}" "${dest}/archive-${stamp}.tgz"; then
      echo "hdfs-log-sync: put failed for ${dest}/archive-${stamp}.tgz" >&2
      rm -f "${tmp}"
      return 1
   fi

   printf '%s\n' "archive-${stamp}.tgz" | hdfs dfs -put -f - "${dest}/LATEST"
   rm -f "${tmp}"
   echo "hdfs-log-sync: pushed ${dest}/archive-${stamp}.tgz"
   return 0
}

run_locked() {
   if command -v flock >/dev/null 2>&1; then
      (
         flock -w 120 200 || exit 1
         "$@"
      ) 200>"${LOCK_FILE}"
   else
      "$@"
   fi
}

push() {
   if [ -z "${HIVE_LOG_HDFS_BASE}" ]; then
      return 0
   fi
   run_locked do_push
}

do_restore() {
   local dest latest tmp

   [ -n "${HIVE_LOG_HDFS_BASE}" ] || return 0

   dest="$(hdfs_dest)"
   if ! hdfs dfs -test -e "${dest}/LATEST"; then
      echo "hdfs-log-sync: no prior archive at ${dest}/LATEST"
      return 0
   fi

   latest="$(hdfs dfs -cat "${dest}/LATEST" 2>/dev/null | tr -d '\r\n')"
   [ -n "${latest}" ] || return 0

   tmp="/tmp/hive-logs-restore-${HOST_ID}.tgz"
   if ! hdfs dfs -get "${dest}/${latest}" "${tmp}"; then
      echo "hdfs-log-sync: get failed for ${dest}/${latest}" >&2
      return 1
   fi

   mkdir -p "${HIVE_LOG_DIR}"
   tar -xzf "${tmp}" -C "${HIVE_HOME}" 2>/dev/null || true
   rm -f "${tmp}"
   echo "hdfs-log-sync: restored ${dest}/${latest} into ${HIVE_HOME}"
   return 0
}

restore() {
   if [ -z "${HIVE_LOG_HDFS_BASE}" ]; then
      return 0
   fi
   run_locked do_restore
}

start_periodic() {
   [ -n "${HIVE_LOG_HDFS_BASE}" ] || exit 0
   echo "hdfs-log-sync: periodic every ${HIVE_LOG_HDFS_SYNC_INTERVAL_SEC}s for ${SERVICE}@${HOST_ID}"
   while true; do
      sleep "${HIVE_LOG_HDFS_SYNC_INTERVAL_SEC}"
      push || true
   done
}

case "${1:-}" in
   push) push ;;
   restore) restore ;;
   start-periodic) start_periodic ;;
   *)
      echo "Usage: $0 push|restore|start-periodic" >&2
      exit 1
      ;;
esac
