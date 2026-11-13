# Cassandra auth design: Kerberos ring plus Trino PLAIN path

> Usage Notice: This project is not meant for commercial use without permission and proper credit.
> Author: j.martinez.poblete@gmail.com

Status: **DRAFT for review. No code or cluster changes have been made.**

## Goal

- All three Cassandra nodes (`cassandra-0..2`, DC **`warehouse`**) stay Kerberos-only for human and service clients.
- The Trino PLAIN principal is a **dedicated bare principal `trino@WAREHOUSE.LAB`** (option 1). It does not reuse the per-host `trino/trino-*` service principals, which are tied to pod hostnames.
- Trino (which cannot speak GSSAPI) can query the same ring through a password path.
- No OpenLDAP, and no separate password-only Cassandra tier (`cassandra-pw`) for Trino.
- Cassandra stays on 4.1.12. Cassandra 5.0 is out of scope (the Kerberos authenticator in this repo targets 4.1.x only).

## Current state (verified in the repo and the cluster)

- `docker/cassandra-kerberos/authenticator-src/base/.../BaseKerberosAuthenticator.java` implements `IAuthenticator` with one SASL negotiator, hardcoded to `SASL_MECHANISM = "GSSAPI"` (line 53).
- `newSaslNegotiator` always builds a `KerberosSaslAuthenticator` backed by a GSSAPI `SaslServer`. PLAIN is not offered.
- Trino's `cassandra` catalog connects only to `cassandra-pw-headless` with `cassandra.security=PASSWORD`, so Trino never reaches the ring.

## Proposed design

### 1. Multi-mechanism authenticator

A wrapper `IAuthenticator` (new class, e.g. `DualMechanismKerberosAuthenticator`) that:

- Advertises **GSSAPI** and **PLAIN** from `newSaslNegotiator`.
- Routes GSSAPI to the existing `KerberosSaslAuthenticator` with no behavior change.
- Routes PLAIN to a password check (see §2), and only for the allowed principal (see §3).
- Keeps `legacyAuthenticate` disabled, so no non-SASL password path exists.

Deployment: same image family (`hive-on-k8s/cassandra-kerberos`), new tag (for example `4.1.12-dual`), so the current `4.1.12` image stays available for rollback. Rolled out to one node first on a scratch keyspace, then the ring.

### 2. PLAIN credential check

- Validate the username and password with JAAS `Krb5LoginModule` against the MIT KDC (`krb5kdc-0` in the `warehouse` namespace), using the same `krb5.conf` (`rdns = false`) as the nodes.
- The password is the Kerberos password of the principal. Cassandra never stores it.
- Requires the KDC to be reachable from every Cassandra node (PLAIN only; GSSAPI works from cached tickets).

### 3. Restrict PLAIN to one principal

- Only `trino@WAREHOUSE.LAB` may authenticate with PLAIN. Any other principal sent over PLAIN is rejected, and the rejection is logged.
- Human users keep GSSAPI only, so a password path does not become a second way in for everyone.
- The allowed principal is set in `cassandra.yaml` (a dedicated option), not hardcoded.

### 4. Role mapping

- Each Kerberos principal maps to a Cassandra role with the same name, as today (`getCassandraUser`). Example: `jpoblete@WAREHOUSE.LAB`.
- Role name is the full principal (`trino@WAREHOUSE.LAB`), the same convention as Kerberos users. The PLAIN username `trino` resolves to the KDC principal `trino@WAREHOUSE.LAB` and the role of the same name, with no translation table.
- `trino@WAREHOUSE.LAB` has **read-write data access** (`SELECT`, `MODIFY`) on the keyspaces Hue and Trino must use for DML. It is **not** a superuser.
- **DDL (CREATE/ALTER/DROP KEYSPACE and TABLE)** for `trino` is granted explicitly, not implied by `MODIFY`. Scope it to the keyspaces Hue manages (for example `CREATE` on `ALL KEYSPACES` is not granted; grant per keyspace).
- The `cassandra` superuser remains for administrative tasks (role and grant management, keyspace replication changes).

### 5. Trino configuration

- `overlays/warehouse/trino/cassandra.properties` points at the ring pods (headless service `cassandra-headless`), not `cassandra-pw`.
- `cassandra.security=PASSWORD`, with the username `trino@WAREHOUSE.LAB` and its password from a Secret (never in the repo).
- Remove the `cassandra-pw` StatefulSet and its Trino Secret once cutover is verified.

## Trade-offs

| Concern | Impact | Mitigation |
|---|---|---|
| Kerberos password used as the `trino` credential | Long-lived credential; a KDC password is more sensitive than a ticket | Store in a Secret; rotate with a documented procedure; `trino` role is data-only (no superuser); PLAIN restricted to this one principal |
| PLAIN validated against KDC | KDC outage blocks new PLAIN logins | Trino connections are pooled; GSSAPI unaffected; monitor KDC |
| Custom auth code | Maintenance and audit burden | Limit to one class; unit-test PLAIN, GSSAPI, and rejection of other principals |
| Cassandra 4.1 internals | Upgrades need re-validation | Stay on 4.1.12; 5.0 needs its own project |
| Two-mechanism negotiation | Client compatibility | Test with cqlsh GSSAPI, `cql-krb.py`, and the Trino Cassandra connector |

## Known risk: no rotation on `trino@WAREHOUSE.LAB`

By decision, the `trino` principal is created with **no password policy** (never expires, no forced rotation). This is accepted for now. Revisit before production hardening: attach a KDC policy with a rotation interval and document the rotation procedure for the `cassandra-krb-trino` Secret.

## Decisions

0. **Datacenter name is `warehouse`.** The live ring is currently `datacenter1` (`SimpleSnitch`). Renaming the DC is a real change and needs a snitch and `cassandra-rackdc.properties` migration, handled as a separate, reviewed step before the rolling restart.

1. **Kerberos password is acceptable** as the Trino credential (`trino@WAREHOUSE.LAB`).
2. **`trino` is read-write for Hue DML/DDL**, with DDL granted per keyspace and no superuser.
3. **`cassandra-pw` is retired after cutover.** Its only remaining use is as a rollback path during validation, and it's a single unreplicated node.

## Open questions for review

- Keep `cassandra-pw` as a rollback path until the dual-mechanism image has passed the test plan, then remove it? (Proposed: yes.)

## Test plan (before any ring change)

1. Build `4.1.12-dual`, run one pod with a scratch data directory.
2. GSSAPI: `cql-krb.py` with a user ticket succeeds, same as today.
3. PLAIN: `trino@WAREHOUSE.LAB` succeeds; a non-allowed principal is rejected.
4. Trino: point a test catalog at the scratch pod and query a `SELECT` on the scratch keyspace.
5. Only then roll the dual image to `cassandra-0..2`, one node at a time, checking `nodetool status` between restarts.
