# Hive + Ranger 2.4 plugin image (`secure` Phase 2)

Stock **`apache/hive:nightly`** does not ship Ranger jars. Build a local image that layers the **Ranger 2.4.0 Hive plugin** onto nightly.

## Build

```bash
cd docker/hive-ranger
./build-ranger-hive-plugin.sh          # git + Maven (Java 17); hive-agent from Ranger master (Hive 4.x)
docker build -t hive-on-k8s/hive-ranger:2.4.0-nightly .
```

**Apple Silicon:** Ranger **2.4.0** plugin build is Java-only (any arch). The Hive base remains **`apache/hive:nightly`** (often arm64 on Mac). **`hiveCtl.sh start secure hiveserver2`** with **`HIVECTL_SECURE_RANGER_HS2=1`** runs **`kind load docker-image`** for the tag when it exists locally (skip with **`HIVECTL_KIND_LOAD=0`**).

## Deploy on `secure`

1. Ranger Admin running (`./hiveCtl.sh start secure ranger`).
2. In Ranger UI, create a **Hive** service named **`secure_hive`** (must match `ranger-hive-security.xml`).
3. Enable HS2 overlay with the custom image:

```bash
# Run hiveCtl from the repo root (not docker/hive-ranger).
export HIVE_RANGER_IMAGE=hive-on-k8s/hive-ranger:2.4.0-nightly   # default
HIVECTL_SECURE_RANGER_HS2=1 ./hiveCtl.sh restart secure hiveserver2
```

After `docker build`, HS2 pods on Kind still use the **previous** image until `hiveCtl` runs **`kind load docker-image`** (automatic on start/restart when `HIVECTL_SECURE_RANGER_HS2=1`) and the StatefulSet pod is recreated.

4. Smoke: Beeline with Kerberos; verify policies deny/allow as configured.

**Beeline on HS2 pods:** The standalone Beeline jar lives under **`/opt/hive/beeline-client/`** (kept off the HS2 server classpath). This image replaces **`/opt/hive/bin/beeline`** to invoke that jar directly.

See [docs/secure-ranger.md](../../docs/secure-ranger.md) for architecture and policy tests.
