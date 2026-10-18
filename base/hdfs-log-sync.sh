#!/bin/bash
# Usage Notice: This project is not meant for commercial use without permission and proper credit.
# Author: j.martinez.poblete@gmail.com
#
# Archive Hive process logs (and optional Tez local paths) to HDFS for llap.
# Used by HiveServer2 and LLAP daemons when HIVE_LOG_HDFS_BASE is set.
#
set -o pipefail

HIVE_HOME="${HIVE_HOME:-/opt/hive}"
HIVE_LOG_DIR="${HIVE_LOG_DIR:-${HIVE_HOME}/log}"
HIVE_LOG_HDFS_BASE="${HIVE_LOG_HDFS_BASE:-}"
HIVE_LOG_HDFS_SYNC_INTERVAL_SEC="${HIVE_LOG_HDFS_SYNC_INTERVAL_SEC:-300}"
HIVE_LOG_HDFS_HISTORY_MAX="${HIVE_LOG_HDFS_HISTORY_MAX:-10}"
HIVE_LOG_SCRATCH_STRINGS_MAX="${HIVE_LOG_SCRATCH_STRINGS_MAX:-32768}"
# Include INFO/WARN lines scoped to each application in tez/ and llap/ exports (1=yes, 0=no).
HIVE_LOG_EXPORT_INFO_WARN="${HIVE_LOG_EXPORT_INFO_WARN:-1}"
HIVE_TEZ_SCRATCH_HDFS="${HIVE_TEZ_SCRATCH_HDFS:-hdfs://nameservice:8020/opt/hive/scratch_dir/hive/_tez_session_dir}"
TEZ_LOG_CACHE_DIR="${TEZ_LOG_CACHE_DIR:-${HIVE_LOG_DIR}/tez}"
LLAP_LOG_CACHE_DIR="${LLAP_LOG_CACHE_DIR:-${HIVE_LOG_DIR}/llap}"
SERVICE="${SERVICE:-hive}"
HOST_ID="${HOSTNAME:-unknown}"
LOCK_FILE="/tmp/hdfs-log-sync.lock"

hdfs_dest() {
   printf '%s/%s/%s' "${HIVE_LOG_HDFS_BASE}" "${SERVICE}" "${HOST_ID}"
}

# gc-hiveserver2-581-... -> hiveserver2-gc-581-... ; gc-metastore-399-... -> hivemetastore-gc-399-...
canonical_log_basename() {
   local base="$1"

   case "${base}" in
      gc-hiveserver2-*)
         printf 'hiveserver2-gc-%s\n' "${base#gc-hiveserver2-}"
         ;;
      gc-metastore-*)
         printf 'hivemetastore-gc-%s\n' "${base#gc-metastore-}"
         ;;
      gc-hivemetastore-*)
         printf 'hivemetastore-gc-%s\n' "${base#gc-hivemetastore-}"
         ;;
      *)
         printf '%s\n' "${base}"
         ;;
   esac
}

# Paths under a staging dir to include in the tarball (relative to staging root).
collect_archive_paths() {
   local staging="$1"
   local paths=()

   if [ -d "${staging}/log" ]; then
      paths+=("log")
   fi
   if [ "${SERVICE}" = "hiveserver2" ] && [ -d "${staging}/tez_logs" ]; then
      paths+=("tez_logs")
   fi
   if [ "${SERVICE}" = "llapdaemon" ] && [ -d "${staging}/llap_logs" ]; then
      paths+=("llap_logs")
   fi
   if [ "${#paths[@]}" -eq 0 ]; then
      return 1
   fi
   printf '%s\n' "${paths[@]}"
}

tez_history_awk() {
   if command -v gawk >/dev/null 2>&1; then
      command -v gawk
      return 0
   fi
   command -v awk
}

tez_awk_lib_path() {
   if [ -f "${HIVE_HOME}/bin/tez-history-yarn-logs.awk" ]; then
      printf '%s\n' "${HIVE_HOME}/bin/tez-history-yarn-logs.awk"
      return 0
   fi
   if [ -f "${HIVE_HOME}/setup/tez-history-yarn-logs.awk" ]; then
      printf '%s\n' "${HIVE_HOME}/setup/tez-history-yarn-logs.awk"
      return 0
   fi
   return 1
}

