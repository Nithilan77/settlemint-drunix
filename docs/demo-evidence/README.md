# Demo evidence

Captured from a real run against the live 11-container network, 2026-09-25, ~15:13–15:14
IST. Chaincode `escrow` v1.0, sequence 1, on channel `mychannel`, endorsement policy
`AND('Org1MSP.peer','Org2MSP.peer')`. Vendor CLI boilerplate (`Using organization N`,
ANSI color codes, the pre-existing `sleep: missing operand` retry-loop noise documented
in `../../NOTES.md`) has been trimmed from all four files below — the commands and their
real output are unedited.

To reproduce: `./network/net.sh bootstrap` then
`bash chaincode/escrow/test/integration/live_demo.sh` (see root README "Quickstart").

| File | What it shows |
|---|---|
| [`01-live-demonstrations.md`](01-live-demonstrations.md) | The four required demonstrations: a lock, a release, a refund, and a rejected unilateral release — full `live_demo.sh` run |
| [`02-single-org-rejection.md`](02-single-org-rejection.md) | The core guarantee, isolated: the exact before/after ledger read proving a single-org-endorsed release left the escrow `LOCKED` |
| [`03-yugabyte-sql-state.md`](03-yugabyte-sql-state.md) | The same three escrows, read directly out of YugabyteDB as JSONB — on **both** orgs independently, not through the chaincode API |
| [`04-endorsement-policy.md`](04-endorsement-policy.md) | `peer lifecycle chaincode querycommitted` — the `AND(Org1MSP, Org2MSP)` policy as it actually exists on the committed ledger, both orgs approved |

Escrow IDs referenced throughout (all created fresh in this run):

| ID | Path | Final state |
|---|---|---|
| `demo-release-1790329431` | `InitiateEscrow → LockEscrow → ReleaseEscrow` (dual-org) | `RELEASED` |
| `demo-refund-1790329431` | `InitiateEscrow → LockEscrow → RefundEscrow` (dual-org) | `REFUNDED` |
| `test-single-org-reject-1790329467` | `InitiateEscrow → LockEscrow`, then a **single-org** `ReleaseEscrow` attempt | `LOCKED` (unchanged — the release did not take effect) |
