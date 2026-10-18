# Slice LLAP daemon logs for one Tez application id (query fragments + errors/stacks).
# Usage: gawk -v app_id=application_xxx_yyyy -f llap-query-slice.awk /opt/hive/log/llapdaemon*.log

BEGIN {
   if (app_id == "") {
      exit 0
   }
   slice_err = ""
   info_buf = ""
   session_buf = ""
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
   ap = app_id
   sub(/^application_/, "attempt_", ap)
   if (index(line, ap) == 1) {
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
   if (line ~ /Query failed|Task failed|Fragment.*failed/i) {
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
   slice_err = slice_err msg "\n"
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

function in_app_scope(line) {
   return in_session || belongs_to_app(line)
}

function match_frag(line,    f) {
   if (match(line, /Fragment \[[0-9]+\]/)) {
      f = substr(line, RSTART, RLENGTH)
      if (belongs_to_app(line)) {
         return f
      }
   }
   if (match(line, /SignificantFragment \[[0-9]+\]/)) {
      f = substr(line, RSTART, RLENGTH)
      if (belongs_to_app(line)) {
         return f
      }
   }
   return ""
}

function route_line(line,    frag) {
   frag = match_frag(line)
   if (frag != "") {
      frag_buf[frag] = frag_buf[frag] line "\n"
      return
   }
   session_buf = session_buf line "\n"
}

{
   line = $0

   if (index(line, app_id) > 0 && line ~ /Received work|Submitting work|Executing work/i) {
      in_session = 1
   }

   if (in_trace || trace_left > 0) {
      if (is_error_line(line) || is_trace_line(line)) {
         slice_err = slice_err line "\n"
      }
      if (is_trace_line(line)) {
         trace_left = 40
      } else if (line ~ /^[[:space:]]*$/) {
         in_trace = 0
         trace_left = 0
      } else {
         trace_left--
      }
      if (in_app_scope(line)) {
         append_info_warn(line)
         route_line(line)
      }
      next
   }

   if (in_session && index(line, app_id) > 0 && line ~ /Work completed|Query complete|Finished executing/i) {
      append_info_warn(line)
      route_line(line)
      in_session = 0
      next
   }

   if (!in_app_scope(line)) {
      next
   }

   if (is_error_line(line)) {
      slice_err = slice_err line "\n"
      in_trace = 1
      trace_left = 40
      route_line(line)
      append_info_warn(line)
      next
   }

   append_info_warn(line)
   route_line(line)
}

END {
   if (slice_err != "") {
      print "__ERR__"
      printf("%s", slice_err)
   }
   if (info_buf != "") {
      print "__INFO__"
      printf("%s", info_buf)
   }
   if (session_buf != "") {
      print "__SESSION__"
      printf("%s", session_buf)
   }
   for (frag in frag_buf) {
      if (frag_buf[frag] == "") {
         continue
      }
      printf("__FRAG__ %s\n", frag)
      printf("%s", frag_buf[frag])
   }
}