tez_hs2_slice_lib_path() {
   if [ -f "${HIVE_HOME}/bin/tez-hs2-slice.awk" ]; then
      printf '%s\n' "${HIVE_HOME}/bin/tez-hs2-slice.awk"
      return 0
   fi
   if [ -f "${HIVE_HOME}/setup/tez-hs2-slice.awk" ]; then
      printf '%s\n' "${HIVE_HOME}/setup/tez-hs2-slice.awk"
      return 0
   fi
   return 1
}

llap_slice_lib_path() {
   if [ -f "${HIVE_HOME}/bin/llap-query-slice.awk" ]; then
      printf '%s\n' "${HIVE_HOME}/bin/llap-query-slice.awk"
      return 0
   fi
   if [ -f "${HIVE_HOME}/setup/llap-query-slice.awk" ]; then
      printf '%s\n' "${HIVE_HOME}/setup/llap-query-slice.awk"
      return 0
   fi
   return 1
}

llap_yarn_awk_lib_path() {
   if [ -f "${HIVE_HOME}/bin/llap-query-yarn-logs.awk" ]; then
      printf '%s\n' "${HIVE_HOME}/bin/llap-query-yarn-logs.awk"
      return 0
   fi
   if [ -f "${HIVE_HOME}/setup/llap-query-yarn-logs.awk" ]; then
      printf '%s\n' "${HIVE_HOME}/setup/llap-query-yarn-logs.awk"
      return 0
   fi
   return 1
}

# Map Tez task attempt dirs to YARN container ids for LogType:directory.info sections.
tez_build_container_dirinfo() {
   local hist="$1"
   local app_wd="$2"
   local map_file="$3"
   local attempt_path attempt_base cid size body

   : > "${map_file}"
   [ -f "${hist}" ] && [ -d "${app_wd}/localmode-local-dir/output" ] || return 0

   shopt -s nullglob
   for attempt_path in "${app_wd}/localmode-local-dir/output"/attempt_*; do
      [ -d "${attempt_path}" ] || continue
      attempt_base="$(basename "${attempt_path}")"
      cid="$(tr '\001' '\n' < "${hist}" | grep -F "\"entity\":\"${attempt_base}\"" | grep 'TASK_ATTEMPT_STARTED' | head -1 \
         | sed -n 's/.*{"entity":"\(container_[^"]*\)","entitytype":"containerId"}.*/\1/p')"
      [ -n "${cid}" ] || continue
      body="localmode-local-dir/output/${attempt_base}"
      for f in file.out file.out.index; do
         if [ -f "${attempt_path}/${f}" ]; then
            size="$(stat -c '%s' "${attempt_path}/${f}" 2>/dev/null || stat -f '%z' "${attempt_path}/${f}")"
            body="${body}"$'\n'"  ${f}: ${size} bytes"
         fi
      done
      printf '%s\t%s\n' "${cid}" "${body}" >> "${map_file}"
   done
   shopt -u nullglob
}

tez_hist_mtime() {
   local hist="$1"

   date -r "${hist}" '+%a %b %d %T %z %Y' 2>/dev/null \
      || date -r "$(stat -f '%m' "${hist}" 2>/dev/null)" '+%a %b %d %T %z %Y' 2>/dev/null \
      || date '+%a %b %d %T %z %Y'
}

