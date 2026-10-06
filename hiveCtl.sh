#!/bin/bash
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
   echo "Usage:  hiveCtl [available|start|stop|status|restart|backup|restore|cleanup] <overlay> [<component>]"
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
   echo "        hiveCtl status"
}
# Return success when the Kubernetes namespace exists.
function namespaceExists(){
   local namespace="$1"

   kubectl get namespace "${namespace}" >/dev/null 2>&1
}
# Require a namespace before running namespace-scoped operations.
function requireNamespace(){
   local namespace="$1"

   if ! namespaceExists "${namespace}"; then
      echo "Namespace '${namespace}' does not exist"
      return 1
   fi
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

   if ! namespaceExists "${namespace}"; then
      kubectl create namespace "${namespace}" >/dev/null
   fi

   if kubectl get secret hive-credentials -n "${namespace}" >/dev/null 2>&1; then
      return 0
   fi

   root_password="$(generatePassword)"
   hive_password="$(generatePassword)"
   hadoop_password="$(generatePassword)"
   mysql_root_password="$(generatePassword)"
   hive_metastore_password="$(generatePassword)"
   beeline_password="${hive_password}"

   # Existing mini PVCs were initialized with the historical lab passwords.
   # Preserve compatibility so adding Secrets does not break a running metastore.
   if [ "${namespace}" = "mini" ] && kubectl get pvc mysql-mysql-0 -n "${namespace}" >/dev/null 2>&1; then
      root_password="cloudera"
      hive_password="hive"
      hadoop_password="hadoop"
      mysql_root_password="mysql"
      hive_metastore_password="hive"
      beeline_password="hive"
   fi

   kubectl create secret generic hive-credentials -n "${namespace}" \
      --from-literal=root-password="${root_password}" \
      --from-literal=hive-password="${hive_password}" \
      --from-literal=hadoop-password="${hadoop_password}" \
      --from-literal=mysql-root-password="${mysql_root_password}" \
      --from-literal=hive-metastore-password="${hive_metastore_password}" \
      --from-literal=beeline-password="${beeline_password}" >/dev/null
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
# Restore namespace credentials from a backup when present.
function restoreSecrets(){
   local namespace="$1"
   local backup_dir="$2"
   local secret_file="${backup_dir}/hive-credentials.secret.json"

   if [ -f "${secret_file}" ]; then
      kubectl apply -f "${secret_file}" >/dev/null
   else
      ensureSecrets "${namespace}"
   fi
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
   local namespace=""
   local service=""
   local active_list=""

   for target in $(overlays); do
       namespace="${target%_*}"
       service="${target#*_}"
       if kubectl get statefulsets -n "${namespace}" --selector="app=${service}" --no-headers 2>/dev/null | awk 'NF {found=1} END {exit !found}'; then
          active_list="${active_list}${target}"$'\n'
       fi
   done

   if [ -n "${arg}" ]; then
      echo "Active Overlays:"
   fi
   printf "%s" "${active_list}"
}
# Return success when the requested overlay exists in the project.
function overlayExists(){
   #
   # Checks whether the requested overlay exists exactly.
   #
   local target="$1"

   overlays | awk -v target="${target}" '$0 == target {found=1} END {exit !found}'
}
# Return success when the requested overlay is active in Kubernetes.
function overlayActive(){
   #
   # Checks whether the requested overlay is currently active exactly.
   #
   local target="$1"

   activeOverlays | awk -v target="${target}" '$0 == target {found=1} END {exit !found}'
}
# Wait until a component pod reports Ready.
function waitForReady(){
   local namespace="$1"
   local service="$2"

   kubectl wait --for=condition=Ready "pod/${service}-0" -n "${namespace}" --timeout=600s
}
# Wait until a component StatefulSet and pod are deleted.
function waitForStopped(){
   local namespace="$1"
   local service="$2"

   if kubectl get statefulset "${service}" -n "${namespace}" >/dev/null 2>&1; then
      kubectl wait --for=delete "statefulset/${service}" -n "${namespace}" --timeout=180s
   fi
   if kubectl get pod "${service}-0" -n "${namespace}" >/dev/null 2>&1; then
      kubectl wait --for=delete "pod/${service}-0" -n "${namespace}" --timeout=180s
   fi
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

   if overlayActive "${target}"; then
      echo "Overlay: ${target} is already ACTIVE, try stopping/restarting it"
      waitForReady "${namespace}" "${service}"
   else
      if overlayExists "${target}"; then
         echo "Starting Overlay: ${target} ..."
         ensureSecrets "${namespace}" || return 1
         #kubectl apply -k "${overlay_path}"
         kustomize build "${overlay_path}" --load-restrictor LoadRestrictionsNone | kubectl apply -f -
         waitForReady "${namespace}" "${service}"
      else
         echo "Overlay: ${target} DOES NOT EXIST"
      fi
   fi
}
# Stop one overlay/component while preserving PVCs.
function stopOverlay(){
   #
   # Expects an argument: overlay_<component>
   # Ex: mini_hivemetastore, mini_hiveserver2, etc
   #
   local target="$1"
   local namespace=""
   local service=""
   local type=""
   local name=""
   local resource_namespace=""

   if overlayActive "${target}"; then
      echo "Stopping Overlay: ${target} ..."
      namespace=${target%_*}
      service=${target#*_}
      if [ "${service}" == "hadoop" ]; then
         kubectl get sts,pods,cm,svc -n "${namespace}" --selector="app=${service}" --no-headers -o custom-columns=TYPE:.kind,NAME:.metadata.name,NAMESPACE:.metadata.namespace \
         | tr '[:upper:]' '[:lower:]'                     \
         | while read -r type name resource_namespace; do
            kubectl delete "${type}" "${name}" -n "${resource_namespace}" --force
         done
      else
        kubectl get sts,pods,cm,svc -n "${namespace}" --selector="app=${service}" --no-headers -o custom-columns=TYPE:.kind,NAME:.metadata.name,NAMESPACE:.metadata.namespace \
        | tr '[:upper:]' '[:lower:]'                     \
        | while read -r type name resource_namespace; do
            kubectl delete "${type}" "${name}" -n "${resource_namespace}" --force
        done
      fi
      waitForStopped "${namespace}" "${service}"
   else
      echo "Overlay: ${target} is already STOPPED or DOES NOT EXIST"
   fi
}
# Start all components in dependency order.
function startStack(){
   local namespace="$1"
   local component=""
   local components=()

   case "${namespace}" in
      standalone)
         components=(hive)
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

   if ! overlayActive "${target}"; then
      echo "Overlay: ${target} must be active"
      return 1
   fi
   waitForReady "${namespace}" "${service}"
}
# Stop Hive writer services and report which ones were stopped.
function stopHiveWriters(){
   local namespace="$1"
   local stopped_hms_var="$2"
   local stopped_hs2_var="$3"
   local hms_was_stopped=0
   local hs2_was_stopped=0

   if overlayActive "${namespace}_hiveserver2"; then
      stopOverlay "${namespace}_hiveserver2" || return 1
      hs2_was_stopped=1
   fi
   if overlayActive "${namespace}_hivemetastore"; then
      stopOverlay "${namespace}_hivemetastore" || return 1
      hms_was_stopped=1
   fi

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
   mkdir -p "${backup_dir}" || return 1
   echo "Creating standalone backup in: ${backup_dir}"
   backupSecrets "${namespace}" "${backup_dir}" || return 1

   if overlayActive "${namespace}_hive"; then
      stopOverlay "${namespace}_hive" || return 1
      was_active=1
   fi

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
   local status=0

   if [ -z "${backup_dir}" ]; then
      echo "Restore requires a backup directory"
      return 1
   fi
   if [ ! -f "${backup_dir}/standalone-hive.tgz" ]; then
      echo "Backup directory must contain standalone-hive.tgz"
      return 1
   fi

   requireNamespace "${namespace}" || return 1
   restoreSecrets "${namespace}" "${backup_dir}" || return 1
   echo "Restoring standalone backup from: ${backup_dir}"

   if overlayActive "${namespace}_hive"; then
      stopOverlay "${namespace}_hive" || return 1
      was_active=1
   fi

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
   )"

   stopStack "${namespace}" || return 1

   echo "Deleting standalone PVCs ..."
   kubectl delete pvc pvc-derby pvc-warehouse pvc-logs -n "${namespace}" --ignore-not-found || status=1

   if [ -n "${pv_names}" ]; then
      echo "Deleting matching PV objects ..."
      for pv in ${pv_names}; do
         kubectl delete pv "${pv}" --ignore-not-found || status=1
      done
   fi

   for pvc in pvc-derby pvc-warehouse pvc-logs; do
      if kubectl get pvc "${pvc}" -n "${namespace}" >/dev/null 2>&1; then
         kubectl wait --for=delete "pvc/${pvc}" -n "${namespace}" --timeout=180s || status=1
      fi
   done

   echo "Deleting namespace '${namespace}' ..."
   kubectl delete namespace "${namespace}" --ignore-not-found || status=1
   if kubectl get namespace "${namespace}" >/dev/null 2>&1; then
      kubectl wait --for=delete "namespace/${namespace}" --timeout=300s || status=1
   fi

   if [ "${status}" -eq 0 ]; then
      echo "Standalone cleanup complete. Run './hiveCtl.sh start ${namespace}' to recreate the namespace and empty PVCs."
   else
      echo "Standalone cleanup finished with errors. Inspect PVC/PV state before restarting."
   fi
   return "${status}"
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

   mkdir -p "${backup_dir}" || return 1
   echo "Creating backup in: ${backup_dir}"
   backupSecrets "${namespace}" "${backup_dir}" || return 1

   stopHiveWriters "${namespace}" stopped_hms stopped_hs2 || return 1

   ensureOverlayReady "${namespace}" hadoop || status=1
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
      # shellcheck disable=SC2016
      kubectl exec hadoop-0 -n "${namespace}" -- bash -lc '
         rm -rf /tmp/hdfs-backup /tmp/hdfs-backup.tgz
         mkdir -p /tmp/hdfs-backup
         for path in /opt /tmp /users /warehouse; do
            if hdfs dfs -test -e "${path}"; then
               hdfs dfs -get "${path}" /tmp/hdfs-backup/
            fi
         done
         tar -C /tmp -czf /tmp/hdfs-backup.tgz hdfs-backup
      ' || status=1
   fi

   if [ "${status}" -eq 0 ]; then
      kubectl cp "${namespace}/hadoop-0:/tmp/hdfs-backup.tgz" "${backup_dir}/hdfs-backup.tgz" || status=1
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

   requireNamespace "${namespace}" || return 1
   restoreSecrets "${namespace}" "${backup_dir}" || return 1

   echo "Restoring backup from: ${backup_dir}"
   stopHiveWriters "${namespace}" stopped_hms stopped_hs2 || return 1

   ensureOverlayReady "${namespace}" hadoop || status=1
   ensureOverlayReady "${namespace}" mysql || status=1

   if [ "${status}" -eq 0 ]; then
      echo "Restoring MySQL metastore database ..."
      # shellcheck disable=SC2016
      kubectl exec -i mysql-0 -n "${namespace}" -- \
         sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"' \
         < "${backup_dir}/mysql-hive.sql" || status=1
   fi

   if [ "${status}" -eq 0 ]; then
      echo "Restoring HDFS data ..."
      kubectl cp "${backup_dir}/hdfs-backup.tgz" "${namespace}/hadoop-0:/tmp/hdfs-backup.tgz" || status=1
   fi

   if [ "${status}" -eq 0 ]; then
      # shellcheck disable=SC2016
      kubectl exec hadoop-0 -n "${namespace}" -- bash -lc '
         rm -rf /tmp/hdfs-restore
         mkdir -p /tmp/hdfs-restore
         tar -C /tmp/hdfs-restore -xzf /tmp/hdfs-backup.tgz
         for path in /opt /tmp /users /warehouse; do
            hdfs dfs -rm -r -skipTrash "${path}" >/dev/null 2>&1 || true
         done
         for path in /tmp/hdfs-restore/hdfs-backup/*; do
            hdfs dfs -put "${path}" /
         done
         hdfs dfs -mkdir -p /tmp/hive /users/hive /warehouse/tablespace/managed/hive /warehouse/tablespace/external/hive
         hdfs dfs -chmod 777 / /tmp
         hdfs dfs -chmod -R 777 /tmp/hive
         hdfs dfs -chown -R hive:supergroup /tmp/hive /users/hive /warehouse /opt || true
      ' || status=1
   fi

   restartHiveWriters "${namespace}" "${stopped_hms}" "${stopped_hs2}" || status=1

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

   cat <<EOF
WARNING: cleanup will delete PVCs for namespace '${namespace}'.

This removes Kubernetes' bindings for:
  - mysql-mysql-0
  - pvc-hdfs

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
      | awk -v namespace="${namespace}" '($2 == "mysql-mysql-0" || $2 == "pvc-hdfs") && $3 == namespace {print $1}'
   )"

   stopStack "${namespace}" || return 1

   echo "Deleting PVCs ..."
   kubectl delete pvc mysql-mysql-0 pvc-hdfs -n "${namespace}" --ignore-not-found || status=1

   if [ -n "${pv_names}" ]; then
      echo "Deleting matching PV objects ..."
      for pv in ${pv_names}; do
         kubectl delete pv "${pv}" --ignore-not-found || status=1
      done
   fi

   if kubectl get pvc mysql-mysql-0 -n "${namespace}" >/dev/null 2>&1; then
      kubectl wait --for=delete pvc/mysql-mysql-0 -n "${namespace}" --timeout=180s || status=1
   fi
   if kubectl get pvc pvc-hdfs -n "${namespace}" >/dev/null 2>&1; then
      kubectl wait --for=delete pvc/pvc-hdfs -n "${namespace}" --timeout=180s || status=1
   fi

   echo "Deleting namespace '${namespace}' ..."
   kubectl delete namespace "${namespace}" --ignore-not-found || status=1
   if kubectl get namespace "${namespace}" >/dev/null 2>&1; then
      kubectl wait --for=delete "namespace/${namespace}" --timeout=300s || status=1
   fi

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
        restart)
          [[ -z "${2:-}" ]] && help && exit 1
          if [ -z "${3:-}" ]; then
             stopStack "$2"
             startStack "$2"
          else
             stopOverlay  "$2_$3"
             startOverlay "$2_$3"
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
