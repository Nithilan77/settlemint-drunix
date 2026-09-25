# Architecture

Status: **Phase 1 — grounded in what has actually been run and observed** (Phase 0 network
bring-up, Phase 0.5 channel + chaincode deploy). Where something is design intent rather
than verified behavior, it's marked as such. Full incident-by-incident evidence for every
claim below is in [`../NOTES.md`](../NOTES.md).

## 1. Network topology (verified)

Bringing up `drunix-network/test-network` produces 11 containers, confirmed running and
stable (`docker ps`, log inspection, `RestartCount: 0`):

| Container | Image | Role |
|---|---|---|
| `orderer.example.com` | `npcioss/drunix-orderer:1.0.0` | Raft orderer, single node |
| `lp1.org1` | `npcioss/drunix-peer:1.0.0` | Org1 Lite Peer (`peer0.org1`) |
| `cp.org1` | `npcioss/drunix-peer:1.0.0` | Org1 Committing Peer (`peer1.org1`) |
| `vs1.org1` | `npcioss/drunix-vscc:1.0.0` | Org1 Validation Service |
| `lp1.org2` | `npcioss/drunix-peer:1.0.0` | Org2 Lite Peer (`peer0.org2`) |
| `cp.org2` | `npcioss/drunix-peer:1.0.0` | Org2 Committing Peer (`peer1.org2`) |
| `vs1.org2` | `npcioss/drunix-vscc:1.0.0` | Org2 Validation Service |
| `yugabyte-org1` | `yugabytedb/yugabyte:2025.2.0.0-b131` | Org1 SQL state DB |
| `yugabyte-org2` | `yugabytedb/yugabyte:2025.2.0.0-b131` | Org2 SQL state DB |
| `hlf_keydb_org1msp` | `eqalpha/keydb` | Org1 transient store |
| `hlf_keydb_org2msp` | `eqalpha/keydb` | Org2 transient store |

Two orgs, single-node Raft ordering, no CA containers (this network uses `cryptogen`,
not Fabric CA, by default). **Everything below each org's dashed line is per-org and
independent** — org1 and org2 each get their own YugabyteDB instance and their own
KeyDB instance; there is no shared/replicated database between orgs. When both orgs
show the same state for the same key (verified in §3), that's because both orgs'
peers independently validated and committed the same ordered transaction — not
because of any database-level replication.

## 2. Peer roles: Lite Peer / Committing Peer / Validation Service

The Lite Peer and Committing Peer run the identical image (`npcioss/drunix-peer:1.0.0`);
role is set purely by environment variable — `CORE_PEER_LITEPEER_ENABLED=true` on the
Lite Peer container (`compose/compose-test-net.yaml:110,334`), absent on the Committing
Peer. This is a config toggle, not a different binary.

What that toggle actually does, confirmed directly from source
(`core/ledger/kvledger/txmgmt/statedb/statesqldb/statesqldb.go:383-392`, comment
authored by Drunix, quoted verbatim):

> *"Since lite peers neither consume blocks nor commit to the ledger, they rely on the
> savepoint from the committing peer. This causes the statedb savepoint to always be
> ahead of the block store. To stabilize lite peers, align the savepoint with the block
> store."*

So: the **Committing Peer is the one actually processing and committing blocks** for
its org. The **Lite Peer shares the same YugabyteDB state DB** (both peers of an org
point at the same `yugabyte-orgN` instance) and mostly serves reads/queries without
doing its own block-store bookkeeping — it patches its own savepoint version to line up
with the block store rather than trusting its (stale-by-design) statedb savepoint.

This also explains an operational detail confirmed in Phase 0.5: the stock
`test-network` chaincode lifecycle flow (`scripts/envVar.sh:setGlobals`, only defines
peer indices `0` and `1`) installs/approves/commits chaincode **only against
`peer0.orgN` (the Lite Peer)** — never touches index `2` (Validation Service) for
lifecycle operations.

**Validation Service (`vs1.orgN`, image `npcioss/drunix-vscc:1.0.0`)** — confirmed
running cleanly, participates in gossip, and its binary links Fabric's endorser,
chaincode-execution, and core VSCC (validation system chaincode) packages
(`internal/vscc/node/start.go` imports). It also connects to the org's YugabyteDB and
KeyDB on boot. Its exact division of responsibility against the Committing Peer (e.g.
whether transaction validation is fully delegated to this node) has **not** been traced
end-to-end through source or exercised with a targeted test — treat that split as
"present and healthy, not fully characterized" rather than verified.

## 3. State DB: YugabyteDB, schema-per-channel, table-per-chaincode (verified)

Confirmed live, both by querying through the Fabric peer and by connecting directly to
YugabyteDB with `ysqlsh`.

