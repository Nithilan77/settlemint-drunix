# Committed escrow state, read directly from YugabyteDB (both orgs)

Not through the chaincode's query API — a direct `ysqlsh` connection to each org's own
YugabyteDB instance, confirming the ledger state independently on both sides. Schema
`mychannel`, table `escrow` (schema-per-channel, table-per-chaincode — see
`../architecture.md` §3).

```sql
select block_number, transaction_number, db_value
from mychannel.escrow
where db_value->>'id' in (
  'demo-release-1790329431',
  'demo-refund-1790329431',
  'test-single-org-reject-1790329467'
)
order by block_number;
```

## `yugabyte-org1`

| block_number | db_value |
|---|---|
| 42 | `{"id": "demo-release-1790329431", "state": "RELEASED", "payeeAccountRef": "payee-acct-A", "payerAccountRef": "payer-acct-A", "claimAmountPaise": 500000}` |
| 45 | `{"id": "demo-refund-1790329431", "state": "REFUNDED", "payeeAccountRef": "payee-acct-B", "payerAccountRef": "payer-acct-B", "claimAmountPaise": 250000}` |
| 47 | `{"id": "test-single-org-reject-1790329467", "state": "LOCKED", "payeeAccountRef": "payee-acct-reject", "payerAccountRef": "payer-acct-reject", "claimAmountPaise": 100000}` |

## `yugabyte-org2`

| block_number | db_value |
|---|---|
| 42 | `{"id": "demo-release-1790329431", "state": "RELEASED", "payeeAccountRef": "payee-acct-A", "payerAccountRef": "payer-acct-A", "claimAmountPaise": 500000}` |
| 45 | `{"id": "demo-refund-1790329431", "state": "REFUNDED", "payeeAccountRef": "payee-acct-B", "payerAccountRef": "payer-acct-B", "claimAmountPaise": 250000}` |
| 47 | `{"id": "test-single-org-reject-1790329467", "state": "LOCKED", "payeeAccountRef": "payee-acct-reject", "payerAccountRef": "payer-acct-reject", "claimAmountPaise": 100000}` |

**Byte-for-byte identical on both orgs**, because both orgs' Committing Peers
independently validated and committed the same ordered blocks — there is no
database-level replication between `yugabyte-org1` and `yugabyte-org2` (they're
completely separate instances; see `../architecture.md` §1).

The row that matters most: `test-single-org-reject-1790329467` sits at `state: "LOCKED"`
on **both** instances — not `RELEASED`. This is the ledger's own bookkeeping (the
`block_number`/`transaction_number` columns Fabric's SQL state DB provider attaches to
every write) independently confirming what
[`02-single-org-rejection.md`](02-single-org-rejection.md) showed through the chaincode
API: the single-org-endorsed release never touched world state, on either org.

Reproduce directly:

```bash
docker exec -it yugabyte-org1 sh -c \
  "PGPASSWORD=yugabyte ysqlsh -h \$(hostname) -U yugabyte -d yugabyte -c 'select * from mychannel.escrow;'"
```
