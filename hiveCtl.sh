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
   echo "        hiveCtl cleanup <overlay>"
   echo "        hiveCtl disk   (check Kind node /var space; prune container images if low)"
   echo "        hiveCtl resync-keytabs <overlay>   (secure: refresh Secret kerberos-keytabs from KDC PVC)"
   echo "        hiveCtl status"
   echo ""
   echo "Hue (llap|secure): after start, hiveCtl tries http://localhost:8888 automatically"
   echo "  (kubectl port-forward in background unless the port already works, e.g. kind/llap-cluster.yaml)"
   echo "  While hue-0 is Ready, a background monitor restarts port-forward every minute if localhost stops responding"
   echo "  Disable forward: HIVECTL_HUE_PORT_FORWARD=0   Port: HIVECTL_HUE_LOCAL_PORT=8888"
   echo "  Disable monitor: HIVECTL_HUE_PORT_FORWARD_MONITOR=0   Interval: HIVECTL_HUE_PORT_FORWARD_MONITOR_INTERVAL=60"
   echo "LLAP daemon UI: http://localhost:15002 after start llapdaemon (pod llapdaemon-0)"
   echo "  Disable: HIVECTL_LLAP_DAEMON_PORT_FORWARD=0   Port: HIVECTL_LLAP_DAEMON_LOCAL_PORT=15002"
   echo "Profile secure: llap-shaped Hive (2 HMS, 2 HS2, 2 LLAP) + KDC, NN + 3 DNs, ZK, Hue (./hiveCtl.sh start secure)"
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
# List overlays that currently have an active StatefulSet.
function activeOverlays(){
   #
   # Each Overlay lives in it's own Namespace of the same name
   #
   local arg="${1:-}"
   local target=""
   local active_list=""
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
   if [ "${service}" = "hadoop-namenode" ]; then
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

   ensureClusterDiskSpaceOnce

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
            #kubectl apply -k "${overlay_path}"
            kustomize build "${overlay_path}" --load-restrictor LoadRestrictionsNone | kubectl apply -f -
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

   [ -n "${port}" ] || return 1
   command -v curl >/dev/null 2>&1 || return 1
   code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/" --connect-timeout 2 2>/dev/null || echo 000)"
   case "${code}" in
      200|301|302|303|401|403|404) return 0 ;;
      *) return 1 ;;
   esac
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

   if [ -f "${pidfile}" ]; then
      pid="$(cat "${pidfile}")"
      if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
         if hueLocalUrlReachable "${port}"; then
            return 0
         fi
         kill "${pid}" 2>/dev/null || true
         wait "${pid}" 2>/dev/null || true
      fi
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
      if hueLocalUrlReachable "${port}"; then
         continue
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

   if hueLocalUrlReachable "${port}"; then
      if [ -f "${pidfile}" ]; then
         pid="$(cat "${pidfile}")"
         if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
            echo "Hue UI (${namespace}): http://localhost:${port}/ (port-forward pid ${pid})"
         else
            echo "Hue UI (${namespace}): http://localhost:${port}/ (already reachable; not starting port-forward)"
         fi
      else
         echo "Hue UI (${namespace}): http://localhost:${port}/ (already reachable; not starting port-forward)"
      fi
      startHuePortForwardMonitor "${namespace}" || true
      return 0
   fi

   if startHuePortForwardProcess "${namespace}"; then
      pid="$(cat "${pidfile}")"
      echo "Hue UI (${namespace}): http://localhost:${port}/ (hiveCtl port-forward pid ${pid}; stops on './hiveCtl.sh stop ${namespace} hue')"
      startHuePortForwardMonitor "${namespace}" || true
      return 0
   fi
   echo "Warning: could not bind localhost:${port} for Hue. Try: kubectl port-forward svc/hue -n ${namespace} ${port}:8888" >&2
   startHuePortForwardMonitor "${namespace}" || true
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
         components=(krb5kdc hadoop-namenode mysql zookeeper hivemetastore llapdaemon hiveserver2 hue)
         ;;
      *)
         components=(hadoop mysql hivemetastore hiveserver2)
         ;;
   esac

   for component in "${components[@]}"; do
      startOverlay "${namespace}_${component}" || return 1
   done
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
         components=(hue hiveserver2 llapdaemon hivemetastore zookeeper mysql hadoop-namenode krb5kdc)
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
   local pv_names=""
   local pv=""
   local status=0

   requireNamespace "${namespace}" || return 1

   cat <<EOF
WARNING: cleanup will delete standalone PVCs for namespace '${namespace}'.

