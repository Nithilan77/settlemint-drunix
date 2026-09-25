# gateway

Empty scaffold. Phase 2+ work — no service here yet.

Will be the application-layer service that talks to the Fabric Gateway on the
Committing Peers (see [`../docs/architecture.md`](../docs/architecture.md) §2 for the
verified Lite Peer / Committing Peer split this needs to be aware of when choosing which
peer to connect to), submitting/evaluating transactions against `chaincode/escrow` on
behalf of `web/`, and reconciling on-chain escrow state with off-chain rupee movement.
