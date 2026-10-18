# LLAP daemon log slice -> yarn logs-style output (syslog per fragment, stderr for errors).
# Usage: gawk -v app_id=application_xxx -v slice_file=slice.txt -v node_default=host:15002 \
#        -v log_mtime="..." -f llap-query-yarn-logs.awk

BEGIN {
   ORS = ""
   if (app_id == "") {
      exit 0
   }
   cid = "llap_executor@" node_default
   load_slice(slice_file)
}

function load_slice(file,    line, mode, tag) {
   if (file == "") {
      return
   }
   mode = ""
   while ((getline line < file) > 0) {
      if (line == "__ERR__") {
         mode = "err"
         continue
      }
      if (line == "__INFO__") {
         mode = "info"
         continue
      }
      if (line == "__SESSION__") {
         mode = "session"
         continue
      }
      if (line ~ /^__FRAG__ /) {
         tag = substr(line, 10)
         mode = "frag"
         frag_tag = tag
         continue
      }
      if (mode == "err") {
         err_buf = err_buf line "\n"
         continue
      }
      if (mode == "info") {
         info_buf = info_buf line "\n"
         continue
      }
      if (mode == "session") {
         session_buf = session_buf line "\n"
         if (line ~ / ERROR[[:space:]\[]/ || line ~ / FATAL[[:space:]\[]/ \
             || line ~ /OutOfMemoryError|NullPointerException|Caused by:/ \
             || line ~ /[[:space:]]+at org\./) {
            err_buf = err_buf line "\n"
         }
         continue
      }
      if (mode == "frag" && frag_tag != "") {
         frag_buf[frag_tag] = frag_buf[frag_tag] line "\n"
      }
   }
   close(file)
}

function emit_log(logtype, content,    hdr, len, sep) {
   if (content == "") {
      return
   }
   len = length(content)
   sep = "=========================================================================================="
   hdr = sprintf("Container: %s on %s\nLogAggregationType: AGGREGATED\n%s\n", cid, node_default, sep)
   hdr = hdr sprintf("LogType:%s\nLogLastModifiedTime:%s\nLogLength:%d\nLogContents:\n", logtype, log_mtime, len)
   printf("%s%s\nEnd of LogType:%s\n", hdr, content, logtype)
   printf("*******************************************************************************************\n\n")
}

END {
   if (session_buf == "" && info_buf == "" && err_buf == "" && length(frag_buf) == 0) {
      exit 0
   }

   printf("LLAP daemon logs for Tez application %s (yarn logs layout).\n", app_id)
   printf("Source: llapdaemon process log on %s\n\n", node_default)

   if (info_buf != "") {
      emit_log("syslog", "=== LLAP INFO / WARN (application scope) ===\n" info_buf)
   }

   header = "=== LLAP session / executor log ===\n"
   if (session_buf != "") {
      emit_log("syslog", header session_buf)
   }

   n = asorti(frag_buf, frag_order)
   for (i = 1; i <= n; i++) {
      tag = frag_order[i]
      if (frag_buf[tag] == "") {
         continue
      }
      emit_log("syslog_" tag, "=== " tag " ===\n" frag_buf[tag])
   }

   if (err_buf != "") {
      emit_log("stderr", err_buf)
   }

   emit_log("stdout", "\n")
}
