# Trino: reading Iceberg tables from the warehouse profile

Usage Notice: This project is not meant for commercial use without permission and proper credit.
Author: j.martinez.poblete@gmail.com

This runbook records how Trino was made to read the Iceberg table
`iceberg.default.iceberg_orc_3_1` (Hue and the Trino CLI), and the failure modes found along the way.
Keep it next to `warehouse-profile.md`.

## Symptoms and root causes

| Symptom in Hue / Trino | Root cause | Fix |
|---|---|---|
| `UNSUPPORTED_TABLE_TYPE: Cannot query Iceberg table` on the `hive` catalog | The `hive` connector cannot read Iceberg tables. | Query through an `iceberg` catalog. |
| `Unsupported file system scheme hdfs ... Supported schemes: []` | Trino had no HDFS client configuration. | Mount HDFS `core-site.xml` and `hdfs-site.xml`, reference them from the catalog. |
| `ICEBERG_INVALID_METADATA: Error accessing metadata file` | HDFS requests were made as SIMPLE (unauthenticated). The NameNode rejects them: `SIMPLE authentication is not enabled. Available:[TOKEN, KERBEROS]`. | Set `hive.hdfs.authentication.type=KERBEROS` with the Trino principal and keytab. |
| `NoMatchingRule: No rules applied to trino/...@WAREHOUSE.LAB` | Hadoop had no `auth_to_local` rule for the `trino/*` principal. | `hadoop.security.auth_to_local` in Trino's own `core-site.xml`. |
| `krb5.kdc and krb5.realm both must be set or neither` | Java Kerberos needs both system properties. | Set `krb5.realm` and `krb5.kdc` together in `jvm.config`. |
| `no tgt; cannot get creds` / `No service creds` | The JVM defaulted to realm `EXAMPLE.COM` and could not find the `WAREHOUSE.LAB` TGT. | Pin the realm in `jvm.config`. |
| `MISSING_CATALOG_NAME` in Hue's Trino Cassandra editor | Hue's native Trino connector builds the session from the user's saved profile. Interpreter `catalog`/`schema` options are not applied. | Select the database in Hue's left panel, or use fully qualified names. |
| `INVALID_SESSION_PROPERTY: 'schema'` / `'catalog' does not exist` | `catalog` and `schema` are not Trino session properties. Do not seed them into the session. | Do not patch the session; use the database picker. |
| `'Cursor' object has no attribute 'poll'` (Trino interpreter) | Hue's SQLAlchemy connector calls `cursor.poll()`, which the SQLAlchemy cursor lacks. | Use Hue's native `trino` interface (`interface=trino`). |

## Where the configuration lives

All Trino configuration is in `overlays/warehouse/trino/`:

- `iceberg.properties`: the `iceberg` catalog. Metastore settings, `hive.config.resources`, and HDFS Kerberos settings.
- `hive.properties`: the `hive` catalog. Unchanged. Hive is not modified by this work.
- `trino-hdfs` ConfigMap (generated from `hdfs/core-site.xml` and `hdfs/hdfs-site.xml`): Trino's own HDFS client config, mounted at `/etc/trino/hdfs`.
- `jvm.config`: `-Djava.security.krb5.conf`, `-Djava.security.krb5.realm=WAREHOUSE.LAB`, `-Djava.security.krb5.kdc=krb5kdc.warehouse.svc`.
- `service.yaml`: the `trino` Service is a NodePort on `30080`, so the UI is reachable through the bastion at `http://34.234.33.208:30080/ui/`.

The shared `hivemetastore/core-site.xml` is intentionally left unchanged. Trino has its own copy with the `auth_to_local` rule.

## Iceberg catalog (`iceberg.properties`), key lines

```properties
connector.name=iceberg
iceberg.catalog.type=hive_metastore
hive.metastore.uri=thrift://hivemetastore-0.hivemetastore-headless.warehouse.svc.cluster.local:9083
hive.metastore.authentication.type=KERBEROS
hive.metastore.service.principal=hive/_HOST@WAREHOUSE.LAB
hive.metastore.client.principal=trino/_HOST@WAREHOUSE.LAB
hive.metastore.client.keytab=/etc/trino/service.keytab
hive.config.resources=/etc/trino/hdfs/core-site.xml,/etc/trino/hdfs/hdfs-site.xml
hive.hdfs.authentication.type=KERBEROS
hive.hdfs.trino.principal=trino/_HOST@WAREHOUSE.LAB
hive.hdfs.trino.keytab=/etc/trino/service.keytab
```

## Verifying

From the coordinator:

```bash
kubectl -n warehouse exec trino-coordinator-0 -- trino --execute "SHOW CATALOGS"
kubectl -n warehouse exec trino-coordinator-0 -- trino --execute "SELECT COUNT(*) FROM iceberg.default.iceberg_orc_3_1"
```

Expected: `iceberg` is listed, and the count is `10400`.

In Hue (Trino editor, no database selected):

```sql
SELECT * FROM iceberg.default.iceberg_orc_3_1 LIMIT 10;
```

## Debugging tips

- The Trino coordinator log often does **not** include the exception. The Trino UI query page (`http://34.234.33.208:30080/ui/`) shows the full stack trace. Use it first.
- The Trino image (Hummingbird OS) has no `apt-get`, `python3`, `grep`, `sed`, `awk`, or `wget`. Diagnostic work needs a separate pod, for example `debian:bookworm-slim` with `krb5-user`, or `apache/hadoop:3` for HDFS. Delete the diagnostic pod afterwards, because it mounts a keytab.
- To check Kerberos from a client, use the same keytab and `krb5.conf` as Trino:

  ```bash
  kinit -kt /keytabs/trino-coordinator-0.keytab trino/trino-coordinator-0.trino-headless.warehouse.svc.cluster.local@WAREHOUSE.LAB
  hdfs dfs -ls hdfs://nameservice:8020/warehouse/tablespace/external/hive/iceberg_orc_3_1/metadata/
  ```

## Open items

- The `hive` catalog does not set `hive.hdfs.authentication.type`. Plain (non-Iceberg) Hive table reads through Trino may need the same setting. Not yet tested, because the warehouse has no non-Iceberg table in `hive.default` to test against.
- Trino's Iceberg read was stable only after the HDFS Kerberos setting. Re-verify after any change to `jvm.config` or `iceberg.properties`.
- The Trino UI has no authentication configured. It is reachable on the bastion at port `30080` by anyone who can reach it.
