# chaincode/escrow

Phase 2 core: the escrow claim state machine. No dispute path, no oracle, no
private data collections yet — that's Phase 3.

## What this is (and isn't)

This chaincode never holds, moves, or custodies money — there is no field or
variable anywhere in it that represents an on-ledger balance of rupees. It
records a **claim**: an authoritative, shared statement that a given amount
of the payer's off-chain funds is earmarked, pending release or refund.
Actual rupee movement happens off-chain, through existing banking/NPCI
settlement rails. See [`../../docs/architecture.md`](../../docs/architecture.md)
§6 for the design note this implements, and `escrow.go`'s package comment for
the same boundary enforced in code.

## State machine

Exactly four canonical states, no others:

```
INITIATED -> LOCKED -> RELEASED
                    \-> REFUNDED
```

(`RELEASED` and `REFUNDED` are both terminal.)

## The core guarantee

`RELEASED` and `REFUNDED` are value-moving transitions: reaching them
requires endorsement from **both** the payer-bank org (`Org1MSP`) and the
settlement org (`Org2MSP`) — enforced by this chaincode's deploy-time
endorsement policy, not by application code (chaincode logic cannot see who
endorsed a call; see the `transition` function's doc comment in `escrow.go`
for why). Every illegal state transition (release without lock, double
release, refund after release, release after refund, acting on a
non-existent escrow) is rejected by application logic instead, in the same
`transition` guard function.

## Tests

- `escrow_test.go` — unit tests (`go test ./...`), covering the happy path
  and every illegal-transition case.
- `test/integration/` — shell scripts exercising the deployed chaincode
  against the live network, including the single-org-release rejection that
  a unit test cannot exercise (endorsement collection/validation is a Fabric
  platform concern, not something a mocked chaincode stub goes through).

## Deploying

Same mechanism as the Phase 0.5 sample chaincode, via
[`../../network/net.sh`](../../network/net.sh) `deploy-cc`, pointed at this
directory with the dual-org endorsement policy applied. See the root
README's deploy instructions and NOTES.md for the exact command and policy
string used.
