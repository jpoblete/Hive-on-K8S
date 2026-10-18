# Slice HiveServer2 logs for one Tez application (local mode): AM/DAG/attempt text + errors/stacks.
# Usage: gawk -v app_id=application_xxx_yyyy -f tez-hs2-slice.awk /opt/hive/log/hiveserver2*.log

BEGIN {
   if (app_id == "") {
      exit 0
   }
   err_buf = ""
   info_buf = ""
   am_buf = ""
   dag_prefix = app_id
   sub(/^application_/, "dag_", dag_prefix)
   dag_prefix = dag_prefix "_"
   in_session = 0
   in_trace = 0
   trace_left = 0
   export_info_warn = (export_info_warn == "" ? 1 : export_info_warn + 0)
}

function belongs_to_app(line) {
   if (index(line, app_id) > 0) {
      return 1
   }
   if (index(line, dag_prefix) > 0) {
      return 1
   }
   return 0
}

function is_error_line(line) {
   if (line ~ / ERROR[[:space:]\[]/ || line ~ / FATAL[[:space:]\[]/) {
      return 1
   }
   if (line ~ / WARN .*Exception/) {
      return 1
   }
   if (line ~ /Query failed|Task failed|DAG failed/i) {
      return 1
   }
   if (line ~ / FAILED /) {
      return 1
   }
   if (line ~ /OutOfMemoryError|NullPointerException|java\.lang\.[A-Za-z]+Exception/) {
      return 1
   }
   return 0
}

function is_trace_line(line) {
   return line ~ /[[:space:]]+at org\./ \
      || line ~ /[[:space:]]+at java\./ \
      || line ~ /[[:space:]]+at sun\./ \
      || line ~ /Caused by:/ \
      || line ~ /[[:space:]]+\.\.\. [0-9]+ more/
}

function append_error(msg) {
   err_buf = err_buf msg "\n"
}

function is_info_or_warn(line) {
   return line ~ / INFO[[:space:]\[]/ || line ~ / WARN[[:space:]\[]/
}

function append_info_warn(line) {
   if (!export_info_warn) {
      return
   }
   if (!is_info_or_warn(line)) {
      return
   }
   info_buf = info_buf line "\n"
}

function match_dag(line,    d) {
   if (match(line, /dag_[0-9]+_[0-9]+_[0-9]+/)) {
      d = substr(line, RSTART, RLENGTH)
      if (index(d, dag_prefix) == 1) {
         return d
      }
   }
   return ""
}

function match_attempt(line,    a, ap) {
   ap = app_id
   sub(/^application_/, "attempt_", ap)
   if (match(line, /attempt_[0-9]+_[0-9]+_[0-9]+_[0-9]+_[0-9]+_[0-9]+(_[0-9]+)?/)) {
      a = substr(line, RSTART, RLENGTH)
      if (index(a, ap) == 1) {
         return a
      }
   }
   return ""
}

function note_dag_post(line, dag) {
   if (dag != "" && index(line, "Event:DAG_FINISHED") > 0 && index(line, dag) > 0) {
      dag_post_mode[dag] = 1
   }
}

function route_line(line,    dag, att, dag_key) {
   dag = match_dag(line)
   if (dag != "") {
      note_dag_post(line, dag)
      if (dag in dag_post_mode && dag_post_mode[dag]) {
         dag_key = dag "_post"
      } else {
         dag_key = dag
      }
      dag_buf[dag_key] = dag_buf[dag_key] line "\n"
      return
   }
   att = match_attempt(line)
   if (att != "") {
      attempt_buf[att] = attempt_buf[att] line "\n"
      return
   }
   if (in_session || index(line, app_id) > 0) {
      am_buf = am_buf line "\n"
   }
}

{
   line = $0

   if (line ~ ("Using working directory:.*\\.tez/" app_id "_wd") \
       || line ~ ("applicationId=" app_id) \
       || line ~ ("applicationId: " app_id)) {
      in_session = 1
   }

   if (in_trace || trace_left > 0) {
      if (is_error_line(line) || is_trace_line(line)) {
         append_error(line)
      }
      if (is_trace_line(line)) {
         trace_left = 40
      } else if (line ~ /^[[:space:]]*$/) {
         in_trace = 0
         trace_left = 0
      } else {
         trace_left--
      }
      if (belongs_to_app(line) || in_session) {
         route_line(line)
      }
      next
   }

   if (is_error_line(line) && (in_session || belongs_to_app(line))) {
      append_error(line)
      in_trace = 1
      trace_left = 40
      route_line(line)
      append_info_warn(line)
      next
   }

   if (in_session && (line ~ ("Shutting down Tez Session.*applicationId=" app_id) \
       || line ~ ("Completed deletion of tez scratch.*" app_id))) {
      route_line(line)
      append_info_warn(line)
      in_session = 0
      next
   }

   if (!in_session && !belongs_to_app(line)) {
      next
   }

   append_info_warn(line)
   route_line(line)
}

END {
   if (err_buf != "") {
      print "__ERR__"
      printf("%s", err_buf)
   }
   if (info_buf != "") {
      print "__INFO__"
      printf("%s", info_buf)
   }
   if (am_buf != "") {
      print "__AM__"
      printf("%s", am_buf)
   }
   for (dk in dag_buf) {
      if (dag_buf[dk] == "") {
         continue
      }
      if (dk ~ /_post$/) {
         gsub(/_post$/, "", dk)
         printf("__DAG__ %s_post\n", dk)
      } else {
         printf("__DAG__ %s\n", dk)
      }
      printf("%s", dag_buf[dk])
   }
   for (att in attempt_buf) {
      if (attempt_buf[att] == "") {
         continue
      }
      printf("__ATTEMPT__ %s\n", att)
      printf("%s", attempt_buf[att])
   }
}
