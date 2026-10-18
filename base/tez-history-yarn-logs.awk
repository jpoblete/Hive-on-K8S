# Tez local-mode: ATS history + optional HS2 log slice -> yarn logs-style output.
# Focus: DAG timeline, per-DAG syslog, errors/stack traces in stderr.

BEGIN {
   FS = ""
   ORS = ""
}

function rel_entity(line, want_type,    a, rest) {
   rest = line
   while (match(rest, /\{"entity":"([^"]+)","entitytype":"([^"]+)"\}/, a)) {
      if (a[2] == want_type) {
         return a[1]
      }
      rest = substr(rest, RSTART + RLENGTH)
   }
   return ""
}

function has_event(line, name,    a, rest) {
   rest = line
   while (match(rest, /"eventtype":"([^"]+)"/, a)) {
      if (a[1] == name) {
         return 1
      }
      rest = substr(rest, RSTART + RLENGTH)
   }
   return 0
}

function field_str(line, key,    a) {
   if (match(line, "\"" key "\":\"([^\"]*)\"" , a)) {
      gsub(/\\\//, "/", a[1])
      return a[1]
   }
   return ""
}

function field_num(line, key,    a) {
   if (match(line, "\"" key "\":([0-9]+)" , a)) {
      return a[1] + 0
   }
   return 0
}

function counters_text(line,    rest, a, out) {
   out = ""
   rest = line
   while (match(rest, /"counterName":"([^"]+)","counterValue":([0-9]+)/, a)) {
      if (out != "") {
         out = out "\n"
      }
      out = out "  " a[1] "=" a[2]
      rest = substr(rest, RSTART + RLENGTH)
   }
   return out
}

function register_container(cid, nid) {
   if (cid == "") {
      return
   }
   if (!(cid in container_seen)) {
      container_seen[cid] = 1
      container_order[++container_count] = cid
   }
   if (nid != "" && container_node[cid] == "") {
      container_node[cid] = nid
   }
   if (container_node[cid] == "") {
      container_node[cid] = node_default
   }
}

function add_body(cid, logtype, chunk) {
   if (cid == "" || chunk == "") {
      return
   }
   register_container(cid, "")
   key = cid SUBSEP logtype
   if (body[key] != "") {
      body[key] = body[key] "\n"
   }
   body[key] = body[key] chunk
}

function timeline_add(msg) {
   dag_timeline = dag_timeline msg "\n"
}

function load_hs2_slice(file,    line, mode, tag, att, cid) {
   if (file == "") {
      return
   }
   am_container = ""
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
      if (line == "__AM__") {
         mode = "am"
         continue
      }
      if (line ~ /^__DAG__ /) {
         tag = substr(line, 9)
         mode = "dag"
         dag_tag = tag
         continue
      }
      if (line ~ /^__ATTEMPT__ /) {
         att = substr(line, 13)
         mode = "attempt"
         attempt_tag = att
         continue
      }
      if (mode == "err") {
         hs2_err = hs2_err line "\n"
         continue
      }
      if (mode == "info") {
         hs2_info = hs2_info line "\n"
         continue
      }
      if (mode == "am") {
         hs2_am = hs2_am line "\n"
         continue
      }
      if (mode == "dag") {
         hs2_dag[dag_tag] = hs2_dag[dag_tag] line "\n"
         continue
      }
      if (mode == "attempt") {
         hs2_attempt[attempt_tag] = hs2_attempt[attempt_tag] line "\n"
         cid = attempt_container[attempt_tag]
         if (cid != "") {
            add_body(cid, "syslog", line)
         }
      }
   }
   close(file)
}

function emit_log(cid, logtype, content,    node, hdr, len, sep) {
   register_container(cid, "")
   node = container_node[cid]
   if (content == "") {
      return
   }
   len = length(content)
   sep = "=========================================================================================="
   hdr = sprintf("Container: %s on %s\nLogAggregationType: AGGREGATED\n%s\n", cid, node, sep)
   hdr = hdr sprintf("LogType:%s\nLogLastModifiedTime:%s\nLogLength:%d\nLogContents:\n", logtype, hist_mtime, len)
   printf("%s%s\nEnd of LogType:%s\n", hdr, content, logtype)
   printf("*******************************************************************************************\n\n")
}

function am_container_id(    i, cid) {
   if (container_count < 1) {
      return ""
   }
   n = asort(container_order, sorted)
   return sorted[1]
}

