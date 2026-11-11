# Warehouse profile

> Usage Notice: This project is not meant for commercial use without permission and proper credit.
> Author: j.martinez.poblete@gmail.com

The `warehouse` profile is a Kerberos-secured data warehouse in the `warehouse` namespace, realm `WAREHOUSE.LAB`. It builds on the [`secure`](secure-profile.md) Hive stack and adds **Cassandra** and **Trino**, both queryable from **Hue**.

## Components

| Layer | Component | Image / source |
|-------|-----------|----------------|
| KDC | MIT Kerberos | `debian:bookworm-slim` (overlay `overlays/warehouse/krb5kdc`, host list `warehouse-hosts.list`) |
| HDFS | 1 NameNode + 3 DataNodes, `dfs.replication=3` | `apache/hadoop:3.4.1` |
| ZooKeeper | SASL/Kerberos | overlay `overlays/warehouse/zookeeper` |
| Cassandra (Kerberos ring) | 3 nodes, Kerberos-only auth | `hive-on-k8s/cassandra-kerberos:4.1.12` (custom, see below) |
| Cassandra (password node) | 1 node, password auth, read by Trino | `hive-on-k8s/cassandra-password:4.1.12` (custom) |
| MySQL | Hive metastore + Ranger DB | overlay `overlays/warehouse/mysql` |
| Ranger | Admin (Hive policies) | overlay `overlays/warehouse/ranger` |
| Hive | Metastore + HiveServer2 (Kerberos), LLAP | `apache/hive:nightly` |
| Trino | 1 coordinator + 2 workers, Trino 484 | `trinodb/trino:484` |
| Hue | Hive + Trino interpreters | `hive-on-k8s/hue-trino` (custom, see below) |

## Startup and shutdown order

Startup: KDC → ZooKeeper / Hadoop (1 NN + 3 DN) → Cassandra → MySQL → Ranger → Hive Metastore → HiveServer2 → Trino → Hue.
Shutdown is the reverse.

```bash
./hiveCtl.sh start warehouse
./hiveCtl.sh stop warehouse
```

## Custom images

These are our own builds. Each Dockerfile or source file carries an in-file label stating whether it is original or a modification of upstream.

### `hive-on-k8s/cassandra-kerberos:4.1.12` (`docker/cassandra-kerberos`)

Cassandra 4.1.12 with the Kerberos SASL authenticator. Built from `authenticator-src/` (Maven reactor: `base` + `cassandra-4.1`, shaded into one jar).

- `base/.../BaseKerberosAuthenticator.java`: **unmodified** upstream (Instaclustr `cassandra-kerberos` v4.1.0-1.0.0).
- `cassandra-4.1/.../KerberosAuthenticator.java`: **modified** — the role lookup passes `Dispatcher.RequestTime.forImmediateExecution()` instead of `System.nanoTime()`, required by Cassandra 4.1.12 (the upstream 4.1.0 jar fails with `NoSuchMethodError` on `SelectStatement.execute`).
- `docker-entrypoint-krb5.sh`: verifies reverse DNS, writes the Kerberos properties, runs `kinit` for the `cassandra` service principal.
- `cql-krb.py`: a GSSAPI CQL client that canonicalises peer IPs to FQDNs so the principal matches the KDC.

The unused upstream jar `cassandra-kerberos-4.1.0-1.0.0.jar` is kept out of the image; it is not referenced by the build.

### `hive-on-k8s/cassandra-password:4.1.12` (`docker/cassandra-password`)

A single Cassandra node with `PasswordAuthenticator`. Trino connects to this node, because the Trino Cassandra connector only supports password auth (`cassandra.security=PASSWORD`). The Kerberos ring stays Kerberos-only. The config is baked into the image because the stock entrypoint `chown`s mounted config, which fails on a read-only ConfigMap.

Credentials are **never** written into a ConfigMap or the repo. Trino reads them from the Secret `cassandra-pw-trino` (keys `username`, `password`) and injects them into its catalog file at startup.

### `hive-on-k8s/hue-trino` (`docker/hue-trino`)

`gethue/hue:latest` bundles SQLAlchemy 1.3.8, which cannot load `sqlalchemy-trino`. This image upgrades SQLAlchemy to **1.4.x** and installs `sqlalchemy-trino==0.5.0` and `trino==0.329.0` into Hue's own venv (`/usr/share/hue/build/env`). It is built for `linux/amd64` because the upstream base is amd64 only.

