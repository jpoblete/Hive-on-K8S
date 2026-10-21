#!/bin/bash
# Usage Notice: This project is not meant for commercial use without permission and proper credit.
# Author: j.martinez.poblete@gmail.com
#
# This script should live at the root of the project
# Assumptions:
# * K8S cluster is available
# * User has permissions to create/delete:
#   + StatefulSets
#   + Services
#   + ConfigMaps
#   + PersistentVolumes
#   + Pods
#
#
# Variables
#
set -o pipefail
HIVECTL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#
# Helpers
#
# Print command usage and supported actions.
function help(){
   echo "Usage:  hiveCtl [available|start|stop|status|restart|backup|restore|cleanup|disk|resync-keytabs] <overlay> [<component>]"
   echo "        hiveCtl available"
   echo "        hiveCtl start   <overlay>"
   echo "        hiveCtl stop    <overlay>"
   echo "        hiveCtl restart <overlay>"
   echo "        hiveCtl restart <overlay> <component>"
   echo "        hiveCtl start   <overlay> <component>"
   echo "        hiveCtl stop    <overlay> <component>"
   echo "        hiveCtl backup  <overlay> [<backup-dir>]"
   echo "        hiveCtl restore <overlay> <backup-dir>"
   echo "  secure backup also writes mysql-ranger.sql when Ranger Admin has been started (policy DB)."
   echo "        hiveCtl cleanup <overlay>"
   echo "        hiveCtl disk   (check Kind node /var space; prune container images if low)"
   echo "        hiveCtl resync-keytabs <overlay>   (secure: refresh Secret kerberos-keytabs from KDC PVC)"
   echo "        hiveCtl list passwd [<overlay>]    (password aliases; with overlay, keys present in hive-credentials)"
   echo "        hiveCtl get passwd <overlay> <alias>   (print one password from hive-credentials)"
   echo "        hiveCtl get passwd <alias>             (same; overlay defaults to secure, or HIVECTL_PASSWD_OVERLAY)"
   echo "        hiveCtl status   (active components and ready/total pod counts)"
   echo ""
   echo "Hue (llap|secure): after start, hiveCtl tries http://localhost:8888 automatically"
   echo "  (kubectl port-forward in background unless the port already works, e.g. kind/llap-cluster.yaml)"
   echo "  While hue-0 is Ready, a background monitor restarts port-forward every minute if localhost stops responding"
   echo "  Disable forward: HIVECTL_HUE_PORT_FORWARD=0   Port: HIVECTL_HUE_LOCAL_PORT=8888"
   echo "  Disable monitor: HIVECTL_HUE_PORT_FORWARD_MONITOR=0   Interval: HIVECTL_HUE_PORT_FORWARD_MONITOR_INTERVAL=60"
   echo "Ranger Admin (secure): after 'start secure ranger', hiveCtl tries http://localhost:6080/login.jsp"
   echo "  Same port-forward + monitor pattern as Hue. Disable: HIVECTL_RANGER_PORT_FORWARD=0"
   echo "  Port: HIVECTL_RANGER_LOCAL_PORT=6080   Monitor: HIVECTL_RANGER_PORT_FORWARD_MONITOR=0"
   echo "  Login: admin + password from: kubectl get secret hive-credentials -n secure -o jsonpath='{.data.ranger-admin-password}' | base64 -d; echo"
   echo "LLAP daemon UI: http://localhost:15002 after start llapdaemon (pod llapdaemon-0)"
   echo "  Disable: HIVECTL_LLAP_DAEMON_PORT_FORWARD=0   Port: HIVECTL_LLAP_DAEMON_LOCAL_PORT=15002"
   echo "Profile secure: llap-shaped Hive (2 HMS, 2 HS2, 2 LLAP) + KDC, NN + 3 DNs, ZK, Hue (./hiveCtl.sh start secure)"
   echo "Ranger (secure, optional): HIVECTL_SECURE_RANGER=1 ./hiveCtl.sh start secure   or: ./hiveCtl.sh start secure ranger"
   echo "Ranger Hive plugin (secure HS2 Phase 2): build docker/hive-ranger, then HIVECTL_SECURE_RANGER_HS2=1 ./hiveCtl.sh start secure hiveserver2"
   echo "  With HS2 plugin, hiveCtl creates secure_hive + lab admin policies (HIVECTL_SECURE_RANGER_BOOTSTRAP_HIVE=auto; 0 to skip)"
   echo "  Image: HIVE_RANGER_IMAGE=hive-on-k8s/hive-ranger:2.4.0-nightly (default)"
   echo "  Kind: hiveCtl runs 'kind load docker-image' for that tag when present locally (HIVECTL_KIND_LOAD=0 to skip)"
   echo "  Kind cluster name: HIVECTL_KIND_CLUSTER_NAME or KIND_CLUSTER (else inferred from node name, e.g. desktop)"
   echo "Disk: before start/restore, hiveCtl checks Kind /var on all nodes (mini, llap, secure, standalone)"
   echo "  Prune when use exceeds threshold: HIVECTL_DISK_MAX_USE_PERCENT=90 (HIVECTL_DISK_CHECK=0 to skip)"
}
# Print the names of the objects kubectl get selects, nothing when there are none.
# A failed API call isn't read as "none": after three attempts its error is shown and the status is 2.
function kubectlNames(){
   local attempt=1
   local errors=""

   until errors="$(kubectl get "$@" -o name --ignore-not-found 2>&1 >&3)"; do
      if [ "${attempt}" -ge 3 ]; then
         echo "${errors}" >&2
         return 2
      fi
      attempt=$((attempt + 1))
      sleep 2
   done 3>&1
}
# Return 0 when the Kubernetes namespace exists, 1 when it doesn't, 2 when Kubernetes can't be queried.
function namespaceExists(){
   local namespace="$1"
   local names=""

   names="$(kubectlNames namespace "${namespace}")" || return 2
   [ -n "${names}" ]
}
# Require a namespace before running namespace-scoped operations.
function requireNamespace(){
   local namespace="$1"

   namespaceExists "${namespace}"
   case $? in
      0) return 0 ;;
      1) echo "Namespace '${namespace}' does not exist" ;;
   esac
   return 1
}
# Create the namespace when it doesn't exist yet.
function ensureNamespace(){
   local namespace="$1"

   namespaceExists "${namespace}"
   case $? in
      0) return 0 ;;
      1) kubectl create namespace "${namespace}" --save-config >/dev/null ;;
      *) return 1 ;;
   esac
}
# Generate a local password for Kubernetes Secrets.
function generatePassword(){
   if command -v uuidgen >/dev/null 2>&1; then
      uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]'
   else
      date "+%s%N"
   fi
}
# Ranger UI/DB passwords must include upper, lower, and digit (see setup.sh validatePassword).
function generateRangerPassword(){
   local suffix=""
   suffix="$(generatePassword)"
   printf 'Ra%s' "${suffix:0:29}"
}
function rangerPasswordMeetsPolicy(){
   local password="$1"
   [ "${#password}" -ge 8 ] || return 1
   [[ "${password}" =~ [A-Z] ]] || return 1
   [[ "${password}" =~ [a-z] ]] || return 1
   [[ "${password}" =~ [0-9] ]] || return 1
   case "${password}" in *[\`\'\"]* ) return 1 ;; esac
   return 0
}
# Create the namespace-local Secret used by bootstrap scripts when absent.
function ensureSecrets(){
   local namespace="$1"
   local root_password=""
   local hive_password=""
   local hadoop_password=""
   local mysql_root_password=""
   local hive_metastore_password=""
   local beeline_password=""
   local hue_mysql_password=""
   local hue_secret_key=""
   local admin_password=""
   local krb5_master_password=""
   local krb5_kadmin_password=""
   local names=""

   ensureNamespace "${namespace}" || return 1
   names="$(kubectlNames secret hive-credentials -n "${namespace}")" || return 1
   if [ -n "${names}" ]; then
      return 0
   fi

   root_password="$(generatePassword)"
   hive_password="$(generatePassword)"
   hadoop_password="$(generatePassword)"
   mysql_root_password="$(generatePassword)"
   hive_metastore_password="$(generatePassword)"
   beeline_password="${hive_password}"
   hue_mysql_password="$(generatePassword)"
   hue_secret_key="$(generatePassword)"
   admin_password="admin"
   krb5_master_password="$(generatePassword)"
   krb5_kadmin_password="$(generatePassword)"

   # Existing mini PVCs were initialized with the historical lab passwords.
   # Preserve compatibility so adding Secrets does not break a running metastore.
   if [ "${namespace}" = "mini" ]; then
      names="$(kubectlNames pvc mysql-mysql-0 -n "${namespace}")" || return 1
      if [ -n "${names}" ]; then
         root_password="cloudera"
         hive_password="hive"
         hadoop_password="hadoop"
         mysql_root_password="mysql"
         hive_metastore_password="hive"
         beeline_password="hive"
      fi
   fi

   if [ "${namespace}" = "secure" ]; then
      kubectl create secret generic hive-credentials -n "${namespace}" \
         --from-literal=root-password="${root_password}" \
         --from-literal=hive-password="${hive_password}" \
         --from-literal=hadoop-password="${hadoop_password}" \
         --from-literal=mysql-root-password="${mysql_root_password}" \
         --from-literal=hive-metastore-password="${hive_metastore_password}" \
         --from-literal=beeline-password="${beeline_password}" \
         --from-literal=hue-mysql-password="${hue_mysql_password}" \
         --from-literal=hue-secret-key="${hue_secret_key}" \
         --from-literal=admin-password="${admin_password}" \
         --from-literal=krb5-master-password="${krb5_master_password}" \
         --from-literal=krb5-kadmin-password="${krb5_kadmin_password}" >/dev/null
   else
      kubectl create secret generic hive-credentials -n "${namespace}" \
         --from-literal=root-password="${root_password}" \
         --from-literal=hive-password="${hive_password}" \
         --from-literal=hadoop-password="${hadoop_password}" \
         --from-literal=mysql-root-password="${mysql_root_password}" \
         --from-literal=hive-metastore-password="${hive_metastore_password}" \
         --from-literal=beeline-password="${beeline_password}" \
         --from-literal=hue-mysql-password="${hue_mysql_password}" \
         --from-literal=hue-secret-key="${hue_secret_key}" \
         --from-literal=admin-password="${admin_password}" >/dev/null
   fi
}
# Add MIT KDC credentials to an existing secure secret (clusters created before krb5kdc).
function ensureKrb5Secrets(){
   local namespace="$1"
   local krb5_master_password=""
   local krb5_kadmin_password=""
   local existing=""

   [ "${namespace}" = "secure" ] || return 0
   ensureSecrets "${namespace}" || return 1
   existing="$(kubectl get secret hive-credentials -n "${namespace}" -o jsonpath='{.data.krb5-master-password}' 2>/dev/null)" || return 1
   if [ -n "${existing}" ]; then
      return 0
   fi
   krb5_master_password="$(generatePassword)"
   krb5_kadmin_password="$(generatePassword)"
   kubectl patch secret hive-credentials -n "${namespace}" --type merge \
      -p "{\"stringData\":{\"krb5-master-password\":\"${krb5_master_password}\",\"krb5-kadmin-password\":\"${krb5_kadmin_password}\"}}" >/dev/null
}
# Wait until the KDC pod has written lab keytabs to its PVC.
function waitForLabKeytabs(){
   local namespace="$1"
   local attempt=0

   while [ "${attempt}" -lt 60 ]; do
      if kubectl exec -n "${namespace}" krb5kdc-0 -- test -f /var/lib/krb5kdc/keytabs/.lab-keytabs-hadoop-hive-admin 2>/dev/null; then
         return 0
      fi
      attempt=$((attempt + 1))
      sleep 5
   done
   echo "Timed out waiting for lab keytabs on krb5kdc in namespace '${namespace}'"
   return 1
}
# Copy lab keytabs from the KDC PVC into Secret kerberos-keytabs for pod mounts.
function ensureKerberosKeytabSecret(){
   local namespace="$1"
   local tmpdir=""
   local keytab_list=""
   local keytab_file=""
   local create_args=()

   [ "${namespace}" = "secure" ] || return 0
   if kubectl get secret kerberos-keytabs -n "${namespace}" >/dev/null 2>&1; then
      if [ -n "$(kubectl get secret kerberos-keytabs -n "${namespace}" -o jsonpath='{.data.hadoop-namenode-0\.keytab}' 2>/dev/null)" ] \
         && [ -z "${HIVECTL_KRB5_RESYNC_KEYTABS:-}" ]; then
         return 0
      fi
   fi
   waitForReady "${namespace}" "krb5kdc" || return 1
   waitForLabKeytabs "${namespace}" || return 1
   if ! kubectl exec -n "${namespace}" krb5kdc-0 -- test -f /var/lib/krb5kdc/keytabs/.lab-host-keytabs-v3 2>/dev/null; then
      echo "Waiting for host keytabs on krb5kdc (.lab-host-keytabs-v3) ..."
      local attempt=0
      while [ "${attempt}" -lt 60 ]; do
         if kubectl exec -n "${namespace}" krb5kdc-0 -- test -f /var/lib/krb5kdc/keytabs/.lab-host-keytabs-v3 2>/dev/null; then
            break
         fi
         attempt=$((attempt + 1))
         sleep 5
      done
      kubectl exec -n "${namespace}" krb5kdc-0 -- test -f /var/lib/krb5kdc/keytabs/.lab-host-keytabs-v3 2>/dev/null || return 1
   fi
   tmpdir="$(mktemp -d)"
   trap 'rm -rf "${tmpdir}"' RETURN
   keytab_list="$(kubectl exec -n "${namespace}" krb5kdc-0 -- sh -c 'ls -1 /var/lib/krb5kdc/keytabs/*.keytab' 2>/dev/null)" || return 1
   for keytab_file in ${keytab_list}; do
      kubectl exec -n "${namespace}" krb5kdc-0 -- cat "${keytab_file}" > "${tmpdir}/$(basename "${keytab_file}")" || return 1
      create_args+=(--from-file="$(basename "${keytab_file}")=${tmpdir}/$(basename "${keytab_file}")")
   done
   kubectl create secret generic kerberos-keytabs -n "${namespace}" \
      "${create_args[@]}" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null || return 1
}
# Add admin-password to an existing secret (clusters created before the admin OS user).
function ensureAdminSecrets(){
   local namespace="$1"
   local admin_password=""
   local existing=""

   ensureSecrets "${namespace}" || return 1
   existing="$(kubectl get secret hive-credentials -n "${namespace}" -o jsonpath='{.data.admin-password}' 2>/dev/null)" || return 1
   if [ -n "${existing}" ]; then
      return 0
   fi
   kubectl patch secret hive-credentials -n "${namespace}" --type merge \
      -p '{"stringData":{"admin-password":"admin"}}' >/dev/null
}
# Add Hue credentials to an existing llap secret (for clusters created before Hue).
function ensureHueSecrets(){
   local namespace="$1"
   local hue_mysql_password=""
   local hue_secret_key=""
   local existing=""

   case "${namespace}" in llap|secure) ;; *) return 0 ;; esac
   ensureSecrets "${namespace}" || return 1
   existing="$(kubectl get secret hive-credentials -n "${namespace}" -o jsonpath='{.data.hue-mysql-password}' 2>/dev/null)" || return 1
   if [ -n "${existing}" ]; then
      return 0
   fi
   hue_mysql_password="$(generatePassword)"
   hue_secret_key="$(generatePassword)"
   kubectl patch secret hive-credentials -n "${namespace}" --type merge \
      -p "{\"stringData\":{\"hue-mysql-password\":\"${hue_mysql_password}\",\"hue-secret-key\":\"${hue_secret_key}\"}}" >/dev/null
}
# Ranger Admin DB + UI passwords (secure profile, opt-in component).
function ensureRangerSecrets(){
   local namespace="$1"
   local ranger_db_password=""
   local ranger_admin_password=""
   local existing=""

   [ "${namespace}" = "secure" ] || return 0
   ensureSecrets "${namespace}" || return 1
   existing="$(kubectl get secret hive-credentials -n "${namespace}" -o jsonpath='{.data.ranger-db-password}' 2>/dev/null)" || return 1
   if [ -z "${existing}" ]; then
      ranger_db_password="$(generatePassword)"
      ranger_admin_password="$(generateRangerPassword)"
      kubectl patch secret hive-credentials -n "${namespace}" --type merge \
         -p "{\"stringData\":{\"ranger-db-password\":\"${ranger_db_password}\",\"ranger-admin-password\":\"${ranger_admin_password}\"}}" >/dev/null
      return 0
   fi
   ranger_admin_password="$(kubectl get secret hive-credentials -n "${namespace}" -o jsonpath='{.data.ranger-admin-password}' 2>/dev/null | base64 -d 2>/dev/null)"
   if rangerPasswordMeetsPolicy "${ranger_admin_password}"; then
      return 0
   fi
   ranger_admin_password="$(generateRangerPassword)"
   echo "Updating ranger-admin-password in hive-credentials (Ranger requires upper+lower+digit)."
   kubectl patch secret hive-credentials -n "${namespace}" --type merge \
      -p "{\"stringData\":{\"ranger-admin-password\":\"${ranger_admin_password}\"}}" >/dev/null
}
# Drop Ranger schema and allow setup.sh to run again (HIVECTL_RANGER_REINIT=1).
function reinitRangerDatabase(){
   local namespace="$1"

   [ "${namespace}" = "secure" ] || return 0
   if ! kubectl get svc mysql -n "${namespace}" >/dev/null 2>&1; then
      return 0
   fi
   echo "Reinitializing Ranger MySQL database (HIVECTL_RANGER_REINIT=1) ..."
   kubectl exec -n "${namespace}" mysql-0 -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP DATABASE IF EXISTS ranger; CREATE DATABASE ranger CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"' || return 1
   if kubectl get pod ranger-0 -n "${namespace}" >/dev/null 2>&1; then
      kubectl exec -n "${namespace}" ranger-0 -c ranger -- rm -f /opt/ranger/.setupDone 2>/dev/null || true
   fi
}
# Wait for ranger-mysql-init Job after first apply.
function waitForRangerMysqlInit(){
   local namespace="$1"

   [ "${namespace}" = "secure" ] || return 0
   if ! kubectl get job ranger-mysql-init -n "${namespace}" >/dev/null 2>&1; then
      return 0
   fi
   kubectl wait --for=condition=complete job/ranger-mysql-init -n "${namespace}" --timeout=300s
}
# Save the generated namespace credentials in a portable backup manifest.
function backupSecrets(){
   local namespace="$1"
   local backup_dir="$2"

   ensureSecrets "${namespace}" || return 1
   kubectl get secret hive-credentials -n "${namespace}" -o json \
   | python3 -c 'import json, sys
obj = json.load(sys.stdin)
obj["metadata"] = {"name": obj["metadata"]["name"], "namespace": obj["metadata"]["namespace"]}
for key in ("creationTimestamp", "resourceVersion", "uid", "managedFields"):
    obj["metadata"].pop(key, None)
print(json.dumps(obj, indent=2))
' > "${backup_dir}/hive-credentials.secret.json"
}
# Restore namespace credentials from a backup when present. MySQL creates its users on first boot and
# the metastore dump doesn't include them, so once MySQL has a volume the current credentials are kept.
function restoreSecrets(){
   local namespace="$1"
   local backup_dir="$2"
   local secret_file="${backup_dir}/hive-credentials.secret.json"
   local names=""

   if [ ! -f "${secret_file}" ]; then
      ensureSecrets "${namespace}"
      return $?
   fi
   ensureNamespace "${namespace}" || return 1
   names="$(kubectlNames pvc mysql-mysql-0 -n "${namespace}")" || return 1
   if [ -n "${names}" ]; then
      ensureSecrets "${namespace}" || return 1
      if ! kubectl get secret hive-credentials -n "${namespace}" -o json \
         | python3 -c 'import json, sys; sys.exit(json.load(sys.stdin)["data"] != json.load(open(sys.argv[1]))["data"])' "${secret_file}"; then
         echo "Keeping the current credentials of '${namespace}': its MySQL users were created with them, and the dump doesn't include users"
      fi
      return 0
   fi
   python3 -c 'import json, sys
obj = json.load(open(sys.argv[1]))
obj["metadata"].pop("namespace", None)
print(json.dumps(obj))
' "${secret_file}" | kubectl apply -n "${namespace}" -f - >/dev/null
}
# List overlay/component pairs discovered from Kustomize files.
function overlays(){
   #
   # Available Overlays
   #
   find ./overlays -name kustomization.yaml -type f -print | awk -F/ 'NF >= 4 {print $3"_"$4}' | sort
}
# Human-readable run state for one overlay workload (StatefulSet or Deployment name = service).
function overlayComponentState(){
   local namespace="$1"
   local service="$2"
   local ready=""
   local desired=""
   local not_ready_pods=""

   if kubectl get statefulset "${service}" -n "${namespace}" >/dev/null 2>&1; then
      desired="$(kubectl get statefulset "${service}" -n "${namespace}" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
      ready="$(kubectl get statefulset "${service}" -n "${namespace}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
   elif kubectl get deployment "${service}" -n "${namespace}" >/dev/null 2>&1; then
      desired="$(kubectl get deployment "${service}" -n "${namespace}" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
      ready="$(kubectl get deployment "${service}" -n "${namespace}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
   else
      echo "deployed (workload missing)"
      return 1
   fi

   ready="${ready:-0}"
   desired="${desired:-0}"

   if [ "${desired}" -eq 0 ]; then
      echo "stopped (0/0)"
      return 1
   fi
   if [ "${ready}" -ge "${desired}" ]; then
      echo "running (${ready}/${desired})"
      return 0
   fi

   not_ready_pods="$(kubectl get pods -n "${namespace}" -l "app=${service}" --field-selector=status.phase!=Running --no-headers 2>/dev/null \
      | awk '$3 ~ /CrashLoopBackOff|Error|Failed|ImagePullBackOff/ {print $3}' | head -1)"
   if [ -n "${not_ready_pods}" ]; then
      echo "failed (${ready}/${desired}, ${not_ready_pods})"
      return 1
   fi
   echo "not ready (${ready}/${desired})"
   return 1
}
# List overlays that currently have an active StatefulSet or Deployment.
function activeOverlays(){
   #
   # Each Overlay lives in it's own Namespace of the same name
   #
   local arg="${1:-}"
   local target=""
   local active_list=""
   local namespace=""
   local service=""
   local state=""
   local status=0

   for target in $(overlays); do
       overlayActive "${target}"
       case $? in
          0) active_list="${active_list}${target}"$'\n' ;;
          2)
             status=1
             break
             ;;
       esac
   done

   if [ -n "${arg}" ]; then
      echo "Active Overlays:"
      printf "  %-28s %s\n" "COMPONENT" "STATE"
      while IFS= read -r target; do
         [ -n "${target}" ] || continue
         namespace="${target%_*}"
         service="${target#*_}"
         state="$(overlayComponentState "${namespace}" "${service}")" || true
         printf "  %-28s %s\n" "${target}" "${state:-unknown}"
      done <<< "${active_list}"
      return "${status}"
   fi
   printf "%s" "${active_list}"
   return "${status}"
}
# Return success when the requested overlay exists in the project.
function overlayExists(){
   #
   # Checks whether the requested overlay exists exactly.
   #
   local target="$1"

   overlays | awk -v target="${target}" '$0 == target {found=1} END {exit !found}'
}
# Return 0 when the requested overlay has a StatefulSet, 1 when it doesn't, 2 when Kubernetes can't be queried.
function overlayActive(){
   local target="$1"
   local names=""

   local namespace="${target%_*}"
   local service="${target#*_}"

   names="$(kubectlNames statefulsets -n "${namespace}" --selector="app=${service}")" || return 2
   if [ -n "${names}" ]; then
      return 0
   fi
   names="$(kubectlNames deployments -n "${namespace}" --selector="app=${service}")" || return 2
   [ -n "${names}" ]
}
# Apply NameNode and three DataNodes together (NameNode startup waits for live DNs).
function startSecureHadoop(){
   local namespace="secure"
   local nn_path="./overlays/secure/hadoop-namenode/"
   local dn_path="./overlays/secure/hadoop-datanode/"

   ensureSecrets "${namespace}" || return 1
   ensureAdminSecrets "${namespace}" || return 1
   ensureKerberosKeytabSecret "${namespace}" || return 1
   echo "Starting Overlay: secure_hadoop (namenode + 3 datanodes) ..."
   kustomize build "${nn_path}" --load-restrictor LoadRestrictionsNone | kubectl apply -f - || return 1
   kustomize build "${dn_path}" --load-restrictor LoadRestrictionsNone | kubectl apply -f - || return 1
   waitForReady "${namespace}" "hadoop-datanode" || return 1
   waitForReady "${namespace}" "hadoop-namenode" || return 1
}
function stopSecureHadoop(){
   local namespace="secure"
   local resources=""
   local resource=""

   echo "Stopping Overlay: secure_hadoop (datanodes + namenode) ..."
   for app in hadoop-datanode hadoop-namenode; do
      resources="$(kubectlNames sts,deploy,pods,cm,svc -n "${namespace}" --selector="app=${app}")" || return 1
      for resource in ${resources}; do
         kubectl delete "${resource}" -n "${namespace}" --wait=false || return 1
      done
      waitForStopped "${namespace}" "${app}"
   done
}
function profileHasHue(){
   case "${1:-}" in
      llap|secure) return 0 ;;
      *) return 1 ;;
   esac
}
# Wait until every replica of a component StatefulSet or Deployment reports Ready.
function waitForReady(){
   local namespace="$1"
   local service="$2"

   local rollout_timeout="600s"
   if [ "${service}" = "hadoop-namenode" ] || [ "${service}" = "ranger" ]; then
      rollout_timeout="1200s"
   fi
   if kubectl get statefulset "${service}" -n "${namespace}" >/dev/null 2>&1; then
      kubectl rollout status "statefulset/${service}" -n "${namespace}" --timeout="${rollout_timeout}"
   else
      kubectl rollout status "deployment/${service}" -n "${namespace}" --timeout=600s
   fi
}
# Wait until none of the objects selected by the kubectl get arguments exist.
function waitForDeleted(){
   local timeout="$1"
   local deadline=$((SECONDS + timeout))
   local remaining=""
   shift

   while remaining="$(kubectlNames "$@")"; do
      if [ -z "${remaining}" ]; then
         return 0
      fi
      if [ "${SECONDS}" -ge "${deadline}" ]; then
         echo "Timed out after ${timeout}s waiting for the deletion of: $(echo "${remaining}" | paste -sd' ' -)"
         return 1
      fi
      sleep 2
   done
   return 1
}
# Wait until a component StatefulSet and all of its pods are deleted.
function waitForStopped(){
   local namespace="$1"
   local service="$2"

   waitForDeleted 180 statefulsets,deployments,pods -n "${namespace}" --selector="app=${service}"
}
# secure HS2: default overlay or Phase 2 Ranger authorizer (HIVECTL_SECURE_RANGER_HS2=1).
function secureHiveserver2OverlayPath(){
   if [ "${HIVECTL_SECURE_RANGER_HS2:-0}" = "1" ]; then
      echo "./overlays/secure/hiveserver2-ranger/"
   else
      echo "./overlays/secure/hiveserver2/"
   fi
}
function applyOverlayKustomize(){
   local overlay_path="$1"
   local manifest=""
   local ranger_image=""

   manifest="$(kustomize build "${overlay_path}" --load-restrictor LoadRestrictionsNone)" || return 1
   if [[ "${overlay_path}" == *hiveserver2-ranger* ]]; then
      ranger_image="${HIVE_RANGER_IMAGE:-hive-on-k8s/hive-ranger:2.4.0-nightly}"
      manifest="$(printf '%s\n' "${manifest}" | sed "s|image: hive-on-k8s/hive-ranger:2.4.0-nightly|image: ${ranger_image}|g")"
   fi
   printf '%s\n' "${manifest}" | kubectl apply -f -
}
# Start one overlay/component and wait for its pod readiness.
function startOverlay(){
   #
   # Expects an argument: overlay_<component>
   # Ex: mini_hadoop mini_hivemetastore, mini_hiveserver2, etc
   #
   local target="$1"
   local overlay_path="./overlays/${target//_//}/"
   local namespace="${target%_*}"
   local service="${target#*_}"

   if [ "${target}" = "secure_hiveserver2" ]; then
      overlay_path="$(secureHiveserver2OverlayPath)"
      if [ "${HIVECTL_SECURE_RANGER_HS2:-0}" = "1" ]; then
         echo "HS2 overlay: Ranger Hive plugin (Phase 2); image ${HIVE_RANGER_IMAGE:-hive-on-k8s/hive-ranger:2.4.0-nightly}"
      fi
   fi

   ensureClusterDiskSpaceOnce

   if [ "${target}" = "secure_hiveserver2" ]; then
      ensureSecureRangerHs2KindImage || return 1
   fi

   if [ "${target}" = "secure_hadoop-namenode" ]; then
      overlayActive "secure_hadoop-namenode"
      case $? in
         0)
            echo "Overlay: secure_hadoop is already ACTIVE, try stopping/restarting it"
            waitForReady "${namespace}" "hadoop-datanode"
            waitForReady "${namespace}" "hadoop-namenode"
            ;;
         1) startSecureHadoop || return 1 ;;
         *) return 1 ;;
      esac
      return 0
   fi
   if [ "${target}" = "secure_hadoop-datanode" ]; then
      echo "Overlay: secure_hadoop-datanode is started with secure_hadoop-namenode (use: hiveCtl start secure hadoop-namenode)"
      return 0
   fi

   overlayActive "${target}"
   case $? in
      0)
         echo "Overlay: ${target} is already ACTIVE, try stopping/restarting it"
         ensureSecrets "${namespace}" || return 1
         ensureAdminSecrets "${namespace}" || return 1
         if [ "${namespace}" = "secure" ] && [ "${service}" = "krb5kdc" ]; then
            ensureKrb5Secrets "${namespace}" || return 1
         fi
         if profileHasHue "${namespace}" && [ "${service}" = "hue" ]; then
            ensureHueSecrets "${namespace}" || return 1
         fi
         if [ "${namespace}" = "secure" ] && [ "${service}" = "ranger" ]; then
            ensureRangerSecrets "${namespace}" || return 1
            if [ "${HIVECTL_RANGER_REINIT:-0}" = "1" ]; then
               reinitRangerDatabase "${namespace}" || return 1
            fi
         fi
         waitForReady "${namespace}" "${service}"
         if [ "${namespace}" = "secure" ] && [ "${service}" = "krb5kdc" ]; then
            ensureKerberosKeytabSecret "${namespace}" || return 1
         fi
         ;;
      1)
         if overlayExists "${target}"; then
            echo "Starting Overlay: ${target} ..."
            ensureSecrets "${namespace}" || return 1
            ensureAdminSecrets "${namespace}" || return 1
            if [ "${namespace}" = "secure" ] && [ "${service}" = "krb5kdc" ]; then
               ensureKrb5Secrets "${namespace}" || return 1
            fi
            if [ "${namespace}" = "secure" ]; then
               case "${service}" in
                  krb5kdc)
                     ;;
                  hadoop-namenode|hadoop-datanode|hivemetastore|hiveserver2|llapdaemon)
                     ensureKerberosKeytabSecret "${namespace}" || return 1
                     ;;
               esac
            fi
            if profileHasHue "${namespace}" && [ "${service}" = "hue" ]; then
               ensureHueSecrets "${namespace}" || return 1
            fi
            if [ "${namespace}" = "secure" ] && [ "${service}" = "ranger" ]; then
               ensureRangerSecrets "${namespace}" || return 1
               if [ "${HIVECTL_RANGER_REINIT:-0}" = "1" ]; then
                  reinitRangerDatabase "${namespace}" || return 1
               fi
            fi
            applyOverlayKustomize "${overlay_path}" || return 1
            if [ "${namespace}" = "secure" ] && [ "${service}" = "ranger" ]; then
               waitForRangerMysqlInit "${namespace}" || return 1
            fi
            waitForReady "${namespace}" "${service}"
            if [ "${namespace}" = "secure" ] && [ "${service}" = "krb5kdc" ]; then
               ensureKerberosKeytabSecret "${namespace}" || return 1
            fi
         else
            echo "Overlay: ${target} DOES NOT EXIST"
         fi
         ;;
      *)
         return 1
         ;;
   esac

   if profileHasHue "${namespace}" && [ "${service}" = "hue" ]; then
      ensureHuePortForward "${namespace}" || true
   fi
   if [ "${namespace}" = "secure" ] && [ "${service}" = "ranger" ]; then
      ensureRangerPortForward "${namespace}" || true
   fi
   if [ "${namespace}" = "secure" ] && [ "${service}" = "hiveserver2" ]; then
      ensureSecureRangerHiveBootstrap "${namespace}" || true
   fi
   if [ "${service}" = "llapdaemon" ]; then
      case "${namespace}" in llap|secure) ensureLlapDaemonPortForward "${namespace}" || true ;; esac
   fi
}
# Stop one overlay/component while preserving PVCs.
function stopOverlay(){
   #
   # Expects an argument: overlay_<component>
   # Ex: mini_hivemetastore, mini_hiveserver2, etc
   #
   local target="$1"
   local namespace="${target%_*}"
   local service="${target#*_}"
   local resources=""
   local resource=""

   if [ "${target}" = "secure_hadoop-datanode" ]; then
      echo "Overlay: secure_hadoop-datanode stops with secure_hadoop-namenode (use: hiveCtl stop secure hadoop-namenode)"
      return 0
   fi
   if [ "${target}" = "secure_hadoop-namenode" ]; then
      stopSecureHadoop
      return $?
   fi

   overlayActive "${target}"
   case $? in
      0) ;;
      1)
         echo "Overlay: ${target} is already STOPPED or DOES NOT EXIST"
         return 0
         ;;
      *)
         return 1
         ;;
   esac

   echo "Stopping Overlay: ${target} ..."
   if profileHasHue "${namespace}" && [ "${service}" = "hue" ]; then
      stopHuePortForward "${namespace}"
   fi
   if [ "${service}" = "llapdaemon" ]; then
      case "${namespace}" in llap|secure) stopLlapDaemonPortForward "${namespace}" ;; esac
   fi
   if [ "${service}" = "ranger" ]; then
      stopRangerPortForward "${namespace}"
      kubectl delete job ranger-mysql-init -n "${namespace}" --ignore-not-found --wait=false || return 1
   fi
   resources="$(kubectlNames sts,deploy,pods,cm,svc -n "${namespace}" --selector="app=${service}")" || return 1
   # Not forced: each pod gets its termination grace period to shut its services down cleanly
   for resource in ${resources}; do
      kubectl delete "${resource}" -n "${namespace}" --wait=false || return 1
   done
   waitForStopped "${namespace}" "${service}"
}
# State under repo .hivectl/ (port-forward pid for Hue).
function hiveCtlStateDir(){
   local root=""
   root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
   echo "${HIVECTL_STATE_DIR:-${root}/.hivectl}"
}
function huePortForwardPidFile(){
   local namespace="${1:-llap}"
   echo "$(hiveCtlStateDir)/${namespace}-hue-portforward.pid"
}
function huePortForwardMonitorPidFile(){
   local namespace="${1:-llap}"
   echo "$(hiveCtlStateDir)/${namespace}-hue-portforward-monitor.pid"
}
function hueLocalPort(){
   echo "${HIVECTL_HUE_LOCAL_PORT:-8888}"
}
function huePortForwardDisabled(){
   case "${HIVECTL_HUE_PORT_FORWARD:-auto}" in
      0|false|no|off|disable|disabled) return 0 ;;
      *) return 1 ;;
   esac
}
function huePortForwardMonitorDisabled(){
   case "${HIVECTL_HUE_PORT_FORWARD_MONITOR:-1}" in
      0|false|no|off|disable|disabled) return 0 ;;
      *) return 1 ;;
   esac
}
# True when hue-0 exists and its Ready condition is True.
function huePodRunningAndReady(){
   local namespace="${1:-${HIVECTL_HUE_NAMESPACE:-llap}}"
   local phase=""
   local ready=""

   phase="$(kubectl get pod hue-0 -n "${namespace}" -o jsonpath='{.status.phase}' 2>/dev/null)" || return 1
   [ "${phase}" = "Running" ] || return 1
   ready="$(kubectl get pod hue-0 -n "${namespace}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" || return 1
   [ "${ready}" = "True" ] || return 1
}
# True when Hue responds on localhost (kind mapping or port-forward).
function hueLocalUrlReachable(){
   local port="$1"
   local code=""
   local attempt=0

   [ -n "${port}" ] || return 1
   command -v curl >/dev/null 2>&1 || return 1
   while [ "${attempt}" -lt 3 ]; do
      code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/hue/accounts/login" --connect-timeout 3 --max-time 8 2>/dev/null || echo 000)"
      case "${code}" in
         200|301|302|303|401|403|404) return 0 ;;
      esac
      attempt=$((attempt + 1))
      sleep 1
   done
   return 1
}
function huePortForwardProcessAlive(){
   local namespace="$1"
   local pidfile=""
   local pid=""

   pidfile="$(huePortForwardPidFile "${namespace}")"
   [ -f "${pidfile}" ] || return 1
   pid="$(cat "${pidfile}")"
   [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null
}
function stopHuePortForwardMonitor(){
   local namespace="${1:-llap}"
   local pidfile=""
   local pid=""

   pidfile="$(huePortForwardMonitorPidFile "${namespace}")"
   [ -f "${pidfile}" ] || return 0
   pid="$(cat "${pidfile}")"
   if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
   fi
   rm -f "${pidfile}"
}
# Start kubectl port-forward to svc/hue (replaces a stale forward when localhost is down).
function startHuePortForwardProcess(){
   local namespace="${1:-${HIVECTL_HUE_NAMESPACE:-llap}}"
   local port=""
   local pidfile=""
   local pid=""

   port="$(hueLocalPort)"
   pidfile="$(huePortForwardPidFile "${namespace}")"
   mkdir -p "$(hiveCtlStateDir)"

   if huePortForwardProcessAlive "${namespace}"; then
      if hueLocalUrlReachable "${port}"; then
         return 0
      fi
      pid="$(cat "${pidfile}")"
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
      rm -f "${pidfile}"
   fi

   nohup kubectl port-forward "svc/hue" -n "${namespace}" "${port}:8888" >/dev/null 2>&1 &
   pid=$!
   echo "${pid}" > "${pidfile}"
   sleep 1
   if kill -0 "${pid}" 2>/dev/null; then
      return 0
   fi
   rm -f "${pidfile}"
   return 1
}
# Internal loop: invoked via hiveCtl __hue-portforward-monitor (nohup background).
function huePortForwardMonitorLoop(){
   local namespace="${HIVECTL_HUE_NAMESPACE:-llap}"
   local interval=""
   local port=""

   interval="${HIVECTL_HUE_PORT_FORWARD_MONITOR_INTERVAL:-60}"
   while true; do
      sleep "${interval}"
      if huePortForwardDisabled; then
         exit 0
      fi
      if huePortForwardMonitorDisabled; then
         exit 0
      fi
      if ! kubectl get svc hue -n "${namespace}" >/dev/null 2>&1; then
         continue
      fi
      if ! huePodRunningAndReady "${namespace}"; then
         continue
      fi
      port="$(hueLocalPort)"
      if huePortForwardProcessAlive "${namespace}" && hueLocalUrlReachable "${port}"; then
         continue
      fi
      if huePortForwardProcessAlive "${namespace}" && ! hueLocalUrlReachable "${port}"; then
         sleep 5
         if hueLocalUrlReachable "${port}"; then
            continue
         fi
      fi
      echo "[hiveCtl] Hue http://127.0.0.1:${port}/ unreachable while hue-0 is Ready; restarting port-forward" >&2
      if startHuePortForwardProcess "${namespace}"; then
         echo "[hiveCtl] Hue port-forward restarted (pid $(cat "$(huePortForwardPidFile "${namespace}")" 2>/dev/null))" >&2
      else
         echo "[hiveCtl] Warning: could not restart Hue port-forward to localhost:${port}" >&2
      fi
   done
}
function startHuePortForwardMonitor(){
   local namespace="${1:-llap}"
   local monitor_pidfile=""
   local logfile=""
   local hivectl=""
   local pid=""

   if huePortForwardDisabled || huePortForwardMonitorDisabled; then
      return 0
   fi
   if ! kubectl get svc hue -n "${namespace}" >/dev/null 2>&1; then
      return 0
   fi

   monitor_pidfile="$(huePortForwardMonitorPidFile "${namespace}")"
   if [ -f "${monitor_pidfile}" ]; then
      pid="$(cat "${monitor_pidfile}")"
      if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
         return 0
      fi
      rm -f "${monitor_pidfile}"
   fi

   mkdir -p "$(hiveCtlStateDir)"
   logfile="$(hiveCtlStateDir)/${namespace}-hue-portforward-monitor.log"
   hivectl="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
   nohup env HIVECTL_STATE_DIR="$(hiveCtlStateDir)" \
      HIVECTL_HUE_NAMESPACE="${namespace}" \
      HIVECTL_HUE_LOCAL_PORT="$(hueLocalPort)" \
      HIVECTL_HUE_PORT_FORWARD="${HIVECTL_HUE_PORT_FORWARD:-auto}" \
      HIVECTL_HUE_PORT_FORWARD_MONITOR="${HIVECTL_HUE_PORT_FORWARD_MONITOR:-1}" \
      HIVECTL_HUE_PORT_FORWARD_MONITOR_INTERVAL="${HIVECTL_HUE_PORT_FORWARD_MONITOR_INTERVAL:-60}" \
      bash "${hivectl}" __hue-portforward-monitor >>"${logfile}" 2>&1 &
   pid=$!
   echo "${pid}" > "${monitor_pidfile}"
}
# Stop background kubectl port-forward and its monitor.
function stopHuePortForward(){
   local namespace="${1:-llap}"
   local pidfile=""
   local pid=""

   stopHuePortForwardMonitor "${namespace}"
   pidfile="$(huePortForwardPidFile "${namespace}")"
   [ -f "${pidfile}" ] || return 0
   pid="$(cat "${pidfile}")"
   if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
   fi
   rm -f "${pidfile}"
}
# Expose Hue on localhost after hue is up (skipped when HIVECTL_HUE_PORT_FORWARD=0).
function ensureHuePortForward(){
   local namespace="${1:-llap}"
   local port=""
   local pidfile=""
   local pid=""

   if huePortForwardDisabled; then
      stopHuePortForward "${namespace}"
      echo "Hue port-forward disabled (HIVECTL_HUE_PORT_FORWARD=${HIVECTL_HUE_PORT_FORWARD})"
      return 0
   fi

   if ! kubectl get svc hue -n "${namespace}" >/dev/null 2>&1; then
      return 0
   fi

   port="$(hueLocalPort)"
   pidfile="$(huePortForwardPidFile "${namespace}")"
   mkdir -p "$(hiveCtlStateDir)"

   if huePortForwardProcessAlive "${namespace}" && hueLocalUrlReachable "${port}"; then
      pid="$(cat "${pidfile}")"
      echo "Hue UI (${namespace}): http://127.0.0.1:${port}/hue/accounts/login (port-forward pid ${pid})"
      startHuePortForwardMonitor "${namespace}" || true
      return 0
   fi

   if startHuePortForwardProcess "${namespace}"; then
      pid="$(cat "${pidfile}")"
      echo "Hue UI (${namespace}): http://127.0.0.1:${port}/hue/accounts/login (hiveCtl port-forward pid ${pid}; stops on './hiveCtl.sh stop ${namespace} hue')"
      startHuePortForwardMonitor "${namespace}" || true
      return 0
   fi
   echo "Warning: could not bind localhost:${port} for Hue. Try: kubectl port-forward svc/hue -n ${namespace} ${port}:8888" >&2
   startHuePortForwardMonitor "${namespace}" || true
   return 1
}
function rangerPortForwardPidFile(){
   local namespace="${1:-secure}"
   echo "$(hiveCtlStateDir)/${namespace}-ranger-portforward.pid"
}
function rangerPortForwardMonitorPidFile(){
   local namespace="${1:-secure}"
   echo "$(hiveCtlStateDir)/${namespace}-ranger-portforward-monitor.pid"
}
function rangerLocalPort(){
   echo "${HIVECTL_RANGER_LOCAL_PORT:-6080}"
}
function rangerPortForwardDisabled(){
   case "${HIVECTL_RANGER_PORT_FORWARD:-auto}" in
      0|false|no|off|disable|disabled) return 0 ;;
      *) return 1 ;;
   esac
}
function rangerPortForwardMonitorDisabled(){
   case "${HIVECTL_RANGER_PORT_FORWARD_MONITOR:-1}" in
      0|false|no|off|disable|disabled) return 0 ;;
      *) return 1 ;;
   esac
}
function rangerPodRunningAndReady(){
   local namespace="${1:-secure}"
   local phase=""
   local ready=""

   phase="$(kubectl get pod ranger-0 -n "${namespace}" -o jsonpath='{.status.phase}' 2>/dev/null)" || return 1
   [ "${phase}" = "Running" ] || return 1
   ready="$(kubectl get pod ranger-0 -n "${namespace}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" || return 1
   [ "${ready}" = "True" ] || return 1
}
function rangerLocalUrlReachable(){
   local port="$1"
   local code=""

   [ -n "${port}" ] || return 1
   command -v curl >/dev/null 2>&1 || return 1
   code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/login.jsp" --connect-timeout 2 2>/dev/null || echo 000)"
   case "${code}" in
      200|301|302|303|401|403|404) return 0 ;;
      *) return 1 ;;
   esac
}
function stopRangerPortForwardMonitor(){
   local namespace="${1:-secure}"
   local pidfile=""
   local pid=""

   pidfile="$(rangerPortForwardMonitorPidFile "${namespace}")"
   [ -f "${pidfile}" ] || return 0
   pid="$(cat "${pidfile}")"
   if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
   fi
   rm -f "${pidfile}"
}
function startRangerPortForwardProcess(){
   local namespace="${1:-secure}"
   local port=""
   local pidfile=""
   local pid=""

   port="$(rangerLocalPort)"
   pidfile="$(rangerPortForwardPidFile "${namespace}")"
   mkdir -p "$(hiveCtlStateDir)"

   if [ -f "${pidfile}" ]; then
      pid="$(cat "${pidfile}")"
      if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
         if rangerLocalUrlReachable "${port}"; then
            return 0
         fi
         kill "${pid}" 2>/dev/null || true
         wait "${pid}" 2>/dev/null || true
      fi
      rm -f "${pidfile}"
   fi

   nohup kubectl port-forward "svc/ranger" -n "${namespace}" "${port}:6080" >/dev/null 2>&1 &
   pid=$!
   echo "${pid}" > "${pidfile}"
   sleep 1
   if kill -0 "${pid}" 2>/dev/null; then
      return 0
   fi
   rm -f "${pidfile}"
   return 1
}
function rangerPortForwardMonitorLoop(){
   local namespace="${HIVECTL_RANGER_NAMESPACE:-secure}"
   local interval=""
   local port=""

   interval="${HIVECTL_RANGER_PORT_FORWARD_MONITOR_INTERVAL:-60}"
   while true; do
      sleep "${interval}"
      if rangerPortForwardDisabled; then
         exit 0
      fi
      if rangerPortForwardMonitorDisabled; then
         exit 0
      fi
      if ! kubectl get svc ranger -n "${namespace}" >/dev/null 2>&1; then
         continue
      fi
      if ! rangerPodRunningAndReady "${namespace}"; then
         continue
      fi
      port="$(rangerLocalPort)"
      if rangerLocalUrlReachable "${port}"; then
         continue
      fi
      echo "[hiveCtl] Ranger http://127.0.0.1:${port}/login.jsp unreachable while ranger-0 is Ready; restarting port-forward" >&2
      if startRangerPortForwardProcess "${namespace}"; then
         echo "[hiveCtl] Ranger port-forward restarted (pid $(cat "$(rangerPortForwardPidFile "${namespace}")" 2>/dev/null))" >&2
      else
         echo "[hiveCtl] Warning: could not restart Ranger port-forward to localhost:${port}" >&2
      fi
   done
}
function startRangerPortForwardMonitor(){
   local namespace="${1:-secure}"
   local monitor_pidfile=""
   local logfile=""
   local hivectl=""
   local pid=""

   if rangerPortForwardDisabled || rangerPortForwardMonitorDisabled; then
      return 0
   fi
   if ! kubectl get svc ranger -n "${namespace}" >/dev/null 2>&1; then
      return 0
   fi

   monitor_pidfile="$(rangerPortForwardMonitorPidFile "${namespace}")"
   if [ -f "${monitor_pidfile}" ]; then
      pid="$(cat "${monitor_pidfile}")"
      if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
         return 0
      fi
      rm -f "${monitor_pidfile}"
   fi

   mkdir -p "$(hiveCtlStateDir)"
   logfile="$(hiveCtlStateDir)/${namespace}-ranger-portforward-monitor.log"
   hivectl="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
   nohup env HIVECTL_STATE_DIR="$(hiveCtlStateDir)" \
      HIVECTL_RANGER_NAMESPACE="${namespace}" \
      HIVECTL_RANGER_LOCAL_PORT="$(rangerLocalPort)" \
      HIVECTL_RANGER_PORT_FORWARD="${HIVECTL_RANGER_PORT_FORWARD:-auto}" \
      HIVECTL_RANGER_PORT_FORWARD_MONITOR="${HIVECTL_RANGER_PORT_FORWARD_MONITOR:-1}" \
      HIVECTL_RANGER_PORT_FORWARD_MONITOR_INTERVAL="${HIVECTL_RANGER_PORT_FORWARD_MONITOR_INTERVAL:-60}" \
      bash "${hivectl}" __ranger-portforward-monitor >>"${logfile}" 2>&1 &
   pid=$!
   echo "${pid}" > "${monitor_pidfile}"
}
function stopRangerPortForward(){
   local namespace="${1:-secure}"
   local pidfile=""
   local pid=""

   stopRangerPortForwardMonitor "${namespace}"
   pidfile="$(rangerPortForwardPidFile "${namespace}")"
   [ -f "${pidfile}" ] || return 0
   pid="$(cat "${pidfile}")"
   if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
   fi
   rm -f "${pidfile}"
}
function rangerAdminPasswordHint(){
   local namespace="${1:-secure}"
   echo "Ranger login user: admin   password: kubectl get secret hive-credentials -n ${namespace} -o jsonpath='{.data.ranger-admin-password}' | base64 -d; echo"
}
# True when automatic secure_hive + admin policy bootstrap should be skipped.
function secureRangerHiveBootstrapDisabled(){
   case "${HIVECTL_SECURE_RANGER_BOOTSTRAP_HIVE:-auto}" in
      0|false|no|off|disable|disabled) return 0 ;;
      auto)
         [ "${HIVECTL_SECURE_RANGER_HS2:-0}" = "1" ] || return 0
         return 1
         ;;
      *) return 1 ;;
   esac
}
# Create secure_hive in Ranger and apply scripts/secure-ranger-admin-default-and-owner.sh (idempotent).
function ensureSecureRangerHiveBootstrap(){
   local namespace="${1:-secure}"
   local bootstrap_script="${HIVECTL_ROOT}/scripts/secure-ranger-bootstrap-hive.sh"

   [ "${namespace}" = "secure" ] || return 0
   if secureRangerHiveBootstrapDisabled; then
      return 0
   fi
   overlayActive "secure_ranger" || return 0
   rangerPodRunningAndReady "${namespace}" || return 0
   if [ ! -x "${bootstrap_script}" ]; then
      echo "Warning: missing ${bootstrap_script}; skip Ranger Hive bootstrap"
      return 0
   fi
   echo "Ranger Hive bootstrap: secure_hive service + lab admin policies ..."
   if ! "${bootstrap_script}" "${namespace}"; then
      echo "Warning: Ranger Hive bootstrap failed (HS2 auth may deny until secure_hive exists in Admin)"
      return 1
   fi
   echo "Ranger Hive bootstrap done (HS2 plugin poll ~30s; restart HS2 if policies seem stale)"
   return 0
}
function ensureRangerPortForward(){
   local namespace="${1:-secure}"
   local port=""
   local pidfile=""
   local pid=""

   if rangerPortForwardDisabled; then
      stopRangerPortForward "${namespace}"
      echo "Ranger port-forward disabled (HIVECTL_RANGER_PORT_FORWARD=${HIVECTL_RANGER_PORT_FORWARD})"
      return 0
   fi

   if ! kubectl get svc ranger -n "${namespace}" >/dev/null 2>&1; then
      return 0
   fi

   port="$(rangerLocalPort)"
   pidfile="$(rangerPortForwardPidFile "${namespace}")"
   mkdir -p "$(hiveCtlStateDir)"

   if rangerLocalUrlReachable "${port}"; then
      if [ -f "${pidfile}" ]; then
         pid="$(cat "${pidfile}")"
         if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
            echo "Ranger Admin (${namespace}): http://localhost:${port}/login.jsp (port-forward pid ${pid})"
         else
            echo "Ranger Admin (${namespace}): http://localhost:${port}/login.jsp (already reachable; not starting port-forward)"
         fi
      else
         echo "Ranger Admin (${namespace}): http://localhost:${port}/login.jsp (already reachable; not starting port-forward)"
      fi
      rangerAdminPasswordHint "${namespace}"
      startRangerPortForwardMonitor "${namespace}" || true
      return 0
   fi

   if startRangerPortForwardProcess "${namespace}"; then
      pid="$(cat "${pidfile}")"
      echo "Ranger Admin (${namespace}): http://localhost:${port}/login.jsp (hiveCtl port-forward pid ${pid}; stops on './hiveCtl.sh stop ${namespace} ranger')"
      rangerAdminPasswordHint "${namespace}"
      startRangerPortForwardMonitor "${namespace}" || true
      return 0
   fi
   echo "Warning: could not bind localhost:${port} for Ranger. Try: kubectl port-forward svc/ranger -n ${namespace} ${port}:6080" >&2
   rangerAdminPasswordHint "${namespace}"
   startRangerPortForwardMonitor "${namespace}" || true
   return 1
}
function llapDaemonPortForwardPidFile(){
   local namespace="${1:-llap}"
   echo "$(hiveCtlStateDir)/${namespace}-llap-daemon-portforward.pid"
}
function llapDaemonLocalPort(){
   echo "${HIVECTL_LLAP_DAEMON_LOCAL_PORT:-15002}"
}
function stopLlapDaemonPortForward(){
   local namespace="${1:-llap}"
   local pidfile=""
   local pid=""

   pidfile="$(llapDaemonPortForwardPidFile "${namespace}")"
   [ -f "${pidfile}" ] || return 0
   pid="$(cat "${pidfile}")"
   if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
   fi
   rm -f "${pidfile}"
}
# Expose llapdaemon-0 web UI on localhost:15002 (HIVECTL_LLAP_DAEMON_PORT_FORWARD=0 to disable).
function ensureLlapDaemonPortForward(){
   local namespace="${1:-llap}"
   local port=""
   local mode=""
   local pidfile=""
   local pid=""
   local code=""

   mode="${HIVECTL_LLAP_DAEMON_PORT_FORWARD:-auto}"
   case "${mode}" in
      0|false|no|off|disable|disabled)
         echo "LLAP daemon UI port-forward disabled (HIVECTL_LLAP_DAEMON_PORT_FORWARD=${mode})"
         return 0
         ;;
   esac

   if ! kubectl get pod llapdaemon-0 -n "${namespace}" >/dev/null 2>&1; then
      return 0
   fi

   port="$(llapDaemonLocalPort)"
   pidfile="$(llapDaemonPortForwardPidFile "${namespace}")"
   mkdir -p "$(hiveCtlStateDir)"

   if [ -f "${pidfile}" ]; then
      pid="$(cat "${pidfile}")"
      if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
         echo "LLAP daemon UI (${namespace}): http://localhost:${port}/ (llapdaemon-0 port-forward pid ${pid})"
         return 0
      fi
      rm -f "${pidfile}"
   fi

   if command -v curl >/dev/null 2>&1; then
      code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/" --connect-timeout 2 2>/dev/null || echo 000)"
      case "${code}" in
         200|301|302|303|401|403|404)
            echo "LLAP daemon UI: http://localhost:${port}/ (already reachable; not starting port-forward)"
            return 0
            ;;
      esac
   fi

   if command -v lsof >/dev/null 2>&1 && lsof -iTCP:"${port}" -sTCP:LISTEN -t >/dev/null 2>&1; then
      echo "LLAP daemon UI: http://localhost:${port}/ (port ${port} in use — manual port-forward?)"
      return 0
   fi

   nohup kubectl port-forward "pod/llapdaemon-0" -n "${namespace}" "${port}:15002" >/dev/null 2>&1 &
   pid=$!
   echo "${pid}" > "${pidfile}"
   sleep 1
   if kill -0 "${pid}" 2>/dev/null; then
      echo "LLAP daemon UI (${namespace}): http://localhost:${port}/ (llapdaemon-0; pid ${pid}; stops on './hiveCtl.sh stop ${namespace} llapdaemon' or 'stop ${namespace}')"
      return 0
   fi
   rm -f "${pidfile}"
   echo "Warning: could not bind localhost:${port} for LLAP daemon UI. Try: kubectl port-forward pod/llapdaemon-0 -n ${namespace} ${port}:15002" >&2
   return 1
}
# Summarize node CPU arch for llap (Hive pods auto-tune hive.llap.io.enabled at bootstrap).
function llapNodeArchSummary(){
   local archs=""

   archs="$(kubectl get nodes -l node-role.kubernetes.io/llap -o jsonpath='{range .items[*]}{.status.nodeInfo.architecture}{" "}{end}' 2>/dev/null | xargs echo)"
   if [ -z "${archs}" ]; then
      archs="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.architecture}{" "}{end}' 2>/dev/null | xargs echo)"
   fi
   if [ -n "${archs}" ]; then
      echo "LLAP worker node architecture(s): ${archs} (hive.llap.io.enabled is set per pod via hadoop checknative in staging.sh)"
   fi
}
# Percent of /var used on a Kind node container (empty when unknown).
function kindNodeVarUsePercent(){
   local node="$1"

   docker exec "${node}" df -P /var 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}'
}
function pruneKindNodeImages(){
   local node="$1"

   docker exec "${node}" crictl rmi --prune 2>/dev/null
}
# Kind cluster name for "kind load" (Docker Desktop cluster is often "desktop", not "kind").
function kindClusterName(){
   local name="${HIVECTL_KIND_CLUSTER_NAME:-${KIND_CLUSTER:-}}"
   local node=""
   local clusters=""

   if [ -n "${name}" ]; then
      printf '%s\n' "${name}"
      return 0
   fi
   if command -v kind >/dev/null 2>&1; then
      clusters="$(kind get clusters 2>/dev/null || true)"
      if [ "$(printf '%s\n' "${clusters}" | sed '/^$/d' | wc -l | tr -d ' ')" = "1" ]; then
         printf '%s\n' "${clusters}" | sed '/^$/d' | head -1
         return 0
      fi
   fi
   node="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" || return 1
   case "${node}" in
      *-control-plane)
         printf '%s\n' "${node%-control-plane}"
         return 0
         ;;
   esac
   return 1
}
# Copy a locally built image into every Kind node (avoids docker.io pull for custom tags).
function ensureKindLocalImage(){
   local image="$1"
   local cluster=""

   case "${HIVECTL_KIND_LOAD:-1}" in
      0|false|no|off|disable|disabled) return 0 ;;
   esac
   command -v docker >/dev/null 2>&1 || return 0
   command -v kind >/dev/null 2>&1 || return 0
   if ! docker image inspect "${image}" >/dev/null 2>&1; then
      echo "hiveCtl: local Docker image not found: ${image}" >&2
      echo "hiveCtl: build it first (see docker/hive-ranger/README.md), or set HIVE_RANGER_IMAGE to a pullable tag." >&2
      return 1
   fi
   cluster="$(kindClusterName)" || {
      echo "hiveCtl: skip kind load for ${image} (Kind cluster name unknown; set HIVECTL_KIND_CLUSTER_NAME)" >&2
      return 0
   }
   echo "hiveCtl: kind load docker-image ${image} --name ${cluster}"
   kind load docker-image "${image}" --name "${cluster}" || return 1
}
function ensureSecureRangerHs2KindImage(){
   [ "${HIVECTL_SECURE_RANGER_HS2:-0}" = "1" ] || return 0
   ensureKindLocalImage "${HIVE_RANGER_IMAGE:-hive-on-k8s/hive-ranger:2.4.0-nightly}"
}
function reportKindNodeDisk(){
   local node="$1"
   local use=""

   use="$(kindNodeVarUsePercent "${node}")"
   [ -n "${use}" ] || return 1
   echo "${node} /var ${use}% used"
}
# Prune unused containerd images on Kind nodes when /var is nearly full (avoids ImagePullBackOff).
function ensureClusterDiskSpace(){
   local max_use=""
   local node=""
   local use=""
   local use_after=""

   case "${HIVECTL_DISK_CHECK:-1}" in
      0|false|no|off|disable|disabled) return 0 ;;
   esac
   command -v docker >/dev/null 2>&1 || return 0
   kubectl get nodes >/dev/null 2>&1 || return 0

   max_use="${HIVECTL_DISK_MAX_USE_PERCENT:-90}"

   while read -r node; do
      [ -n "${node}" ] || continue
      docker inspect "${node}" >/dev/null 2>&1 || continue
      use="$(kindNodeVarUsePercent "${node}")"
      [ -n "${use}" ] || continue
      if [ "${use}" -lt "${max_use}" ]; then
         continue
      fi
      echo "hiveCtl: ${node} /var is ${use}% full (threshold ${max_use}%) — pruning unused container images ..."
      pruneKindNodeImages "${node}"
      use_after="$(kindNodeVarUsePercent "${node}")"
      if [ -n "${use_after}" ]; then
         echo "hiveCtl: ${node} /var now ${use_after}% used"
      fi
      if [ -n "${use_after}" ] && [ "${use_after}" -ge 98 ]; then
         echo "Warning: ${node} still critically full (${use_after}%). Try: ./hiveCtl.sh disk   or increase Docker Desktop disk." >&2
      fi
   done < <(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
}
function ensureClusterDiskSpaceOnce(){
   [ "${HIVECTL_DISK_CHECKED:-0}" = "1" ] && return 0
   HIVECTL_DISK_CHECKED=1
   ensureClusterDiskSpace
}
function showClusterDisk(){
   local node=""
   local any=0

   command -v docker >/dev/null 2>&1 || { echo "docker not available"; return 1; }
   kubectl get nodes >/dev/null 2>&1 || { echo "kubectl cluster not reachable"; return 1; }
   while read -r node; do
      [ -n "${node}" ] || continue
      docker inspect "${node}" >/dev/null 2>&1 || continue
      reportKindNodeDisk "${node}" && any=1
   done < <(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
   [ "${any}" -eq 1 ] || echo "No Kind node containers matched cluster node names"
   ensureClusterDiskSpace
}
# Start all components in dependency order.
function startStack(){
   local namespace="$1"
   local component=""
   local components=()

   ensureClusterDiskSpaceOnce

   case "${namespace}" in
      standalone)
         components=(hive)
         ;;
      llap)
         ensureHueSecrets "${namespace}" || return 1
         ensureAdminSecrets "${namespace}" || return 1
         llapNodeArchSummary
         components=(hadoop mysql zookeeper hivemetastore llapdaemon hiveserver2 hue)
         ;;
      secure)
         ensureKrb5Secrets "${namespace}" || return 1
         ensureHueSecrets "${namespace}" || return 1
         ensureAdminSecrets "${namespace}" || return 1
         llapNodeArchSummary
         components=(krb5kdc hadoop-namenode mysql)
         if [ "${HIVECTL_SECURE_RANGER:-0}" = "1" ]; then
            components+=(ranger)
         fi
         components+=(zookeeper hivemetastore llapdaemon hiveserver2 hue)
         ;;
      *)
         components=(hadoop mysql hivemetastore hiveserver2)
         ;;
   esac

   for component in "${components[@]}"; do
      startOverlay "${namespace}_${component}" || return 1
   done
   ensureProfileUiPortForwards "${namespace}" || true
}
# Start or refresh localhost port-forwards for Hue / Ranger after full stack or restore.
function ensureProfileUiPortForwards(){
   local namespace="$1"

   case "${namespace}" in
      secure)
         if kubectl get svc ranger -n "${namespace}" >/dev/null 2>&1; then
            ensureRangerPortForward "${namespace}" || true
         fi
         if profileHasHue "${namespace}" && kubectl get svc hue -n "${namespace}" >/dev/null 2>&1; then
            ensureHuePortForward "${namespace}" || true
         fi
         ;;
      llap)
         if profileHasHue "${namespace}" && kubectl get svc hue -n "${namespace}" >/dev/null 2>&1; then
            ensureHuePortForward "${namespace}" || true
         fi
         ;;
   esac
}
# Stop all components in reverse dependency order.
function stopStack(){
   local namespace="$1"
   local component=""
   local components=()

   requireNamespace "${namespace}" || return 1

   case "${namespace}" in
      standalone)
         components=(hive)
         ;;
      llap)
         components=(hue hiveserver2 llapdaemon hivemetastore zookeeper mysql hadoop)
         ;;
      secure)
         components=(hue hiveserver2 llapdaemon hivemetastore zookeeper)
         overlayActive "secure_ranger"
         if [ $? -eq 0 ]; then
            components+=(ranger)
         fi
         components+=(mysql hadoop-namenode krb5kdc)
         ;;
      *)
         components=(hiveserver2 hivemetastore mysql hadoop)
         ;;
   esac

   for component in "${components[@]}"; do
      stopOverlay "${namespace}_${component}" || return 1
   done
}
# Ensure a required component is active and Ready.
function ensureOverlayReady(){
   local namespace="$1"
   local service="$2"
   local target="${namespace}_${service}"

   overlayActive "${target}"
   case $? in
      0) waitForReady "${namespace}" "${service}" ;;
      1)
         echo "Overlay: ${target} must be active"
         return 1
         ;;
      *) return 1 ;;
   esac
}
# Stop Hive writer services and report which ones were stopped.
function stopHiveWriters(){
   local namespace="$1"
   local stopped_hms_var="$2"
   local stopped_hs2_var="$3"
   local hms_was_stopped=0
   local hs2_was_stopped=0

   overlayActive "${namespace}_hiveserver2"
   case $? in
      0)
         stopOverlay "${namespace}_hiveserver2" || return 1
         hs2_was_stopped=1
         ;;
      2) return 1 ;;
   esac
   overlayActive "${namespace}_hivemetastore"
   case $? in
      0)
         stopOverlay "${namespace}_hivemetastore" || return 1
         hms_was_stopped=1
         ;;
      2) return 1 ;;
   esac

   printf -v "${stopped_hms_var}" "%s" "${hms_was_stopped}"
   printf -v "${stopped_hs2_var}" "%s" "${hs2_was_stopped}"
}
# Restart Hive writer services that were stopped earlier.
function restartHiveWriters(){
   local namespace="$1"
   local stopped_hms="$2"
   local stopped_hs2="$3"
   local status=0

   if [ "${stopped_hms}" = "1" ]; then
      startOverlay "${namespace}_hivemetastore" || status=1
   fi
   if [ "${stopped_hs2}" = "1" ]; then
      startOverlay "${namespace}_hiveserver2" || status=1
   fi

   return "${status}"
}
# Create a temporary pod that mounts standalone data PVCs for offline backup/restore.
function createStandaloneDataHelper(){
   local namespace="$1"

   cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: standalone-data-helper
  namespace: ${namespace}
spec:
  serviceAccountName: hive
  automountServiceAccountToken: false
  restartPolicy: Never
  containers:
    - name: helper
      image: apache/hive:4.2.0
      command: ["/bin/bash", "-lc", "sleep infinity"]
      volumeMounts:
        - name: derby
          mountPath: /opt/hive/derby
        - name: warehouse
          mountPath: /opt/hive/data/warehouse
        - name: logs
          mountPath: /opt/hive/log
  volumes:
    - name: derby
      persistentVolumeClaim:
        claimName: pvc-derby
    - name: warehouse
      persistentVolumeClaim:
        claimName: pvc-warehouse
    - name: logs
      persistentVolumeClaim:
        claimName: pvc-logs
EOF
   kubectl wait --for=condition=Ready pod/standalone-data-helper -n "${namespace}" --timeout=180s
}
# Delete the temporary standalone data helper pod.
function deleteStandaloneDataHelper(){
   local namespace="$1"

   kubectl delete pod standalone-data-helper -n "${namespace}" --ignore-not-found --force
}
# Back up standalone Derby, warehouse, and log PVC contents.
function backupStandaloneStack(){
   local namespace="$1"
   local backup_dir="${2:-}"
   local was_active=0
   local status=0

   if [ -z "${backup_dir}" ]; then
      backup_dir="./backups/${namespace}-$(date +%Y%m%d-%H%M%S)"
   fi

   requireNamespace "${namespace}" || return 1
   ensureClusterDiskSpaceOnce
   mkdir -p "${backup_dir}" || return 1
   echo "Creating standalone backup in: ${backup_dir}"
   backupSecrets "${namespace}" "${backup_dir}" || return 1

   overlayActive "${namespace}_hive"
   case $? in
      0)
         stopOverlay "${namespace}_hive" || return 1
         was_active=1
         ;;
      2) return 1 ;;
   esac

   createStandaloneDataHelper "${namespace}" || status=1
   if [ "${status}" -eq 0 ]; then
      kubectl exec standalone-data-helper -n "${namespace}" -- bash -lc '
         tar -C /opt/hive -czf /tmp/standalone-hive.tgz derby data/warehouse log
      ' || status=1
   fi
   if [ "${status}" -eq 0 ]; then
      kubectl cp "${namespace}/standalone-data-helper:/tmp/standalone-hive.tgz" "${backup_dir}/standalone-hive.tgz" || status=1
   fi

   deleteStandaloneDataHelper "${namespace}" || status=1

   if [ "${was_active}" = "1" ]; then
      startOverlay "${namespace}_hive" || status=1
   fi

   if [ "${status}" -eq 0 ]; then
      echo "Standalone backup complete: ${backup_dir}"
   else
      echo "Standalone backup failed: ${backup_dir}"
   fi
   return "${status}"
}
# Restore standalone Derby, warehouse, and log PVC contents.
function restoreStandaloneStack(){
   local namespace="$1"
   local backup_dir="$2"
   local was_active=0
   local names=""
   local status=0

   if [ -z "${backup_dir}" ]; then
      echo "Restore requires a backup directory"
      return 1
   fi
   if [ ! -f "${backup_dir}/standalone-hive.tgz" ]; then
      echo "Backup directory must contain standalone-hive.tgz"
      return 1
   fi

   ensureClusterDiskSpaceOnce

   restoreSecrets "${namespace}" "${backup_dir}" || return 1
   echo "Restoring standalone backup from: ${backup_dir}"

   # The data helper mounts the overlay's PVCs, which only exist once the overlay has been started
   names="$(kubectlNames pvc pvc-derby -n "${namespace}")" || return 1
   if [ -z "${names}" ]; then
      startOverlay "${namespace}_hive" || return 1
   fi
   overlayActive "${namespace}_hive"
   case $? in
      0)
         stopOverlay "${namespace}_hive" || return 1
         was_active=1
         ;;
      2) return 1 ;;
   esac

   createStandaloneDataHelper "${namespace}" || status=1
   if [ "${status}" -eq 0 ]; then
      kubectl cp "${backup_dir}/standalone-hive.tgz" "${namespace}/standalone-data-helper:/tmp/standalone-hive.tgz" || status=1
   fi
   if [ "${status}" -eq 0 ]; then
      kubectl exec standalone-data-helper -n "${namespace}" -- bash -lc '
         find /opt/hive/derby -mindepth 1 -exec rm -rf {} +
         find /opt/hive/data/warehouse -mindepth 1 -exec rm -rf {} +
         find /opt/hive/log -mindepth 1 -exec rm -rf {} +
         tar -C /opt/hive -xzf /tmp/standalone-hive.tgz
         chown -R 1000:1000 /opt/hive/derby /opt/hive/data/warehouse /opt/hive/log 2>/dev/null || true
      ' || status=1
   fi

   deleteStandaloneDataHelper "${namespace}" || status=1

   if [ "${was_active}" = "1" ]; then
      startOverlay "${namespace}_hive" || status=1
   fi

   if [ "${status}" -eq 0 ]; then
      echo "Standalone restore complete: ${backup_dir}"
   else
      echo "Standalone restore failed: ${backup_dir}"
   fi
   return "${status}"
}
# Destructively remove standalone data PVC/PV bindings after optional backup.
function cleanupStandaloneStack(){
   local namespace="$1"
   local answer=""
   local confirm=""
   local status=0

   requireNamespace "${namespace}" || return 1

   cat <<EOF
WARNING: cleanup will delete standalone PVCs for namespace '${namespace}'.

Typical PVCs:
  - pvc-derby
  - pvc-warehouse
  - pvc-logs

Cleanup removes every PVC in the namespace, every PV bound to it, and
/var/local-path-provisioner/pvc-*_${namespace}_* on Kind nodes (same as secure).

If these PVCs/PVs are cleared, standalone Derby metastore, warehouse, and logs can be lost.
EOF

   read -r -p "Create a backup before cleanup? [Y/n] " answer
   case "${answer}" in
      ""|y|Y|yes|YES)
         backupStandaloneStack "${namespace}" || return 1
         ;;
      n|N|no|NO)
         echo "Skipping backup."
         ;;
      *)
         echo "Invalid answer. Aborting cleanup."
         return 1
         ;;
   esac

   echo
   read -r -p "Type '${namespace}' to confirm PVC/PV cleanup: " confirm
   if [ "${confirm}" != "${namespace}" ]; then
      echo "Confirmation did not match. Aborting cleanup."
      return 1
   fi

   stopStack "${namespace}" || return 1

   deleteNamespaceStorageAndLocalPath "${namespace}" || status=1

   echo "Deleting namespace '${namespace}' ..."
   kubectl delete namespace "${namespace}" --ignore-not-found || status=1
   waitForDeleted 300 "namespace/${namespace}" || status=1

   if [ "${status}" -eq 0 ]; then
      echo "Standalone cleanup complete. Run './hiveCtl.sh start ${namespace}' to recreate the namespace and empty PVCs."
   else
      echo "Standalone cleanup finished with errors. Inspect PVC/PV state before restarting."
   fi
   return "${status}"
}
# Pod used for offline HDFS backup/restore (mini/llap vs secure NameNode).
function hdfsBackupPod(){
   case "${1:-}" in
      secure) echo "hadoop-namenode-0" ;;
      *) echo "hadoop-0" ;;
   esac
}
# Ensure HDFS storage is Ready before backup/restore.
function ensureHdfsOverlayReady(){
   local namespace="$1"

   case "${namespace}" in
      secure) ensureOverlayReady "${namespace}" hadoop-namenode ;;
      *) ensureOverlayReady "${namespace}" hadoop ;;
   esac
}
# Archive selected HDFS paths inside the HDFS admin pod.
function hdfsArchiveForBackup(){
   local namespace="$1"
   local pod
   pod="$(hdfsBackupPod "${namespace}")"

   if [ "${namespace}" = "secure" ]; then
      # shellcheck disable=SC2016
      kubectl exec "${pod}" -n "${namespace}" -- bash -lc '
         realm="${KRB5_REALM:-SECURE.LAB}"
         host="$(hostname -f)"
         sudo -u hadoop kinit -kt /home/hadoop/host-service.keytab "hdfs/${host}@${realm}" || exit 1
         rm -rf /tmp/hdfs-backup /tmp/hdfs-backup.tgz
         mkdir -p /tmp/hdfs-backup
         for path in /opt /tmp /user /users /warehouse; do
            if hdfs dfs -test -e "${path}"; then
               hdfs dfs -get "${path}" /tmp/hdfs-backup/
            fi
         done
         tar -C /tmp -czf /tmp/hdfs-backup.tgz hdfs-backup
      '
   else
      # shellcheck disable=SC2016
      kubectl exec "${pod}" -n "${namespace}" -- bash -lc '
         rm -rf /tmp/hdfs-backup /tmp/hdfs-backup.tgz
         mkdir -p /tmp/hdfs-backup
         for path in /opt /tmp /user /users /warehouse; do
            if hdfs dfs -test -e "${path}"; then
               hdfs dfs -get "${path}" /tmp/hdfs-backup/
            fi
         done
         tar -C /tmp -czf /tmp/hdfs-backup.tgz hdfs-backup
      '
   fi
}
# Restore HDFS paths from an archive inside the HDFS admin pod.
function hdfsRestoreFromArchive(){
   local namespace="$1"
   local pod
   pod="$(hdfsBackupPod "${namespace}")"

   if [ "${namespace}" = "secure" ]; then
      # shellcheck disable=SC2016
      kubectl exec "${pod}" -n "${namespace}" -- bash -lc '
         realm="${KRB5_REALM:-SECURE.LAB}"
         host="$(hostname -f)"
         sudo -u hadoop kinit -kt /home/hadoop/host-service.keytab "hdfs/${host}@${realm}" || exit 1
         rm -rf /tmp/hdfs-restore
         mkdir -p /tmp/hdfs-restore
         tar -C /tmp/hdfs-restore -xzf /tmp/hdfs-backup.tgz
         for path in /opt /tmp /user /users /warehouse; do
            hdfs dfs -rm -r -skipTrash "${path}" >/dev/null 2>&1 || true
         done
         for path in /tmp/hdfs-restore/hdfs-backup/*; do
            hdfs dfs -put "${path}" /
         done
         hdfs dfs -mkdir -p /tmp/hive /user/hive /user/admin /warehouse/tablespace/managed/hive /warehouse/tablespace/external/hive
         hdfs dfs -chmod 777 / /tmp
         hdfs dfs -chmod -R 777 /tmp/hive
         hdfs dfs -chown -R hive:supergroup /tmp/hive /user/hive /warehouse /opt || true
         hdfs dfs -chown admin:supergroup /user/admin 2>/dev/null || true
      '
   else
      # shellcheck disable=SC2016
      kubectl exec "${pod}" -n "${namespace}" -- bash -lc '
         rm -rf /tmp/hdfs-restore
         mkdir -p /tmp/hdfs-restore
         tar -C /tmp/hdfs-restore -xzf /tmp/hdfs-backup.tgz
         for path in /opt /tmp /user /users /warehouse; do
            hdfs dfs -rm -r -skipTrash "${path}" >/dev/null 2>&1 || true
         done
         for path in /tmp/hdfs-restore/hdfs-backup/*; do
            hdfs dfs -put "${path}" /
         done
         hdfs dfs -mkdir -p /tmp/hive /user/hive /user/admin /warehouse/tablespace/managed/hive /warehouse/tablespace/external/hive
         hdfs dfs -chmod 777 / /tmp
         hdfs dfs -chmod -R 777 /tmp/hive
         hdfs dfs -chown -R hive:supergroup /tmp/hive /user/hive /warehouse /opt || true
         hdfs dfs -chown admin:supergroup /user/admin 2>/dev/null || true
      '
   fi
}
# Delete orphaned local-path-provisioner dirs on Kind nodes (Retain PVs leave data on disk).
function cleanupLocalPathProvisionerDirs(){
   local namespace="$1"
   local node=""
   local line=""
   local path=""
   local size=""

   [ -n "${namespace}" ] || return 0
   if ! command -v docker >/dev/null 2>&1; then
      echo "docker not available; skipping stale local-path-provisioner cleanup on Kind nodes"
      return 0
   fi
   if ! kubectl get nodes >/dev/null 2>&1; then
      echo "kubectl cannot list nodes; skipping stale local-path-provisioner cleanup"
      return 0
   fi

   echo "Removing stale local-path-provisioner data for namespace '${namespace}' on Kind nodes ..."
   while IFS= read -r node; do
      [ -n "${node}" ] || continue
      docker inspect "${node}" >/dev/null 2>&1 || continue
      while IFS= read -r line; do
         [ -n "${line}" ] || continue
         path="${line#*|}"
         size="${line%%|*}"
         echo "  ${node}: removed ${path} (${size})"
      done < <(
         docker exec "${node}" bash -lc "
            shopt -s nullglob
            for d in /var/local-path-provisioner/pvc-*_${namespace}_*; do
               [ -d \"\${d}\" ] || continue
               sz=\$(du -sh \"\${d}\" 2>/dev/null | awk '{print \$1}')
               echo \"\${sz}|\${d}\"
               rm -rf \"\${d}\"
            done
         " 2>/dev/null || true
      )
   done < <(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)

   return 0
}
# Typical PVC names per profile (cleanup also removes any other PVCs still in the namespace).
function stackCleanupPvcsExpected(){
   case "${1:-}" in
      secure)
         echo "mysql-mysql-0 pvc-hdfs-nn datanode-data-hadoop-datanode-0 datanode-data-hadoop-datanode-1 datanode-data-hadoop-datanode-2 krb5kdc-data-krb5kdc-0"
         ;;
      mini|llap)
         echo "mysql-mysql-0 pvc-hdfs"
         ;;
      standalone)
         echo "pvc-derby pvc-warehouse pvc-logs"
         ;;
      *)
         echo "mysql-mysql-0 pvc-hdfs"
         ;;
   esac
}
function pvcNamesInNamespace(){
   local namespace="$1"

   kubectl get pvc -n "${namespace}" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null
}
function pvNamesForNamespace(){
   local namespace="$1"

   kubectl get pv -o custom-columns=NAME:.metadata.name,NS:.spec.claimRef.namespace --no-headers 2>/dev/null \
      | awk -v ns="${namespace}" '$2 == ns { print $1 }'
}
# Delete every PVC in the namespace, every PV bound to it, and local-path dirs on Kind nodes.
function deleteNamespaceStorageAndLocalPath(){
   local namespace="$1"
   local status=0
   local pvc_list=""
   local pv_names=""
   local pv=""
   local pvc=""
   local wait_args=()

   pvc_list="$(pvcNamesInNamespace "${namespace}")"
   pv_names="$(pvNamesForNamespace "${namespace}")"

   if [ -n "${pvc_list// /}" ]; then
      echo "Deleting PVCs in namespace '${namespace}' ..."
      # shellcheck disable=SC2086
      kubectl delete pvc ${pvc_list} -n "${namespace}" --ignore-not-found || status=1
   else
      echo "No PVCs remain in namespace '${namespace}'."
   fi

   if [ -n "${pv_names}" ]; then
      echo "Deleting PV objects bound to namespace '${namespace}' ..."
      while IFS= read -r pv; do
         [ -n "${pv}" ] || continue
         kubectl delete pv "${pv}" --ignore-not-found || status=1
      done <<< "${pv_names}"
   fi

   wait_args=()
   for pvc in ${pvc_list}; do
      wait_args+=( "pvc/${pvc}" )
   done
   if [ "${#wait_args[@]}" -gt 0 ]; then
      waitForDeleted 180 "${wait_args[@]}" -n "${namespace}" || status=1
   fi

   cleanupLocalPathProvisionerDirs "${namespace}" || true
   return "${status}"
}
# Return 0 when MySQL in the namespace contains the given database.
function mysqlDatabaseExists(){
   local namespace="$1"
   local db="$2"

   kubectl exec mysql-0 -n "${namespace}" -- \
      sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -e "SHOW DATABASES"' 2>/dev/null \
      | grep -qx "${db}"
}
# Stop Ranger Admin during backup/restore so the policy database is quiescent (secure only).
function stopRangerIfActive(){
   local namespace="$1"
   local stopped_var="$2"
   local stopped=0

   printf -v "${stopped_var}" "0"
   [ "${namespace}" = "secure" ] || return 0
   overlayActive "secure_ranger"
   case $? in
      0)
         stopOverlay "secure_ranger" || return 1
         stopped=1
         ;;
      1|2) ;;
   esac
   printf -v "${stopped_var}" "${stopped}"
   return 0
}
# Start Ranger Admin after backup/restore when it was stopped for MySQL consistency.
function startRangerIfStopped(){
   local namespace="$1"
   local was_stopped="$2"

   [ "${was_stopped}" = "1" ] || return 0
   [ "${namespace}" = "secure" ] || return 0
   startOverlay "secure_ranger" || return 1
}
# Dump Ranger policy/service data from MySQL (secure, when ranger DB exists).
function backupRangerDatabase(){
   local namespace="$1"
   local backup_dir="$2"

   [ "${namespace}" = "secure" ] || return 0
   if ! mysqlDatabaseExists "${namespace}" ranger; then
      echo "Skipping Ranger backup (no ranger database in MySQL; start './hiveCtl.sh start secure ranger' first)"
      return 0
   fi
   echo "Backing up MySQL ranger database (Ranger policies and services) ..."
   # shellcheck disable=SC2016
   kubectl exec mysql-0 -n "${namespace}" -- \
      sh -c 'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines --events --databases ranger' \
      > "${backup_dir}/mysql-ranger.sql" || return 1
}
# Create ranger DB/user on mysql-0 before importing mysql-ranger.sql (fresh PVC after cleanup).
function ensureRangerMysqlForRestore(){
   local namespace="$1"
   local backup_dir="$2"
   local ranger_db_pw=""

   [ "${namespace}" = "secure" ] || return 0
   [ -f "${backup_dir}/mysql-ranger.sql" ] || return 0
   ensureSecrets "${namespace}" || return 1
   ranger_db_pw="$(kubectl get secret hive-credentials -n "${namespace}" -o jsonpath='{.data.ranger-db-password}' 2>/dev/null | base64 -d 2>/dev/null)" || true
   if [ -z "${ranger_db_pw}" ]; then
      echo "Cannot restore Ranger policies: ranger-db-password missing in hive-credentials"
      return 1
   fi
   echo "Ensuring Ranger MySQL database/user before policy restore ..."
   # shellcheck disable=SC2016
   kubectl exec mysql-0 -n "${namespace}" -- \
      env RANGER_DB_PASSWORD="${ranger_db_pw}" \
      sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" <<EOF
CREATE DATABASE IF NOT EXISTS ranger CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '\''rangeradmin'\''@'\''%'\'' IDENTIFIED WITH mysql_native_password BY '\''${RANGER_DB_PASSWORD}'\'';
ALTER USER '\''rangeradmin'\''@'\''%'\'' IDENTIFIED WITH mysql_native_password BY '\''${RANGER_DB_PASSWORD}'\'';
GRANT ALL PRIVILEGES ON ranger.* TO '\''rangeradmin'\''@'\''%'\'';
FLUSH PRIVILEGES;
EOF' || return 1
}
# Restore Ranger policies from mysql-ranger.sql when present in the backup directory.
function restoreRangerDatabase(){
   local namespace="$1"
   local backup_dir="$2"

   [ "${namespace}" = "secure" ] || return 0
   if [ ! -f "${backup_dir}/mysql-ranger.sql" ]; then
      echo "No mysql-ranger.sql in backup (Ranger policies were not included)"
      return 0
   fi
   ensureRangerMysqlForRestore "${namespace}" "${backup_dir}" || return 1
   echo "Restoring MySQL ranger database (Ranger policies and services) ..."
   # shellcheck disable=SC2016
   kubectl exec -i mysql-0 -n "${namespace}" -- \
      sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"' \
      < "${backup_dir}/mysql-ranger.sql" || return 1
}
# Back up MySQL metastore data and HDFS data to a local directory.
function backupStack(){
   local namespace="$1"
   local backup_dir="${2:-}"
   local stopped_hms=0
   local stopped_hs2=0
   local stopped_ranger=0
   local status=0

   if [ "${namespace}" = "standalone" ]; then
      backupStandaloneStack "${namespace}" "${backup_dir}"
      return $?
   fi

   if [ -z "${backup_dir}" ]; then
      backup_dir="./backups/${namespace}-$(date +%Y%m%d-%H%M%S)"
   fi

   requireNamespace "${namespace}" || return 1

   ensureClusterDiskSpaceOnce

   mkdir -p "${backup_dir}" || return 1
   echo "Creating backup in: ${backup_dir}"
   backupSecrets "${namespace}" "${backup_dir}" || return 1

   stopHiveWriters "${namespace}" stopped_hms stopped_hs2 || return 1
   stopRangerIfActive "${namespace}" stopped_ranger || return 1

   ensureHdfsOverlayReady "${namespace}" || status=1
   ensureOverlayReady "${namespace}" mysql || status=1

   if [ "${status}" -eq 0 ]; then
      echo "Backing up MySQL metastore database ..."
      # shellcheck disable=SC2016
      kubectl exec mysql-0 -n "${namespace}" -- \
         sh -c 'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines --events --databases hive' \
         > "${backup_dir}/mysql-hive.sql" || status=1
   fi

   if [ "${status}" -eq 0 ]; then
      backupRangerDatabase "${namespace}" "${backup_dir}" || status=1
   fi

   if [ "${status}" -eq 0 ]; then
      echo "Backing up HDFS data ..."
      hdfsArchiveForBackup "${namespace}" || status=1
   fi

   if [ "${status}" -eq 0 ]; then
      local hdfs_pod
      hdfs_pod="$(hdfsBackupPod "${namespace}")"
      kubectl cp "${namespace}/${hdfs_pod}:/tmp/hdfs-backup.tgz" "${backup_dir}/hdfs-backup.tgz" || status=1
   fi

   startRangerIfStopped "${namespace}" "${stopped_ranger}" || status=1
   restartHiveWriters "${namespace}" "${stopped_hms}" "${stopped_hs2}" || status=1

   if [ "${status}" -eq 0 ]; then
      echo "Backup complete: ${backup_dir}"
   else
      echo "Backup failed: ${backup_dir}"
   fi
   return "${status}"
}
# Restore MySQL metastore data and HDFS data from a local backup directory.
function restoreStack(){
   local namespace="$1"
   local backup_dir="$2"
   local stopped_hms=0
   local stopped_hs2=0
   local stopped_ranger=0
   local started_storage=0
   local component=""
   local status=0

   if [ "${namespace}" = "standalone" ]; then
      restoreStandaloneStack "${namespace}" "${backup_dir}"
      return $?
   fi

   if [ -z "${backup_dir}" ]; then
      echo "Restore requires a backup directory"
      return 1
   fi
   if [ ! -f "${backup_dir}/mysql-hive.sql" ] || [ ! -f "${backup_dir}/hdfs-backup.tgz" ]; then
      echo "Backup directory must contain mysql-hive.sql and hdfs-backup.tgz"
      return 1
   fi

   ensureClusterDiskSpaceOnce

   restoreSecrets "${namespace}" "${backup_dir}" || return 1

   echo "Restoring backup from: ${backup_dir}"
   stopHiveWriters "${namespace}" stopped_hms stopped_hs2 || return 1
   stopRangerIfActive "${namespace}" stopped_ranger || return 1

   # Storage that isn't running is started now and the rest of the stack after the restore,
   # so on a fresh namespace the Metastore never creates an empty schema first
   local storage_components=()
   case "${namespace}" in
      secure) storage_components=(krb5kdc hadoop-namenode mysql) ;;
      *) storage_components=(hadoop mysql) ;;
   esac
   for component in "${storage_components[@]}"; do
      overlayActive "${namespace}_${component}"
      case $? in
         0)
            if [ "${component}" = "hadoop-namenode" ]; then
               waitForReady "${namespace}" "hadoop-datanode" || status=1
            fi
            waitForReady "${namespace}" "${component}" || status=1
            ;;
         1)
            startOverlay "${namespace}_${component}" || status=1
            started_storage=1
            ;;
         *) status=1 ;;
      esac
   done

   if [ "${status}" -eq 0 ]; then
      echo "Restoring MySQL metastore database ..."
      # shellcheck disable=SC2016
      kubectl exec -i mysql-0 -n "${namespace}" -- \
         sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"' \
         < "${backup_dir}/mysql-hive.sql" || status=1
   fi

   if [ "${status}" -eq 0 ]; then
      restoreRangerDatabase "${namespace}" "${backup_dir}" || status=1
   fi

   if [ "${status}" -eq 0 ]; then
      echo "Restoring HDFS data ..."
      local hdfs_pod
      hdfs_pod="$(hdfsBackupPod "${namespace}")"
      kubectl cp "${backup_dir}/hdfs-backup.tgz" "${namespace}/${hdfs_pod}:/tmp/hdfs-backup.tgz" || status=1
   fi

   if [ "${status}" -eq 0 ]; then
      hdfsRestoreFromArchive "${namespace}" || status=1
   fi

   if [ "${started_storage}" = "0" ]; then
      startRangerIfStopped "${namespace}" "${stopped_ranger}" || status=1
      restartHiveWriters "${namespace}" "${stopped_hms}" "${stopped_hs2}" || status=1
   elif [ "${status}" -eq 0 ]; then
      startStack "${namespace}" || status=1
      startRangerIfStopped "${namespace}" "${stopped_ranger}" || status=1
   fi

   ensureProfileUiPortForwards "${namespace}" || true
   if [ "${status}" -eq 0 ]; then
      echo "Restore complete: ${backup_dir}"
   else
      echo "Restore failed: ${backup_dir}"
   fi
   return "${status}"
}
# Destructively remove stack data PVC/PV bindings after optional backup.
function cleanupStack(){
   local namespace="$1"
   local answer=""
   local confirm=""
   local status=0
   local expected_pvcs=""
   local actual_pvcs=""

   if [ "${namespace}" = "standalone" ]; then
      cleanupStandaloneStack "${namespace}"
      return $?
   fi

   requireNamespace "${namespace}" || return 1

   expected_pvcs="$(stackCleanupPvcsExpected "${namespace}")"
   actual_pvcs="$(pvcNamesInNamespace "${namespace}")"

   cat <<EOF
WARNING: cleanup will delete PVCs for namespace '${namespace}'.

Typical PVCs for this profile:
$(for pvc in ${expected_pvcs}; do echo "  - ${pvc}"; done)

Cleanup removes every PVC still in the namespace and every PV bound to it
(same as secure), then stale local-path data on Kind nodes.
$(if [ -n "${actual_pvcs// /}" ] && [ "${actual_pvcs}" != "${expected_pvcs}" ]; then
     echo "PVCs currently present: ${actual_pvcs}"
   fi)

If these PVCs/PVs are cleared, Hive metastore and HDFS data can be lost.
EOF

   read -r -p "Create a backup before cleanup? [Y/n] " answer
   case "${answer}" in
      ""|y|Y|yes|YES)
         backupStack "${namespace}" || return 1
         ;;
      n|N|no|NO)
         echo "Skipping backup."
         ;;
      *)
         echo "Invalid answer. Aborting cleanup."
         return 1
         ;;
   esac

   echo
   read -r -p "Type '${namespace}' to confirm PVC/PV cleanup: " confirm
   if [ "${confirm}" != "${namespace}" ]; then
      echo "Confirmation did not match. Aborting cleanup."
      return 1
   fi

   stopStack "${namespace}" || return 1

   deleteNamespaceStorageAndLocalPath "${namespace}" || status=1

   echo "Deleting namespace '${namespace}' ..."
   kubectl delete namespace "${namespace}" --ignore-not-found || status=1
   waitForDeleted 300 "namespace/${namespace}" || status=1

   if [ "${status}" -eq 0 ]; then
      echo "Cleanup complete. Run './hiveCtl.sh start ${namespace}' to recreate the namespace and empty PVCs."
   else
      echo "Cleanup finished with errors. Inspect PVC/PV state before restarting."
   fi
   return "${status}"
}

# Overlays that use hive-credentials (namespace name = overlay name).
function passwdOverlayName(){
   case "${1:-}" in
      mini|llap|secure|standalone) echo "${1}" ;;
      *) return 1 ;;
   esac
}
# Secret data key for a passwd alias (empty if unknown).
function passwdSecretKeyForAlias(){
   case "${1:-}" in
      mysql-root) echo "mysql-root-password" ;;
      hive-mysql) echo "hive-metastore-password" ;;
      hue-mysql) echo "hue-mysql-password" ;;
      hue-secret-key) echo "hue-secret-key" ;;
      ranger-admin) echo "ranger-admin-password" ;;
      ranger-db) echo "ranger-db-password" ;;
      krb5-master) echo "krb5-master-password" ;;
      krb5-kadmin) echo "krb5-kadmin-password" ;;
      root) echo "root-password" ;;
      hive) echo "hive-password" ;;
      hadoop) echo "hadoop-password" ;;
      beeline) echo "beeline-password" ;;
      admin) echo "admin-password" ;;
      *) return 1 ;;
   esac
}
# passwd aliases applicable to an overlay profile (may not exist in Secret until ensure* runs).
function passwdAliasesForOverlay(){
   local overlay="$1"
   case "${overlay}" in
      secure)
         echo "mysql-root hive-mysql hue-mysql hue-secret-key ranger-admin ranger-db krb5-master krb5-kadmin root hive hadoop beeline admin"
         ;;
      llap|mini)
         echo "mysql-root hive-mysql hue-mysql hue-secret-key root hive hadoop beeline admin"
         ;;
      standalone)
         echo "root hive hadoop beeline admin"
         ;;
      *)
         return 1
         ;;
   esac
}
function listPasswd(){
   local overlay="${1:-}"
   local alias=""
   local key=""
   local desc=""
   local present=""

   if [ -z "${overlay}" ]; then
      echo "Password aliases (hive-credentials Secret; namespace = overlay name):"
      echo ""
      printf "%-16s %-28s %s\n" "ALIAS" "SECRET_KEY" "DESCRIPTION"
      printf "%-16s %-28s %s\n" "-----" "----------" "-----------"
      while read -r alias key desc; do
         [ -n "${alias}" ] || continue
         printf "%-16s %-28s %s\n" "${alias}" "${key}" "${desc}"
      done <<'EOF'
mysql-root mysql-root-password MySQL root
hive-mysql hive-metastore-password MySQL hive metastore user
hue-mysql hue-mysql-password Hue MySQL user
hue-secret-key hue-secret-key Hue Django secret (not a login password)
ranger-admin ranger-admin-password Ranger UI user admin
ranger-db ranger-db-password MySQL rangeradmin (Ranger schema)
krb5-master krb5-master-password KDC database master (secure)
krb5-kadmin krb5-kadmin-password kadmin principal (secure)
root root-password Lab bootstrap root slot
hive hive-password Lab Hive service / JDBC material
hadoop hadoop-password Lab Hadoop service material
beeline beeline-password Beeline JDBC (often same as hive at create)
admin admin-password Lab admin slot (Hue/Hadoop; not Ranger UI)
EOF
      echo ""
      echo "Profiles:"
      echo "  secure:     mysql-root hive-mysql hue-mysql hue-secret-key ranger-admin ranger-db krb5-master krb5-kadmin root hive hadoop beeline admin"
      echo "  llap, mini: mysql-root hive-mysql hue-mysql hue-secret-key root hive hadoop beeline admin"
      echo "  standalone: root hive hadoop beeline admin"
      echo ""
      echo "List keys present in a cluster:  hiveCtl list passwd <overlay>"
      return 0
   fi

   passwdOverlayName "${overlay}" >/dev/null || {
      echo "Unknown overlay '${overlay}' (use mini, llap, secure, or standalone)"
      return 1
   }
   requireNamespace "${overlay}" || return 1
   if ! kubectl get secret hive-credentials -n "${overlay}" >/dev/null 2>&1; then
      echo "Secret hive-credentials not found in namespace '${overlay}' (start the overlay first)"
      return 1
   fi

   echo "Password aliases in hive-credentials (namespace ${overlay}):"
   printf "%-16s %-28s %s\n" "ALIAS" "SECRET_KEY" "IN_SECRET"
   for alias in $(passwdAliasesForOverlay "${overlay}"); do
      key="$(passwdSecretKeyForAlias "${alias}")" || continue
      present="$(kubectl get secret hive-credentials -n "${overlay}" -o "jsonpath={.data.${key}}" 2>/dev/null)"
      if [ -n "${present}" ]; then
         present="yes"
      else
         present="no"
      fi
      printf "%-16s %-28s %s\n" "${alias}" "${key}" "${present}"
   done
}
function getPasswd(){
   local overlay=""
   local alias=""
   local key=""
   local value=""

   if passwdOverlayName "${2:-}" >/dev/null 2>&1; then
      overlay="${2}"
      alias="${3:-}"
   else
      overlay="${HIVECTL_PASSWD_OVERLAY:-secure}"
      alias="${2:-}"
   fi

   if [ -z "${alias}" ]; then
      echo "Usage: hiveCtl get passwd [<overlay>] <alias>   (hiveCtl list passwd for aliases)"
      return 1
   fi
   passwdOverlayName "${overlay}" >/dev/null || {
      echo "Unknown overlay '${overlay}'"
      return 1
   }
   key="$(passwdSecretKeyForAlias "${alias}")" || {
      echo "Unknown password alias '${alias}' (try: hiveCtl list passwd)"
      return 1
   }
   requireNamespace "${overlay}" || return 1
   if ! kubectl get secret hive-credentials -n "${overlay}" >/dev/null 2>&1; then
      echo "Secret hive-credentials not found in namespace '${overlay}'"
      return 1
   fi
   value="$(kubectl get secret hive-credentials -n "${overlay}" -o "jsonpath={.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null)"
   if [ -z "${value}" ]; then
      echo "Key '${key}' (${alias}) is not set in hive-credentials (namespace ${overlay})"
      return 1
   fi
   printf '%s\n' "${value}"
}

# Dispatch CLI actions to the appropriate helper.
main(){
   case "${1:-}" in
        __hue-portforward-monitor)
          huePortForwardMonitorLoop
          ;;
        __ranger-portforward-monitor)
          rangerPortForwardMonitorLoop
          ;;
        available)
          overlays
          ;;
        start)
          [[ -z "${2:-}" ]] && help && exit 1
          if [ -z "${3:-}" ]; then
             startStack "$2"
          else
             startOverlay "$2_$3"
          fi
          ;;
        stop)
          [[ -z "${2:-}" ]] && help && exit 1
          if [ -z "${3:-}" ]; then
             stopStack "$2"
          else
             stopOverlay  "$2_$3"
          fi
          ;;
        status)
          activeOverlays show
          ;;
        disk)
          showClusterDisk
          ;;
        resync-keytabs)
          [[ -z "${2:-}" ]] && help && exit 1
          HIVECTL_KRB5_RESYNC_KEYTABS=1 ensureKerberosKeytabSecret "$2" || exit 1
          echo "Updated Secret kerberos-keytabs in namespace '${2}'."
          if [ "$2" = "secure" ]; then
             echo "Restarting Hadoop + Hive so pods remount v3 keytabs (FQDN + pod short name) ..."
             stopOverlay "secure_hiveserver2" || true
             stopOverlay "secure_hivemetastore" || true
             stopSecureHadoop || exit 1
             startSecureHadoop || exit 1
             startOverlay "secure_hivemetastore" || exit 1
             startOverlay "secure_hiveserver2" || exit 1
          else
             echo "Restart Kerberos-enabled pods in '${2}' to remount keytabs."
          fi
          ;;
        restart)
          [[ -z "${2:-}" ]] && help && exit 1
          if [ -z "${3:-}" ]; then
             stopStack "$2" && startStack "$2"
          else
             stopOverlay "$2_$3" && startOverlay "$2_$3"
          fi
          ;;
        backup)
          [[ -z "${2:-}" ]] && help && exit 1
          backupStack "$2" "${3:-}"
          ;;
        restore)
          [[ -z "${2:-}" || -z "${3:-}" ]] && help && exit 1
          restoreStack "$2" "$3"
          ;;
        cleanup)
          [[ -z "${2:-}" ]] && help && exit 1
          cleanupStack "$2"
          ;;
        list)
          case "${2:-}" in
             passwd) listPasswd "${3:-}" ;;
             *) help && exit 1 ;;
          esac
          ;;
        get)
          case "${2:-}" in
             passwd) getPasswd "${3:-}" "${4:-}" ;;
             *) help && exit 1 ;;
          esac
          ;;
        *)
          help
          ;;
esac
}

main "$@"