This removes Kubernetes' bindings for:
  - pvc-derby
  - pvc-warehouse
  - pvc-logs

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

   pv_names="$(
      kubectl get pv --no-headers -o custom-columns=NAME:.metadata.name,CLAIM:.spec.claimRef.name,NAMESPACE:.spec.claimRef.namespace \
      | awk -v namespace="${namespace}" '($2 == "pvc-derby" || $2 == "pvc-warehouse" || $2 == "pvc-logs") && $3 == namespace {print $1}'
   )" || return 1

   stopStack "${namespace}" || return 1

   echo "Deleting standalone PVCs ..."
   kubectl delete pvc pvc-derby pvc-warehouse pvc-logs -n "${namespace}" --ignore-not-found || status=1

   if [ -n "${pv_names}" ]; then
      echo "Deleting matching PV objects ..."
      for pv in ${pv_names}; do
         kubectl delete pv "${pv}" --ignore-not-found || status=1
      done
   fi

   waitForDeleted 180 pvc/pvc-derby pvc/pvc-warehouse pvc/pvc-logs -n "${namespace}" || status=1

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
# PVC names removed by cleanupStack for a profile.
function stackCleanupPvcs(){
   case "${1:-}" in
      secure)
         echo "mysql-mysql-0 pvc-hdfs-nn datanode-data-hadoop-datanode-0 datanode-data-hadoop-datanode-1 datanode-data-hadoop-datanode-2 krb5kdc-data-krb5kdc-0"
         ;;
      *)
         echo "mysql-mysql-0 pvc-hdfs"
         ;;
   esac
}
# Back up MySQL metastore data and HDFS data to a local directory.
function backupStack(){
   local namespace="$1"
   local backup_dir="${2:-}"
   local stopped_hms=0
   local stopped_hs2=0
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
      echo "Backing up HDFS data ..."
      hdfsArchiveForBackup "${namespace}" || status=1
   fi

   if [ "${status}" -eq 0 ]; then
      local hdfs_pod
      hdfs_pod="$(hdfsBackupPod "${namespace}")"
      kubectl cp "${namespace}/${hdfs_pod}:/tmp/hdfs-backup.tgz" "${backup_dir}/hdfs-backup.tgz" || status=1
   fi

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
      echo "Restoring HDFS data ..."
      local hdfs_pod
      hdfs_pod="$(hdfsBackupPod "${namespace}")"
      kubectl cp "${backup_dir}/hdfs-backup.tgz" "${namespace}/${hdfs_pod}:/tmp/hdfs-backup.tgz" || status=1
   fi

   if [ "${status}" -eq 0 ]; then
      hdfsRestoreFromArchive "${namespace}" || status=1
   fi

   if [ "${started_storage}" = "0" ]; then
      restartHiveWriters "${namespace}" "${stopped_hms}" "${stopped_hs2}" || status=1
   elif [ "${status}" -eq 0 ]; then
      startStack "${namespace}" || status=1
   fi

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
   local pv_names=""
   local pv=""
   local status=0

   if [ "${namespace}" = "standalone" ]; then
      cleanupStandaloneStack "${namespace}"
      return $?
   fi

   requireNamespace "${namespace}" || return 1

   local pvc_list
   pvc_list="$(stackCleanupPvcs "${namespace}")"

   cat <<EOF
WARNING: cleanup will delete PVCs for namespace '${namespace}'.

This removes Kubernetes' bindings for:
$(for pvc in ${pvc_list}; do echo "  - ${pvc}"; done)

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

   pv_names="$(
      kubectl get pv --no-headers -o custom-columns=NAME:.metadata.name,CLAIM:.spec.claimRef.name,NAMESPACE:.spec.claimRef.namespace \
      | awk -v namespace="${namespace}" -v pvcs="${pvc_list}" '
         BEGIN { n = split(pvcs, a, " "); for (i = 1; i <= n; i++) wanted[a[i]] = 1 }
         wanted[$2] && $3 == namespace { print $1 }
      '
   )" || return 1

   stopStack "${namespace}" || return 1

   echo "Deleting PVCs ..."
   # shellcheck disable=SC2086
   kubectl delete pvc ${pvc_list} -n "${namespace}" --ignore-not-found || status=1

   if [ -n "${pv_names}" ]; then
      echo "Deleting matching PV objects ..."
      for pv in ${pv_names}; do
         kubectl delete pv "${pv}" --ignore-not-found || status=1
      done
   fi

   local wait_args=()
   for pvc in ${pvc_list}; do
      wait_args+=( "pvc/${pvc}" )
   done
   waitForDeleted 180 "${wait_args[@]}" -n "${namespace}" || status=1

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

# Dispatch CLI actions to the appropriate helper.
main(){
   case "${1:-}" in
        __hue-portforward-monitor)
          huePortForwardMonitorLoop
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
        *)
          help
          ;;
esac
}

main "$@"
