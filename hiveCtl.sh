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

   names="$(kubectlNames statefulsets -n "${target%_*}" --selector="app=${target#*_}")" || return 2
   [ -n "${names}" ]
}
# Wait until every replica of a component StatefulSet reports Ready.
function waitForReady(){
   local namespace="$1"
   local service="$2"

   kubectl rollout status "statefulset/${service}" -n "${namespace}" --timeout=600s
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

   waitForDeleted 180 statefulsets,pods -n "${namespace}" --selector="app=${service}"
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

   overlayActive "${target}"
   case $? in
      0)
         echo "Overlay: ${target} is already ACTIVE, try stopping/restarting it"
         waitForReady "${namespace}" "${service}"
         ;;
      1)
         if overlayExists "${target}"; then
            echo "Starting Overlay: ${target} ..."
            ensureSecrets "${namespace}" || return 1
            #kubectl apply -k "${overlay_path}"
            kustomize build "${overlay_path}" --load-restrictor LoadRestrictionsNone | kubectl apply -f -
            waitForReady "${namespace}" "${service}"
         else
            echo "Overlay: ${target} DOES NOT EXIST"
         fi
         ;;
      *)
         return 1
         ;;
   esac
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
   resources="$(kubectlNames sts,pods,cm,svc -n "${namespace}" --selector="app=${service}")" || return 1
   # Not forced: each pod gets its termination grace period to shut its services down cleanly
   for resource in ${resources}; do
      kubectl delete "${resource}" -n "${namespace}" --wait=false || return 1
   done
   waitForStopped "${namespace}" "${service}"
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
      llap)
         components=(hadoop mysql zookeeper hivemetastore llapdaemon hiveserver2)
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
         components=(hiveserver2 llapdaemon hivemetastore zookeeper mysql hadoop)
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

   restoreSecrets "${namespace}" "${backup_dir}" || return 1

   echo "Restoring backup from: ${backup_dir}"
   stopHiveWriters "${namespace}" stopped_hms stopped_hs2 || return 1

   # Storage that isn't running is started now and the rest of the stack after the restore,
   # so on a fresh namespace the Metastore never creates an empty schema first
   for component in hadoop mysql; do
      overlayActive "${namespace}_${component}"
      case $? in
         0) waitForReady "${namespace}" "${component}" || status=1 ;;
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
   )" || return 1

   stopStack "${namespace}" || return 1

   echo "Deleting PVCs ..."
   kubectl delete pvc mysql-mysql-0 pvc-hdfs -n "${namespace}" --ignore-not-found || status=1

   if [ -n "${pv_names}" ]; then
      echo "Deleting matching PV objects ..."
      for pv in ${pv_names}; do
         kubectl delete pv "${pv}" --ignore-not-found || status=1
      done
   fi

   waitForDeleted 180 pvc/mysql-mysql-0 pvc/pvc-hdfs -n "${namespace}" || status=1

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
