#!/usr/bin/env bash
# Usage Notice: This project is not meant for commercial use without permission and proper credit.
# Author: j.martinez.poblete@gmail.com
# Build Ranger Hive plugin JARs into ./dist/jars/ for docker/hive-ranger/Dockerfile.
# Admin stays on apache/ranger:2.4.0; hive-agent is built from RANGER_GIT_REF (default master) for Hive 4.x.
set -euo pipefail

RANGER_GIT_REF="${RANGER_GIT_REF:-master}"
RANGER_ADMIN_IMAGE="${RANGER_ADMIN_IMAGE:-apache/ranger:2.4.0}"
RANGER_ADMIN_VERSION="${RANGER_ADMIN_VERSION:-2.4.0}"
MAVEN_IMAGE="${MAVEN_IMAGE:-maven:3.9-eclipse-temurin-17}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="${SCRIPT_DIR}/dist"
SRC="${DIST}/.build/ranger"
JARS="${DIST}/jars"
REF_STAMP="${DIST}/.build/ranger-git-ref"

mkdir -p "${DIST}/.build"

ensure_ranger_source(){
  local need_clone=0

  if [ ! -f "${SRC}/pom.xml" ]; then
    need_clone=1
  elif [ ! -f "${REF_STAMP}" ] || [ "$(cat "${REF_STAMP}")" != "${RANGER_GIT_REF}" ]; then
    need_clone=1
  fi
  if [ "${need_clone}" -eq 1 ]; then
    echo "Cloning Ranger ref ${RANGER_GIT_REF} ..."
    rm -rf "${SRC}"
    git clone --depth 1 --branch "${RANGER_GIT_REF}" https://github.com/apache/ranger.git "${SRC}"
    printf '%s\n' "${RANGER_GIT_REF}" > "${REF_STAMP}"
  fi
}

run_mvn(){
  local modules="$1"
  shift || true
  if command -v mvn >/dev/null 2>&1; then
    (cd "${SRC}" && mvn -pl "${modules}" -am package -DskipTests -Drat.skip=true "$@")
  else
    echo "Using Maven Docker image (${MAVEN_IMAGE}) ..."
    docker run --rm \
      -v "${SRC}:/work" \
      -v "${HOME}/.m2:/root/.m2" \
      -w /work \
      "${MAVEN_IMAGE}" \
      mvn -pl "${modules}" -am package -DskipTests -Drat.skip=true "$@"
  fi
}

# All ranger-*.jar produced by the Maven reactor (hive-agent -am), including common-utils and audit.
copy_built_ranger_jars(){
  while IFS= read -r jar; do
    [ -n "${jar}" ] || continue
    cp -f "${jar}" "${JARS}/"
  done < <(find "${SRC}" \( -path '*/target/ranger-*.jar' -o -path '*/target/ugsync-util-*.jar' \) \
    ! -name '*-tests.jar' ! -name '*-sources.jar' ! -name '*-javadoc.jar' 2>/dev/null)
}

run_mvn_copy_deps(){
  local out_dir="$1"
  shift
  rm -rf "${out_dir}"
  mkdir -p "${out_dir}"
  if command -v mvn >/dev/null 2>&1; then
    (cd "${SRC}" && mvn -pl hive-agent dependency:copy-dependencies -DskipTests \
      -Dmdep.copyDependencies=true -DoutputDirectory="${out_dir}" "$@")
  else
    docker run --rm \
      -v "${SRC}:/work" \
      -v "${HOME}/.m2:/root/.m2" \
      -v "${out_dir}:/out" \
      -w /work \
      "${MAVEN_IMAGE}" \
      mvn -pl hive-agent dependency:copy-dependencies -DskipTests \
        -Dmdep.copyDependencies=true -DoutputDirectory=/out "$@"
  fi
}

# Ranger 3.x REST client (RangerRESTClient) uses Glassfish Jersey 2 + HK2, not Jersey 1 from Admin 2.4.
copy_hive_agent_jersey2_deps(){
  local dep_dir="${JARS}/.jersey2-deps"
  echo "Copying hive-agent Jersey 2 / HK2 runtime jars ..."
  run_mvn_copy_deps "${dep_dir}" -q \
    -DincludeGroupIds=org.glassfish.jersey,org.glassfish.hk2,jakarta.ws.rs,org.glassfish \
    -DexcludeArtifactIds=jersey-json
  shopt -s nullglob
  for jar in "${dep_dir}"/*.jar; do
    cp -f "${jar}" "${JARS}/"
  done
  shopt -u nullglob
  rm -rf "${dep_dir}"
}

copy_hive_agent_runtime_deps(){
  case "${RANGER_COPY_MVN_DEPS:-0}" in
    1|true|yes) ;;
    *) return 0 ;;
  esac
  local dep_dir="${JARS}/.mvn-deps"
  echo "Copying full hive-agent Maven runtime deps (RANGER_COPY_MVN_DEPS) ..."
  run_mvn_copy_deps "${dep_dir}" -q
  shopt -s nullglob
  for jar in "${dep_dir}"/*.jar; do
    base="$(basename "${jar}")"
    case "${base}" in
      hive-*.jar|hadoop-*.jar|tez-*.jar|lib*.jar) continue ;;
    esac
    cp -f "${jar}" "${JARS}/"
  done
  shopt -u nullglob
  rm -rf "${dep_dir}"
}

copy_admin_rest_jars(){
  local admin_lib="${JARS}/.admin-lib"
  rm -rf "${admin_lib}"
  mkdir -p "${admin_lib}"
  cid="$(docker create "${RANGER_ADMIN_IMAGE}")"
  docker cp "${cid}:/opt/ranger/ranger-${RANGER_ADMIN_VERSION}-admin/ews/webapp/WEB-INF/lib/." "${admin_lib}/"
  docker rm "${cid}" >/dev/null
  # Legacy Codehaus Jackson / misc from Admin 2.4 (Jersey 1.x omitted — plugin uses Jersey 2 from Maven).
  for pattern in \
    gethostname4j*.jar jackson-core-asl-*.jar jackson-mapper-asl-*.jar \
    jackson-jaxrs-*.jar jackson-xc-*.jar \
    http*.jar jetty*.jar noggit*.jar jna*.jar solr-solrj*.jar; do
    find "${admin_lib}" -name "${pattern}" -exec cp -f {} "${JARS}/" \;
  done
  rm -rf "${admin_lib}"
}

ensure_ranger_source

echo "Building Ranger Hive plugin (hive-agent) from ${RANGER_GIT_REF} ..."
run_mvn "hive-agent"

rm -rf "${JARS}"
mkdir -p "${JARS}"

copy_built_ranger_jars
copy_hive_agent_jersey2_deps
copy_hive_agent_runtime_deps
copy_admin_rest_jars

find "${JARS}" -name 'hive-*.jar' -delete 2>/dev/null || true
find "${JARS}" -name 'hadoop-*.jar' -delete 2>/dev/null || true
find "${JARS}" -name 'lib*.jar' -delete 2>/dev/null || true

count="$(find "${JARS}" -maxdepth 1 -name '*.jar' | wc -l | tr -d ' ')"
if [ "${count}" -lt 5 ]; then
  echo "Too few plugin jars in ${JARS} (got ${count})" >&2
  exit 1
fi
echo "Wrote ${count} jars to ${JARS}/"
ls -lh "${JARS}" | head -25
