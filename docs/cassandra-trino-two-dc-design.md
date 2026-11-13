# Cassandra for Trino: two-datacenter design (mTLS + PASSWORD)

> Usage Notice: This project is not meant for commercial use without permission and proper credit.
> Author: j.martinez.poblete@gmail.com

Status: **DRAFT for review. No code or cluster changes have been made.**
Supersedes: `docs/cassandra-trino-auth-design.md` (dual-mechanism PLAIN authenticator), which is abandoned.

## Why this replaces the dual-mechanism design

The custom PLAIN authenticator was blocked at the last step. The KDC accepted the `trino` password, but Cassandra's internal role read inside the authenticator returned no rows, so the login was refused. Several causes were ruled out, and the root cause was not found. Trino's Cassandra connector only supports `cassandra.security=PASSWORD`, so Trino needs a password path that Cassandra accepts natively. Instead of maintaining a custom authenticator, this design uses the stock password authenticator on an isolated datacenter, with mutual TLS in front.

## Goal

- `warehouse` (DC, RF=3, `cassandra-0..2`): stays Kerberos-only for all human and service clients. Unchanged.
- `trino` (DC, RF=1, `cassandra-trino`): read-only replica of the keyspaces Trino needs. Reachable only by clients presenting a valid client certificate. Trino authenticates with `cassandra.security=PASSWORD`.
- No custom authenticator code in the Trino path.

## Topology

| DC | Nodes | RF | Auth | Clients |
|---|---|---|---|---|
| `warehouse` | `cassandra-0`, `cassandra-1`, `cassandra-2` | 3 | Kerberos (GSSAPI) | Hue, Hive, CQL over Kerberos |
| `trino` | `cassandra-trino` (one node) | 1 | PasswordAuthenticator | Trino only, over mTLS |

Replication: every keyspace is replicated to both DCs, for example `NetworkTopologyStrategy` with `warehouse: 3, trino: 1`.

## Authentication and transport

- **Trino to `trino` DC:** `cassandra.security=PASSWORD` with a dedicated Cassandra role, plus `cassandra.tls.enabled=true` with a client keystore (`cassandra.tls.keystore-path`) and a CA truststore (`cassandra.tls.truststore-path`). Both are mounted from Kubernetes Secrets.
- **Mutual TLS:** the `trino` DC's `server_encryption_options` set `require_client_auth: true`, so a node rejects any client without a certificate signed by the internal CA.
- **Password:** the Cassandra role's password is stored in a Secret and is not committed. It is set by a provisioning step, not in `cassandra.yaml`.

## Replication and write model (decided)

- **Trino is read-write.** Hue has no direct Cassandra access; it reaches Cassandra only through Trino. Writes from Trino land on the `trino` DC and replicate to `warehouse`.
- **Both DCs are writable and replicate to each other.** Replication is asynchronous, so Trino can read data that is slightly behind `warehouse`.
- **Conflicts:** last-write-wins per cell. Concurrent writes to the *same row* from both DCs can silently overwrite each other.
- **Operating rule:** the collision risk is low because clients reach Cassandra only through Hue and Trino, not through CQL from the bastion. Keep writes to a given row on one DC at a time. This rule must be documented for users.
- **RF=1 on `trino`:** a single node, so losing it loses that DC's copy until it is rebuilt. Accepted for test; risk is low because everything is supposed to be replicated between datacenters.
- **`system_auth` is replicated** to `trino`, so the role lives in one place and cannot drift. Accepted downside: if the `trino` DC is compromised, its copy of the role and grant data is exposed. Mitigated by the 2-way TLS requirement.

## Prerequisites (must be done in order)

1. **Rename the ring DC `datacenter1` to `warehouse`.** The live ring is `SimpleSnitch` in `datacenter1`. This needs a snitch change (`GossipingPropertyFileSnitch` with `cassandra-rackdc.properties`) and a reviewed rolling restart. Separate step, with a backup first.
2. **Add the `trino` DC node** (`cassandra-trino`) with its own rack and data PVC.
3. **Create the internal CA** and issue: the server certificate for `cassandra-trino`, and a client certificate for Trino. Store all in Secrets.
4. **Create the Cassandra role** `trino@WAREHOUSE.LAB` with `PASSWORD`, and make it a **superuser** (decision 2025-11-13). Superuser lets Trino and Hue run DDL/DML across all keyspaces, including `DROP`, which the Trino Cassandra connector otherwise disables. Trade-off: the role can alter or drop any keyspace and read system data. Acceptable for this non-production cluster; revisit the scoped-grant model before any production rollout. Superuser status replicates to the `warehouse` DC through `system_auth`.
5. **Alter keyspace replication** on every keyspace to include the `trino` DC, then run `nodetool rebuild -- warehouse` on `cassandra-trino` to copy the data.

## Keyspaces to replicate

All keyspaces replicate to both DCs, including `system_auth` (the role data the `trino` DC authenticates against). The `system` and `system_schema` keyspaces use `LocalStrategy` and are not replicated.

## Test plan (before any production change)

1. Build the `trino` DC on a scratch namespace, not the ring.
2. Verify the stock `PasswordAuthenticator` accepts the Trino role over TLS, and rejects a client with no certificate.
3. Verify a Trino `SELECT` on a replicated keyspace returns the expected rows.
4. Verify a write on `warehouse` appears on `trino` within the expected lag.
5. Only then roll the DC into production, one step at a time with `nodetool status` checks.

## Rollback

- Remove the `trino` DC from the keyspace replication settings.
- Point the Trino catalog back to the existing `cassandra-pw` path until the new one is verified.
- The `warehouse` DC is not changed by this design except for the DC rename, which is reversible from the backup.

## Decisions (confirmed)

1. **Trino is read-write**, both DCs writable, last-write-wins; operating rule above.
2. **RF=1 for the `trino` DC** (single node; accepted for test).
3. **Replicate `system_auth` to `trino`** (accepted downside noted above).
4. **Self-signed internal CA** for the server and client certificates. Not production.

Scope: this is a test environment, not production.