# Write one yarn-style Tez log file from a local ATS history path.
emit_tez_application_log() {
   local app_id="$1"
   local hist="$2"
   local app_wd="$3"
   local out="$4"
   local map node_default hist_mtime awk_lib awk_bin hs2_slice hs2_lib

   awk_lib="$(tez_awk_lib_path)" || return 1
   awk_bin="$(tez_history_awk)"
   node_default="$(hostname -f 2>/dev/null || hostname):8042"
   hist_mtime="$(tez_hist_mtime "${hist}")"

   if [ "${HIVE_LOG_TRY_YARN_LOGS:-0}" = "1" ] && command -v yarn >/dev/null 2>&1; then
      if timeout 120 yarn logs -applicationId "${app_id}" -appOwner hive > "${out}.tmp" 2>/dev/null \
         && [ -s "${out}.tmp" ] && ! grep -qi 'Log aggregation has not completed' "${out}.tmp" 2>/dev/null; then
         mv "${out}.tmp" "${out}"
         return 0
      fi
      rm -f "${out}.tmp"
   fi

   hs2_slice="$(mktemp)"
   if hs2_lib="$(tez_hs2_slice_lib_path)"; then
      shopt -s nullglob
      if compgen -G "${HIVE_LOG_DIR}/hiveserver2*.log" >/dev/null 2>&1; then
         "${awk_bin}" -v app_id="${app_id}" -v export_info_warn="${HIVE_LOG_EXPORT_INFO_WARN}" \
            -f "${hs2_lib}" "${HIVE_LOG_DIR}"/hiveserver2*.log > "${hs2_slice}" 2>/dev/null || true
      fi
      shopt -u nullglob
   fi

   map="$(mktemp)"
   tez_build_container_dirinfo "${hist}" "${app_wd}" "${map}"
   tr '\001' '\n' < "${hist}" | "${awk_bin}" -v app_id="${app_id}" -v node_default="${node_default}" \
      -v hist_mtime="${hist_mtime}" -v dirinfo_file="${map}" -v hs2_slice_file="${hs2_slice}" \
      -f "${awk_lib}" > "${out}" 2>/dev/null || true
   rm -f "${map}" "${hs2_slice}"
   [ -s "${out}" ] || return 1
   return 0
}

tez_cache_application_log() {
   local app_id="$1"
   local out="$2"

   mkdir -p "${TEZ_LOG_CACHE_DIR}"
   cp "${out}" "${TEZ_LOG_CACHE_DIR}/${app_id}.log" 2>/dev/null || true
}

# Seed pod tez cache from the newest HDFS archive when scratch was already deleted.
bootstrap_tez_cache_from_archive() {
   local dest="$1"
   local archive_path tmpdir f base

   [ "${SERVICE}" = "hiveserver2" ] || return 0
   if compgen -G "${TEZ_LOG_CACHE_DIR}/application_*.log" >/dev/null 2>&1; then
      return 0
   fi

   mapfile -t archives < <(hdfs dfs -ls -t "${dest}" 2>/dev/null | awk 'NR>1 && $8 ~ /\/archive-.*\.tgz$/ {print $8}')
   [ "${#archives[@]}" -gt 0 ] || return 0

   mkdir -p "${TEZ_LOG_CACHE_DIR}"
   for archive_path in "${archives[@]}"; do
      tmpdir="$(mktemp -d)"
      if ! hdfs dfs -get "${archive_path}" "${tmpdir}/archive.tgz" 2>/dev/null; then
         rm -rf "${tmpdir}"
         continue
      fi
      if ! tar -tzf "${tmpdir}/archive.tgz" 2>/dev/null | grep -q '^tez_logs/application_.*\.log$'; then
         rm -rf "${tmpdir}"
         continue
      fi
      tar -xzf "${tmpdir}/archive.tgz" -C "${tmpdir}" tez_logs 2>/dev/null || true
      shopt -s nullglob
      for f in "${tmpdir}"/tez_logs/application_*.log; do
         base="$(basename "${f}")"
         cp "${f}" "${TEZ_LOG_CACHE_DIR}/${base}" 2>/dev/null || true
      done
      shopt -u nullglob
      rm -rf "${tmpdir}"
      return 0
   done
}

