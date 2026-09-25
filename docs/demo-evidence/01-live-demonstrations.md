# Live demonstrations: lock, release, refund, rejected unilateral release

Full run of `chaincode/escrow/test/integration/live_demo.sh` against the live network.
**Exit code 0 — all four demonstrations passed.** Vendor CLI boilerplate trimmed (see
[`README.md`](README.md) for what was cut); every `peer chaincode` command and every
state read below is real, unedited output from this run.

## 1. LOCK

```
$ peer chaincode invoke ... -c '{"Args":["InitiateEscrow","demo-release-1790329431","500000","payer-acct-A","payee-acct-A"]}'
Chaincode invoke successful. result: status:200

$ peer chaincode query ... -c '{"Args":["ReadEscrow","demo-release-1790329431"]}'
{"id":"demo-release-1790329431","state":"INITIATED","claimAmountPaise":500000,"payerAccountRef":"payer-acct-A","payeeAccountRef":"payee-acct-A"}

$ peer chaincode invoke ... -c '{"Args":["LockEscrow","demo-release-1790329431"]}'
Chaincode invoke successful. result: status:200

State after lock: LOCKED
1. LOCK: OK
```

## 2. RELEASE (dual-org endorsed — the normal, legal path)

```
$ peer chaincode invoke ... -c '{"Args":["ReleaseEscrow","demo-release-1790329431"]}'
Chaincode invoke successful. result: status:200

State after release: RELEASED
2. RELEASE: OK
```

## 3. REFUND (separate escrow, dual-org endorsed)

```
$ peer chaincode invoke ... -c '{"Args":["InitiateEscrow","demo-refund-1790329431","250000","payer-acct-B","payee-acct-B"]}'
$ peer chaincode invoke ... -c '{"Args":["LockEscrow","demo-refund-1790329431"]}'
$ peer chaincode invoke ... -c '{"Args":["RefundEscrow","demo-refund-1790329431"]}'
Chaincode invoke successful. result: status:200

State after refund: REFUNDED
3. REFUND: OK
```

## 4. REJECTED UNILATERAL RELEASE — the core guarantee

```
=== Primary test: single-org-endorsed RELEASE must be REJECTED ===
Escrow ID: test-single-org-reject-1790329467

$ peer chaincode invoke ... -c '{"Args":["InitiateEscrow","test-single-org-reject-1790329467", ...]}'
$ peer chaincode invoke ... -c '{"Args":["LockEscrow","test-single-org-reject-1790329467"]}'

State before single-org release attempt: LOCKED

--- attempting ReleaseEscrow endorsed by Org1MSP ONLY (Org2MSP not asked) ---
$ peer chaincode invoke -o localhost:7050 --ordererTLSHostnameOverride orderer.example.com \
    -C mychannel -n escrow -c '{"Args":["ReleaseEscrow","test-single-org-reject-1790329467"]}' \
    --tls --cafile ... --peerAddresses localhost:7051 --tlsRootCertFiles <org1-only>
Chaincode invoke successful. result: status:200
single-org invoke exit code: 0

State after single-org release attempt: LOCKED

PASS: single-org-endorsed release was REJECTED — escrow test-single-org-reject-1790329467 is still LOCKED, not RELEASED.
4. REJECTED UNILATERAL RELEASE: OK
```

**Read that carefully**: the single-org invoke *itself* reports `status:200` and exit
code `0` — proposal simulation has no way to know the transaction will later fail
endorsement-policy validation. The proof isn't in that line, it's in the state read
immediately after: still `LOCKED`, not `RELEASED`. See
[`02-single-org-rejection.md`](02-single-org-rejection.md) for this isolated, and
[`03-yugabyte-sql-state.md`](03-yugabyte-sql-state.md) for the same fact confirmed
directly in the SQL state DB on both orgs.

```
ALL FOUR LIVE DEMONSTRATIONS PASSED
```