**Schema per channel.** Creating `mychannel` produces a Postgres/YSQL schema named
`mychannel` in each org's Yugabyte instance
(`core/ledger/kvledger/txmgmt/statedb/statesqldb/statesqldb.go:98`, schema name derived
from the ledger/channel ID).

**Table per chaincode.** Installing the `basic` chaincode on that channel produces
`mychannel.basic`:

```
                   Table "mychannel.basic"
       Column       |  Type  | Collation | Nullable | Default
--------------------+--------+-----------+----------+---------
 block_number       | bigint |           |          |
 transaction_number | bigint |           |          |
 key                | bytea  |           | not null |
 db_metadata        | bytea  |           |          |
 db_value           | jsonb  |           |          |
Indexes:
    "basic_pkey" PRIMARY KEY, lsm (key HASH)
```

**Key encoding**, confirmed from source
(`core/ledger/kvledger/txmgmt/statedb/statesqldb/{statesqldb,utils}.go`):

```
key = 0x64 ('d')  ++  <chaincode/namespace name>  ++  0x00  ++  <chaincode-level key>
```

i.e. a single-byte `'d'` (data-record) prefix, then the chaincode name, then a NUL
separator, then whatever key the chaincode itself used. Observed live for asset
`asset999` in chaincode `basic`: raw bytes `dbasic\x00asset999`.

**Value** is stored as `jsonb`, verified byte-for-byte identical to what the chaincode's
own query API returns. Example, live row after invoking
`CreateAsset(asset999, teal, 10, Nithilan, 9999)`:

```sql
select block_number, transaction_number, encode(key,'escape'), db_value
from mychannel.basic where db_value->>'ID' = 'asset999';

 block_number | transaction_number |        key          |                          db_value
--------------+---------------------+---------------------+-------------------------------------------------------------
            7 |                   0 | dbasic\000asset999   | {"ID":"asset999","Size":10,"Color":"teal","Owner":"Nithilan","AppraisedValue":9999}
```

Present identically on **both** `yugabyte-org1` and `yugabyte-org2` after both orgs'
Committing Peers validated and committed the same block.

A second table, `mychannel.peer_lifecycle`, also exists per-channel (holds chaincode
lifecycle/definition metadata) — present, not yet inspected in detail.

Because state is queryable JSONB in a real SQL engine rather than an opaque LevelDB/
CouchDB blob, this is the mechanism that will let `gateway/` (Phase 2+) do direct
reporting/analytics queries against ledger state without going through chaincode for
every read, if that turns out to be useful.

## 4. KeyDB (per org) — present, not yet exercised

`hlf_keydb_orgNmsp` runs alongside each org's Yugabyte instance. Named and positioned
consistently with Fabric's private-data **transient store** (holds private collection
data pending commit, separately from the committed ledger). This has **not** been
exercised yet — the Phase 0.5 chaincode test used only public state, no private data
collections — so its role here is inferred from naming/placement/Fabric convention, not
independently confirmed the way the peer roles and state DB schema were.

## 5. Channel / chaincode lifecycle (verified)

- Channel: `mychannel`, single application channel, Raft consensus (`ChannelUsingRaft`
  profile), both orgs joined, anchor peers set to each org's Committing Peer
  (`peer1.orgN:706x`/`906x`).
- Chaincode lifecycle (install → approve → commit) targets `peer0.orgN` (Lite Peer) per
  org, requires both orgs' approval before commit (2-of-2 endorsement policy default).
- A committed transaction is independently verifiable via direct SQL against either
  org's YugabyteDB, not just through the chaincode query API (§3).

## 6. Intended domain model — Phase 2 scope, **not yet built**

This section is design intent for the upcoming `chaincode/escrow` work, not a verified
fact — flagging that distinction explicitly since everything above this line is.

The escrow chaincode is expected to record **on-chain state** — the escrow's lifecycle
(created / funded / released / disputed / expired) and the conditions attached to it —
as chaincode-owned ledger state, using exactly the mechanism verified in §3 (state
lands in `mychannel.<ccname>` in each org's YugabyteDB, queryable as JSONB). The actual
movement of rupees is expected to happen **off-chain**, through existing banking/NPCI
settlement rails, with the chain acting as the shared, tamper-evident record of what
was agreed and what condition it's in — not as the payment rail itself. No design for
how those two are reconciled (webhook, oracle, reconciliation job, etc.) exists yet;
that's Phase 2+ work.

## 7. Known gaps / open questions

- Validation Service's precise responsibility split vs. the Committing Peer (§2) —
  not traced through source or tested directly.
- KeyDB / transient store — present but unexercised (§4).
- Single-node orderer — no Raft HA in this topology; fine for a hackathon dev network,
  not representative of a production topology.
- `mychannel.peer_lifecycle` table contents — not inspected.
- No chaincode-level access control / MSP-based authorization logic evaluated yet —
  out of scope until `chaincode/escrow` exists.