# Build yarn logs-style text from Tez local-mode ATS history (local scratch + HDFS scratch).
stage_tez_scratch_readable() {
   local staging="$1"
   local src_root="${HIVE_HOME}/scratch_dir/hive/_tez_session_dir"
   local dest_root="${staging}/tez_logs"
   local app_wd app_id hist out hist_hdfs app_wd_hdfs tmp_hist

   awk_lib="$(tez_awk_lib_path)" || return 0
   mkdir -p "${dest_root}" "${TEZ_LOG_CACHE_DIR}"

   while IFS= read -r -d '' app_wd; do
      app_id="$(basename "${app_wd}")"
      app_id="${app_id%_wd}"
      [ -n "${app_id}" ] || continue
      hist="$(find "${app_wd}/localmode-log-dir" -maxdepth 1 -name 'history.txt.appattempt_*' 2>/dev/null | head -1)"
      [ -f "${hist}" ] || continue
      out="${dest_root}/${app_id}.log"
      if emit_tez_application_log "${app_id}" "${hist}" "${app_wd}" "${out}"; then
         tez_cache_application_log "${app_id}" "${out}"
      fi
   done < <(find "${src_root}" -type d -path '*/.tez/application_*_wd' -print0 2>/dev/null)

   if command -v hdfs >/dev/null 2>&1 && [ -n "${HIVE_TEZ_SCRATCH_HDFS}" ]; then
      while IFS= read -r hist_hdfs; do
         [ -n "${hist_hdfs}" ] || continue
         app_wd_hdfs="$(dirname "$(dirname "${hist_hdfs}")")"
         app_id="$(basename "${app_wd_hdfs}")"
         app_id="${app_id%_wd}"
         [ -n "${app_id}" ] || continue
         out="${dest_root}/${app_id}.log"
         tmp_hist="$(mktemp)"
         if ! hdfs dfs -get -f "${hist_hdfs}" "${tmp_hist}" 2>/dev/null; then
            rm -f "${tmp_hist}"
            continue
         fi
         if emit_tez_application_log "${app_id}" "${tmp_hist}" "${app_wd_hdfs}" "${out}"; then
            tez_cache_application_log "${app_id}" "${out}"
         fi
         rm -f "${tmp_hist}"
      done < <(hdfs dfs -find "${HIVE_TEZ_SCRATCH_HDFS}" -name 'history.txt.appattempt_*' 2>/dev/null || true)
   fi

   if [ -n "$(ls -A "${dest_root}" 2>/dev/null)" ]; then
      {
         echo "Tez local-mode query logs in the same layout as: yarn logs -applicationId <id>"
         echo "One file per application id (stdout / stderr / syslog / directory.info per container)."
         echo "Set HIVE_LOG_TRY_YARN_LOGS=1 to prefer real yarn logs when YARN log aggregation is available."
         ls -1 "${dest_root}"/*.log 2>/dev/null | xargs -n1 basename | sed 's/^/  /'
      } > "${dest_root}/README.txt"
   fi
}

llap_log_mtime() {
   local newest="" f mtime best=0

   shopt -s nullglob
   for f in "${HIVE_LOG_DIR}"/llapdaemon*.log; do
      [ -f "${f}" ] || continue
      mtime="$(stat -c '%Y' "${f}" 2>/dev/null || stat -f '%m' "${f}" 2>/dev/null || echo 0)"
      if [ "${mtime}" -ge "${best}" ]; then
         best="${mtime}"
         newest="${f}"
      fi
   done
   shopt -u nullglob
   if [ -n "${newest}" ]; then
      date -r "${newest}" '+%a %b %d %T %z %Y' 2>/dev/null \
         || date -r "$(stat -f '%m' "${newest}" 2>/dev/null)" '+%a %b %d %T %z %Y' 2>/dev/null \
         || date '+%a %b %d %T %z %Y'
   else
      date '+%a %b %d %T %z %Y'
   fi
}

discover_llap_application_ids() {
   local -a ids=()
   local f base

   shopt -s nullglob
   for f in "${HIVE_LOG_DIR}"/llapdaemon*.log; do
      [ -f "${f}" ] || continue
      while IFS= read -r base; do
         [ -n "${base}" ] || continue
         ids+=("${base}")
      done < <(grep -hoE 'application_[0-9]+_[0-9]+' "${f}" 2>/dev/null | sort -u)
   done
   for f in "${LLAP_LOG_CACHE_DIR}"/application_*.log; do
      [ -f "${f}" ] || continue
      base="$(basename "${f}")"
      base="${base%.log}"
      ids+=("${base}")
   done
   shopt -u nullglob
   if [ "${#ids[@]}" -eq 0 ]; then
      return 0
   fi
   printf '%s\n' "${ids[@]}" | sort -u
}

emit_llap_application_log() {
   local app_id="$1"
   local out="$2"
   local slice_lib yarn_lib awk_bin node_default log_mtime slice

   slice_lib="$(llap_slice_lib_path)" || return 1
   yarn_lib="$(llap_yarn_awk_lib_path)" || return 1
   awk_bin="$(tez_history_awk)"
   node_default="$(hostname -f 2>/dev/null || hostname):15002"
   log_mtime="$(llap_log_mtime)"

   slice="$(mktemp)"
   shopt -s nullglob
   if ! compgen -G "${HIVE_LOG_DIR}/llapdaemon*.log" >/dev/null 2>&1; then
      shopt -u nullglob
      rm -f "${slice}"
      return 1
   fi
   "${awk_bin}" -v app_id="${app_id}" -v export_info_warn="${HIVE_LOG_EXPORT_INFO_WARN}" \
      -f "${slice_lib}" "${HIVE_LOG_DIR}"/llapdaemon*.log > "${slice}" 2>/dev/null || true
   shopt -u nullglob

   "${awk_bin}" -v app_id="${app_id}" -v slice_file="${slice}" -v node_default="${node_default}" \
      -v log_mtime="${log_mtime}" -f "${yarn_lib}" > "${out}" 2>/dev/null || true
   rm -f "${slice}"
   [ -s "${out}" ] || return 1
   return 0
}

llap_cache_application_log() {
   local app_id="$1"
   local out="$2"

   mkdir -p "${LLAP_LOG_CACHE_DIR}"
   cp "${out}" "${LLAP_LOG_CACHE_DIR}/${app_id}.log" 2>/dev/null || true
}

bootstrap_llap_cache_from_archive() {
   local dest="$1"
   local archive_path tmpdir f base

   [ "${SERVICE}" = "llapdaemon" ] || return 0
   if compgen -G "${LLAP_LOG_CACHE_DIR}/application_*.log" >/dev/null 2>&1; then
      return 0
   fi

   mapfile -t archives < <(hdfs dfs -ls -t "${dest}" 2>/dev/null | awk 'NR>1 && $8 ~ /\/archive-.*\.tgz$/ {print $8}')
   [ "${#archives[@]}" -gt 0 ] || return 0

   mkdir -p "${LLAP_LOG_CACHE_DIR}"
   for archive_path in "${archives[@]}"; do
      tmpdir="$(mktemp -d)"
      if ! hdfs dfs -get "${archive_path}" "${tmpdir}/archive.tgz" 2>/dev/null; then
         rm -rf "${tmpdir}"
         continue
      fi
      if ! tar -tzf "${tmpdir}/archive.tgz" 2>/dev/null | grep -q '^llap_logs/application_.*\.log$'; then
         rm -rf "${tmpdir}"
         continue
      fi
      tar -xzf "${tmpdir}/archive.tgz" -C "${tmpdir}" llap_logs 2>/dev/null || true
      shopt -s nullglob
      for f in "${tmpdir}"/llap_logs/application_*.log; do
         base="$(basename "${f}")"
         cp "${f}" "${LLAP_LOG_CACHE_DIR}/${base}" 2>/dev/null || true
      done
      shopt -u nullglob
      rm -rf "${tmpdir}"
      return 0
   done
}

stage_llap_query_logs() {
   local staging="$1"
   local dest_root="${staging}/llap_logs"
   local app_id out

   [ "${SERVICE}" = "llapdaemon" ] || return 0
   slice_lib="$(llap_slice_lib_path)" || return 0

   mkdir -p "${dest_root}" "${LLAP_LOG_CACHE_DIR}"

   while IFS= read -r app_id; do
      [ -n "${app_id}" ] || continue
      out="${dest_root}/${app_id}.log"
      if emit_llap_application_log "${app_id}" "${out}"; then
         llap_cache_application_log "${app_id}" "${out}"
      fi
   done < <(discover_llap_application_ids)

   shopt -s nullglob
   for f in "${LLAP_LOG_CACHE_DIR}"/application_*.log; do
      [ -f "${f}" ] || continue
      base="$(basename "${f}")"
      cp "${f}" "${dest_root}/${base}" 2>/dev/null || true
   done
   shopt -u nullglob

   if [ -n "$(ls -A "${dest_root}" 2>/dev/null)" ]; then
      {
         echo "LLAP daemon query logs in the same layout as: yarn logs -applicationId <id>"
         echo "One file per Tez application id (syslog / syslog_Fragment [n] / stderr)."
         echo "Correlate with HiveServer2 tez/application_<id>.log for AM + DAG timeline."
         ls -1 "${dest_root}"/*.log 2>/dev/null | xargs -n1 basename | sed 's/^/  /'
      } > "${dest_root}/README.txt"
   fi
}

# Copy logs into staging/log with canonical GC names; optional Tez scratch for HS2.
prepare_archive_staging() {
   local staging="$1"
   local f base canon

   rm -rf "${staging}"
   mkdir -p "${staging}/log"
   shopt -s nullglob
   for f in "${HIVE_LOG_DIR}"/*; do
      [ -f "${f}" ] || continue
      base="$(basename "${f}")"
      canon="$(canonical_log_basename "${base}")"
      cp "${f}" "${staging}/log/${canon}" 2>/dev/null || true
   done
   shopt -u nullglob
   if [ "${SERVICE}" = "hiveserver2" ]; then
      stage_tez_scratch_readable "${staging}"
   fi
   if [ "${SERVICE}" = "llapdaemon" ]; then
      stage_llap_query_logs "${staging}"
   fi
   [ -n "$(ls -A "${staging}/log" 2>/dev/null)" ] || return 1
   return 0
}

# Newest file under HIVE_LOG_DIR matching a glob (by mtime).
find_newest_log() {
   local pattern="$1"
   local newest="" f mtime best=0

   [ -d "${HIVE_LOG_DIR}" ] || return 1
   shopt -s nullglob
   for f in "${HIVE_LOG_DIR}"/${pattern}; do
      [ -f "${f}" ] || continue
      mtime="$(stat -c '%Y' "${f}" 2>/dev/null || stat -f '%m' "${f}" 2>/dev/null || echo 0)"
      if [ "${mtime}" -ge "${best}" ]; then
         best="${mtime}"
         newest="${f}"
      fi
   done
   shopt -u nullglob
   [ -n "${newest}" ] || return 1
   printf '%s\n' "${newest}"
}

# Keep newest $keep files in an HDFS directory (paths sorted newest-first by hdfs dfs -ls -t).
prune_hdfs_dir() {
   local dir="$1"
   local keep="${2:-10}"
   local -a files=()
   local i

   mapfile -t files < <(hdfs dfs -ls -t "${dir}" 2>/dev/null | awk 'NR>1 {print $8}')
   for (( i=keep; i<${#files[@]}; i++ )); do
      hdfs dfs -rm -f "${files[i]}" >/dev/null 2>&1 || true
   done
}

# Newest archive-*.tgz under a pod log directory (hdfs dfs -ls -t).
find_newest_hdfs_archive() {
   local dest="$1"

   hdfs dfs -ls -t "${dest}" 2>/dev/null | awk 'NR>1 && $8 ~ /\/archive-.*\.tgz$/ {print $8; exit}'
}

# Drop oldest matching files under $dir (e.g. archive-*.tgz at pod dest root).
prune_hdfs_glob() {
   local dir="$1"
   local pattern="$2"
   local keep="${3:-10}"
   local -a files=()
   local i

   mapfile -t files < <(hdfs dfs -ls -t "${dir}" 2>/dev/null | awk -v pat="${pattern}" 'NR>1 && $8 ~ pat {print $8}')
   for (( i=keep; i<${#files[@]}; i++ )); do
      hdfs dfs -rm -f "${files[i]}" >/dev/null 2>&1 || true
   done
}

push_log_snapshot() {
   local dest="$1"
   local hist_subdir="$2"
   local stamp="$3"
   local local_file="$4"
   local hdfs_name="$5"

   hdfs dfs -mkdir -p "${dest}/${hist_subdir}" || return 1
   if ! hdfs dfs -put -f "${local_file}" "${dest}/${hdfs_name}"; then
      return 1
   fi
   if hdfs dfs -put -f "${local_file}" "${dest}/${hist_subdir}/${stamp}.log"; then
      prune_hdfs_dir "${dest}/${hist_subdir}" "${HIVE_LOG_HDFS_HISTORY_MAX}"
   fi
   echo "hdfs-log-sync: updated ${dest}/${hdfs_name} (from $(basename "${local_file}"))"
   return 0
}

# Plain-text snapshots for Hue File Browser (stable names + bounded history per log type).
push_named_latest_logs() {
   local dest="$1"
   local stamp="$2"
   local main gc pushed=0

   case "${SERVICE}" in
      hiveserver2)
         if main="$(find_newest_log 'hiveserver2*.log')"; then
            if push_log_snapshot "${dest}" "hiveserver2" "${stamp}" "${main}" "hiveserver2.log"; then
               pushed=1
            fi
         fi
         if gc="$(find_newest_log 'gc-hiveserver2*.log')"; then
            if push_log_snapshot "${dest}" "gc" "${stamp}" "${gc}" "hiveserver2-gc.log"; then
               pushed=1
            fi
         fi
         ;;
      metastore)
         if main="$(find_newest_log 'hivemetastore*.log')"; then
            if push_log_snapshot "${dest}" "hivemetastore" "${stamp}" "${main}" "hivemetastore.log"; then
               pushed=1
            fi
         fi
         if gc="$(find_newest_log 'gc-metastore*.log')"; then
            if push_log_snapshot "${dest}" "gc" "${stamp}" "${gc}" "hivemetastore-gc.log"; then
               pushed=1
            fi
         fi
         ;;
      llapdaemon)
         if main="$(find_newest_log 'llapdaemon*.log')"; then
            if push_log_snapshot "${dest}" "llapdaemon" "${stamp}" "${main}" "llapdaemon.log"; then
               pushed=1
            fi
         fi
         ;;
      *)
         if main="$(find_newest_log '*.log')"; then
            if push_log_snapshot "${dest}" "logs" "${stamp}" "${main}" "latest.log"; then
               pushed=1
            fi
         fi
         ;;
   esac
   [ "${pushed}" -eq 1 ] || return 1
   return 0
}

# Stable LLAP / yarn-style logs on HDFS (llap/application_*.log + llap/application_*/<stamp>.log).
push_llap_log_snapshots() {
   local dest="$1"
   local stamp="$2"
   local f base app pushed=0

   [ "${SERVICE}" = "llapdaemon" ] || return 0
   [ -d "${LLAP_LOG_CACHE_DIR}" ] || return 0

   shopt -s nullglob
   for f in "${LLAP_LOG_CACHE_DIR}"/application_*.log; do
      [ -f "${f}" ] || continue
      base="$(basename "${f}")"
      app="${base%.log}"
      if push_log_snapshot "${dest}" "llap/${app}" "${stamp}" "${f}" "llap/${base}"; then
         pushed=1
      fi
   done
   shopt -u nullglob
   [ "${pushed}" -eq 1 ] || return 1
   return 0
}

# Stable Tez / yarn-style logs on HDFS (tez/application_*.log + tez/application_*/<stamp>.log).
push_tez_log_snapshots() {
   local dest="$1"
   local stamp="$2"
   local f base app pushed=0

   [ "${SERVICE}" = "hiveserver2" ] || return 0
   [ -d "${TEZ_LOG_CACHE_DIR}" ] || return 0

   shopt -s nullglob
   for f in "${TEZ_LOG_CACHE_DIR}"/application_*.log; do
      [ -f "${f}" ] || continue
      base="$(basename "${f}")"
      app="${base%.log}"
      if push_log_snapshot "${dest}" "tez/${app}" "${stamp}" "${f}" "tez/${base}"; then
         pushed=1
      fi
   done
   shopt -u nullglob
   [ "${pushed}" -eq 1 ] || return 1
   return 0
}

do_push() {
   local dest stamp tmp staging paths=()

   [ -n "${HIVE_LOG_HDFS_BASE}" ] || return 0

   dest="$(hdfs_dest)"
   stamp="$(date -u +%Y%m%d-%H%M%S)"
   tmp="/tmp/hive-logs-${HOST_ID}-${stamp}.tgz"
   staging="/tmp/hive-logs-staging-${HOST_ID}-${stamp}"

   if ! prepare_archive_staging "${staging}"; then
      rm -rf "${staging}"
      return 0
   fi

   mapfile -t paths < <(collect_archive_paths "${staging}") || {
      rm -rf "${staging}"
      return 0
   }

   if ! hdfs dfs -mkdir -p "${dest}"; then
      echo "hdfs-log-sync: failed to create ${dest}" >&2
      rm -rf "${staging}"
      return 1
   fi

   bootstrap_tez_cache_from_archive "${dest}"
   bootstrap_llap_cache_from_archive "${dest}"

   if ! tar -C "${staging}" -czf "${tmp}" "${paths[@]}" 2>/dev/null; then
      echo "hdfs-log-sync: tar failed for ${paths[*]}" >&2
      rm -f "${tmp}"
      rm -rf "${staging}"
      return 1
   fi

   # Stable HDFS snapshots (Hue); do not skip when archive upload fails later.
   if ! push_named_latest_logs "${dest}" "${stamp}"; then
      echo "hdfs-log-sync: warning: could not push latest log snapshots under ${dest}" >&2
   fi
   if ! push_tez_log_snapshots "${dest}" "${stamp}"; then
      echo "hdfs-log-sync: warning: could not push tez log snapshots under ${dest}/tez" >&2
   fi
   if ! push_llap_log_snapshots "${dest}" "${stamp}"; then
      echo "hdfs-log-sync: warning: could not push llap log snapshots under ${dest}/llap" >&2
   fi
   rm -rf "${staging}"

   archive_status=0
   if ! hdfs dfs -put -f "${tmp}" "${dest}/archive-${stamp}.tgz"; then
      echo "hdfs-log-sync: put failed for ${dest}/archive-${stamp}.tgz" >&2
      archive_status=1
   else
      hdfs dfs -rm -f "${dest}/LATEST_ARCHIVE" >/dev/null 2>&1 || true
      prune_hdfs_glob "${dest}" 'archive-.*\.tgz$' "${HIVE_LOG_HDFS_HISTORY_MAX}"
      echo "hdfs-log-sync: pushed ${dest}/archive-${stamp}.tgz"
   fi
   rm -f "${tmp}"
   return "${archive_status}"
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
   local dest archive_path archive_name tmp

   [ -n "${HIVE_LOG_HDFS_BASE}" ] || return 0

   dest="$(hdfs_dest)"
   archive_path="$(find_newest_hdfs_archive "${dest}")"
   if [ -z "${archive_path}" ]; then
      echo "hdfs-log-sync: no archive-*.tgz under ${dest}"
      return 0
   fi
   archive_name="${archive_path##*/}"

   tmp="/tmp/hive-logs-restore-${HOST_ID}.tgz"
   if ! hdfs dfs -get "${archive_path}" "${tmp}"; then
      echo "hdfs-log-sync: get failed for ${archive_path}" >&2
      return 1
   fi

   mkdir -p "${HIVE_LOG_DIR}"
   tar -xzf "${tmp}" -C "${HIVE_HOME}" 2>/dev/null || true
   rm -f "${tmp}"
   echo "hdfs-log-sync: restored ${archive_path} into ${HIVE_HOME}"
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
   push || true
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