{
   line = $0
   entity = field_str(line, "entity")
   etype = field_str(line, "entitytype")

   if (etype == "TEZ_CONTAINER_ID" && has_event(line, "CONTAINER_LAUNCHED")) {
      cid = rel_entity(line, "containerId")
      if (cid == "") {
         cid = entity
         sub(/^tez_container_/, "container_", cid)
      }
      register_container(cid, node_default)
   }

   if (etype == "TEZ_DAG_ID") {
      if (has_event(line, "DAG_SUBMITTED")) {
         dag = field_str(line, "dagName")
         timeline_add("DAG_SUBMITTED " entity " " dag)
      }
      if (has_event(line, "DAG_STARTED")) {
         timeline_add("DAG_STARTED " entity)
      }
      if (has_event(line, "DAG_FINISHED")) {
         timeline_add("DAG_FINISHED " entity)
      }
   }

   if (etype == "TEZ_VERTEX_ID") {
      if (has_event(line, "VERTEX_STARTED")) {
         timeline_add("VERTEX_STARTED " entity)
      }
      if (has_event(line, "VERTEX_FINISHED")) {
         timeline_add("VERTEX_FINISHED " entity)
      }
   }

   if (etype == "TEZ_TASK_ATTEMPT_ID") {
      cid = rel_entity(line, "containerId")
      nid = rel_entity(line, "nodeId")
      if (cid != "" && entity != "") {
         attempt_container[entity] = cid
      }
      if (cid == "" && entity != "" && (entity in attempt_container)) {
         cid = attempt_container[entity]
      }
      register_container(cid, nid)

      if (has_event(line, "TASK_ATTEMPT_STARTED")) {
         timeline_add("TASK_ATTEMPT_STARTED " entity " -> " cid)
      }

      if (has_event(line, "TASK_ATTEMPT_FINISHED")) {
         status = field_str(line, "status")
         diag = field_str(line, "diagnostics")
         taken = field_num(line, "timeTaken")
         ctr = counters_text(line)
         timeline_add("TASK_ATTEMPT_FINISHED " entity " status=" status " timeTakenMs=" taken)
         chunk = "Tez task attempt finished: " entity "\nStatus: " status
         if (taken > 0) {
            chunk = chunk "\ntimeTaken(ms): " taken
         }
         if (diag != "") {
            chunk = chunk "\nDiagnostics: " diag
         }
         if (ctr != "") {
            chunk = chunk "\nCounters:\n" ctr
         }
         add_body(cid, "syslog", chunk)
         if (status == "FAILED" || diag != "") {
            add_body(cid, "stderr", chunk)
         }
      }
   }

   if (etype == "TEZ_APPLICATION_ATTEMPT" && has_event(line, "AM_STARTED")) {
      timeline_add("AM_STARTED " entity)
   }
}

END {
   load_hs2_slice(hs2_slice_file)

   if (hs2_err != "") {
      timeline_add("")
      timeline_add("=== HS2 errors / stack traces (application scope) ===")
   }

   cid_am = am_container_id()
   if (cid_am == "" && container_count == 0 && hs2_am == "" && hs2_err == "") {
      exit 0
   }

   if (app_id != "") {
      printf("Specified ALL for -am option. Printed logs for all am containers (Tez local mode).\n")
   }

   if (cid_am == "" && container_count > 0) {
      cid_am = am_container_id()
   }

   if (dag_timeline != "" && cid_am != "") {
      add_body(cid_am, "syslog", "=== DAG timeline (from Tez ATS history) ===\n" dag_timeline)
   }

   if (hs2_am != "" && cid_am != "") {
      add_body(cid_am, "syslog", "=== HiveServer2 Tez AM / session log ===\n" hs2_am)
   }

   if (hs2_info != "" && cid_am != "") {
      add_body(cid_am, "syslog", "=== HiveServer2 INFO / WARN (application scope) ===\n" hs2_info)
   }

   if (cid_am != "") {
      for (dtag in hs2_dag) {
         if (hs2_dag[dtag] == "") {
            continue
         }
         lt = "syslog_" dtag
         add_body(cid_am, lt, hs2_dag[dtag])
      }
   }

   if (hs2_err != "") {
      if (cid_am != "") {
         add_body(cid_am, "stderr", hs2_err)
      }
      for (i = 1; i <= container_count; i++) {
         add_body(container_order[i], "stderr", hs2_err)
      }
   }

   for (att in hs2_attempt) {
      cid = attempt_container[att]
      if (cid == "" || hs2_attempt[att] == "") {
         continue
      }
      add_body(cid, "syslog", "=== Task attempt log (HiveServer2) ===\n" hs2_attempt[att])
   }

   if (dirinfo_file != "") {
      while ((getline line < dirinfo_file) > 0) {
         split(line, parts, "\t")
         if (length(parts) >= 2) {
            add_body(parts[1], "directory.info", parts[2])
         }
      }
      close(dirinfo_file)
   }

   if (container_count == 0) {
      register_container(node_default, node_default)
      container_order[1] = node_default
      container_count = 1
      cid_am = node_default
      if (hs2_am != "") {
         add_body(cid_am, "syslog", hs2_am)
      }
      if (hs2_err != "") {
         add_body(cid_am, "stderr", hs2_err)
      }
   }

   n = asort(container_order, sorted)
   for (i = 1; i <= n; i++) {
      cid = sorted[i]
      key = cid SUBSEP "syslog"
      if (body[key] != "") {
         emit_log(cid, "syslog", body[key])
      }
      key = cid SUBSEP "stderr"
      if (body[key] != "") {
         emit_log(cid, "stderr", body[key])
      }
      for (dtag in hs2_dag) {
         lt = "syslog_" dtag
         key = cid SUBSEP lt
         if (body[key] != "" && cid == cid_am) {
            emit_log(cid, lt, body[key])
         }
      }
      key = cid SUBSEP "directory.info"
      if (body[key] != "") {
         emit_log(cid, "directory.info", body[key])
      }
      emit_log(cid, "stdout", "\n")
   }
}