```bash
docker build --platform linux/amd64 -t hive-on-k8s/hue-trino:latest docker/hue-trino
kind load docker-image hive-on-k8s/hue-trino:latest --name desktop
```

## Hue → Trino and Cassandra

Hue has a `trino` interpreter (`sqlalchemy` interface, `trino://…/hive/default`). Cassandra is reached through Trino's `cassandra` catalog, not directly from Hue.

Verified: from the Hue pod, SQLAlchemy lists the `hive` schema (`default`) and the `cassandra` catalog's keyspaces (including `system_auth`). HiveServer2 (10000) and Trino (8080) are reachable over TCP from Hue.

Not yet verified: running a query end to end through Hue's UI for both Hive and Trino.

## Cassandra Kerberos ring vs. Trino (design decision)

Decision: **the three Kerberos Cassandra nodes (`cassandra-0..2`) stay Kerberos-only.** Trino's Cassandra connector supports only `PASSWORD` auth, so it cannot read the ring. Trino therefore reads only the single password node (`cassandra-pw`, cluster `warehouse-pw`).

Consequences:

- Tables on the Kerberos ring (RF=3, `QUORUM`) are **not visible** to Trino or Hue.
- Tables that Trino or Hue must query are created on **`cassandra-pw`**, which is a single unreplicated node, so they use `replication_factor: 1` and have no node-loss tolerance.
- `cassandra-pw` is only reachable from Trino through the `trino_pw` role, which has **no CREATE permission**. Schema changes on `cassandra-pw` require the `cassandra-pw-superuser` credentials (Secret `cassandra-pw-superuser`).
- After creating a keyspace or table as the superuser, grant Trino read access, for example `GRANT SELECT ON KEYSPACE <ks> TO trino_pw;`. Without it, Trino returns `User trino_pw has no SELECT permission`.

Test table on the password node (Trino-visible):

```text
keyspace: demo            (SimpleStrategy, RF=1)
table:    demo.dummy_4    (c1 int PK, c2 uuid, c3 text, c4 text)
rows:     10000           (verified via cqlsh and via Trino: cassandra.demo.dummy_4)
grant:    SELECT ON KEYSPACE demo TO trino_pw
```

Loaded with the superuser role, using `/tmp/pw_table.cql` generated by the snippet in the commit history for this change. Credentials are read from Kubernetes Secrets at run time and never stored in the repo.

Kerberos ring test keyspace `rftest` (RF=3) was used to verify one-node-down behavior at `QUORUM` and was dropped afterwards.

## Ports and access

| Service | Port | Note |
|---------|------|------|
| Hue | `8889` (port-forward) · NodePort `30890` | Own range; does not conflict with `secure` (`8888` / `30889`) |
| HiveServer2 | Thrift `31040`, HTTP `31041`, Web UI `31042` (NodePorts) · forwards `11400` / `11401` / `11402` | Own range; `secure` uses `31030–31032` / `11300–11302` |

`secure` and `warehouse` can run at the same time on the port side. Both still compete for the same cluster CPU, memory, and disk; see the hardware notes in the README.

## Secrets

| Secret | Keys | Purpose |
|--------|------|---------|
| `kerberos-keytabs` | per-pod keytabs | Kerberos principals (synced from the KDC PVC by `hiveCtl`) |
| `cassandra-pw-trino` | `username`, `password` | Trino → password-node Cassandra. Created out-of-band, not in the repo. |

Keytab resync for this profile: `./hiveCtl.sh resync-keytabs warehouse` refreshes the Secret. Restart the Kerberos pods in `warehouse` afterward; only `secure` restarts automatically.

## Status

| Item | State |
|------|-------|
| Kerberos ring (3 Cassandra nodes), authenticated query | Verified |
| Trino (coordinator + 2 workers), Hive and Cassandra catalogs | Verified |
| Hue SQLAlchemy → Trino (`hive`, `cassandra` catalogs) | Verified |
| Hue → HiveServer2 TCP | Verified |
| Hue → Hive query through UI | Not yet verified |
| Hue → Trino query through UI | Not yet verified |
| Fresh cluster bring-up from zero | Not yet verified |
| Cloudera / EC2 deployment | Not started |
