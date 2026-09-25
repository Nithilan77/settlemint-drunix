// Package main implements the Phase 2 escrow chaincode core.
//
// IMPORTANT — what this chaincode is and is not:
//
// This chaincode never holds, moves, or custodies money. There is no field,
// variable, or function anywhere in this package that represents an
// on-ledger balance of rupees. What it records is a CLAIM: an authoritative,
// shared statement that "this much of the payer's off-chain funds is
// earmarked, on these terms, pending release or refund." The actual rupee
// movement happens off-chain, through existing banking/NPCI settlement
// rails, outside this ledger entirely. See docs/architecture.md §6 in the
// repo root for the fuller design note; this file is the enforcement of
// that boundary in code, not just in prose.
//
// State machine (exactly these four states, no others):
//
//	INITIATED -> LOCKED -> RELEASED
//	                    \-> REFUNDED
//
// No dispute path, no oracle, no private data collections here — that's
// out of scope for this phase.
package main

import (
	"encoding/json"
	"fmt"

	"github.com/hyperledger/fabric-contract-api-go/v2/contractapi"
)

// State is one of the four canonical escrow-claim states. It is a claim
// lifecycle state, never a monetary balance.
type State string

const (
	// StateInitiated: the claim has been recorded but nothing is locked yet.
	StateInitiated State = "INITIATED"
	// StateLocked: both parties have a shared, committed record of the claim
	// terms. This is the only state RELEASED/REFUNDED may be reached from.
	StateLocked State = "LOCKED"
	// StateReleased: terminal. The claim record says the off-chain funds
	// should move to the payee. This chaincode does not move them.
	StateReleased State = "RELEASED"
	// StateRefunded: terminal. The claim record says the off-chain funds
	// should return to the payer. This chaincode does not move them.
	StateRefunded State = "REFUNDED"
)

// Organization MSP IDs recognized as the two required co-endorsers for
// value-moving transitions. This network (see NOTES.md) has exactly two
// orgs, provisioned by the vendor test-network's default cryptogen config:
// Org1MSP and Org2MSP. We map them here to the roles this escrow model
// actually cares about, for use in documentation, tooling, and the deploy
// -time endorsement policy — the chaincode logic itself does not read these
// constants, because chaincode logic cannot see who endorsed a transaction
// (see the comment on transition, below).
const (
	// PayerBankMSPID is the org acting for the payer's bank — the party
	// whose customer's off-chain funds are the subject of the claim.
	PayerBankMSPID = "Org1MSP"
	// SettlementOrgMSPID is the org acting as the settlement/payee-side
	// counterparty co-signer required to move a claim to a terminal state.
	SettlementOrgMSPID = "Org2MSP"
)

// Escrow is the on-chain, authoritative record of a single claim against
// off-chain funds. Every field here describes the CLAIM, never custody of
// money: ClaimAmountPaise is the size of the claim being tracked, not a
// balance held by this chaincode; PayerAccountRef/PayeeAccountRef are
// opaque references to off-chain accounts, not on-ledger wallets.
type Escrow struct {
	ID string `json:"id"`
	// State is the escrow claim's current lifecycle state.
	State State `json:"state"`
	// ClaimAmountPaise is the paisa-denominated size of the off-chain funds
	// CLAIM this escrow record represents. It is bookkeeping metadata about
	// the claim, not money held on the ledger.
	ClaimAmountPaise int64 `json:"claimAmountPaise"`
	// PayerAccountRef is an opaque, off-chain reference identifying the
	// payer's account. This chaincode does not interpret or move it.
	PayerAccountRef string `json:"payerAccountRef"`
	// PayeeAccountRef is an opaque, off-chain reference identifying the
	// payee's account. This chaincode does not interpret or move it.
	PayeeAccountRef string `json:"payeeAccountRef"`
}

// SmartContract implements the escrow claim lifecycle.
type SmartContract struct {
	contractapi.Contract
}

// InitiateEscrow records a new claim in StateInitiated. It fails if an
// escrow with this ID already exists, or if the claim amount is not
// positive. It does not lock anything and does not move anything.
func (s *SmartContract) InitiateEscrow(ctx contractapi.TransactionContextInterface, id string, claimAmountPaise int64, payerAccountRef string, payeeAccountRef string) error {
	exists, err := s.escrowExists(ctx, id)
	if err != nil {
		return err
	}
	if exists {
		return fmt.Errorf("escrow %q already exists", id)
	}
	if claimAmountPaise <= 0 {
		return fmt.Errorf("escrow %q: claimAmountPaise must be positive, got %d", id, claimAmountPaise)
	}

	escrow := &Escrow{
		ID:               id,
		State:            StateInitiated,
		ClaimAmountPaise: claimAmountPaise,
		PayerAccountRef:  payerAccountRef,
		PayeeAccountRef:  payeeAccountRef,
	}
	return s.putEscrow(ctx, escrow)
}

// LockEscrow moves a claim from INITIATED to LOCKED. LOCKED is the only
// state RELEASED/REFUNDED may be reached from.
func (s *SmartContract) LockEscrow(ctx contractapi.TransactionContextInterface, id string) error {
	_, err := s.transition(ctx, id, StateInitiated, StateLocked)
	return err
}

// ReleaseEscrow moves a claim from LOCKED to RELEASED: the terminal state
// recording that the off-chain funds should move to the payee. This
// function only ever changes the claim's recorded state — it does not, and
// cannot, move any money.
//
// This is a value-moving transition. Reaching commit with a valid ledger
// write here requires endorsement from BOTH PayerBankMSPID and
// SettlementOrgMSPID, per this chaincode's deploy-time endorsement policy
// (see NOTES.md / README for the exact policy string). A transaction
// endorsed by only one of those orgs will be rejected at commit-time
// validation before it ever reaches this state; see the comment on
// transition for why that enforcement cannot live in this function's Go
// code.
func (s *SmartContract) ReleaseEscrow(ctx contractapi.TransactionContextInterface, id string) error {
	_, err := s.transition(ctx, id, StateLocked, StateReleased)
	return err
}

// RefundEscrow moves a claim from LOCKED to REFUNDED: the terminal state
// recording that the off-chain funds should return to the payer. Like
// ReleaseEscrow, this only changes recorded state and never moves money,
// and is subject to the same dual-org endorsement requirement.
func (s *SmartContract) RefundEscrow(ctx contractapi.TransactionContextInterface, id string) error {
	_, err := s.transition(ctx, id, StateLocked, StateRefunded)
	return err
}

// ReadEscrow returns the current recorded state of a claim.
func (s *SmartContract) ReadEscrow(ctx contractapi.TransactionContextInterface, id string) (*Escrow, error) {
	return s.readEscrow(ctx, id)
}

// transition is the single choke point every state-changing escrow function
// goes through. It is the chaincode-level guarantee that the escrow state
// machine (INITIATED -> LOCKED -> RELEASED | REFUNDED) can never be
// violated by application logic, independent of who called it or how many
// organizations endorsed the call.
//
// It rejects:
//   - operating on an escrow ID that does not exist (readEscrow returns an
//     error for a missing key), and
//   - any transition whose required "from" state does not match the
//     escrow's actual current on-ledger state. Because every state-changing
//     function above declares its own required "from" state and calls only
//     this function to enforce it, this one check is — by construction —
//     exactly equivalent to rejecting every illegal transition: you cannot
//     release without having locked (ReleaseEscrow requires from=LOCKED, so
//     an INITIATED escrow is rejected), cannot release twice (the first
//     release already moved the state to RELEASED, which is not LOCKED),
//     cannot refund an already-released escrow, and cannot release an
//     already-refunded one — all four are the same "current state != from"
//     check, just with different current/required states.
//
// It does NOT and cannot enforce which organizations endorsed the call.
// Endorsement is not visible to chaincode logic at all: a chaincode
// proposal executes exactly once, on whichever peer(s) the client happened
// to send it to, and that single execution has no way to know who else
// will or will not co-sign the same proposal. The multi-org endorsement
// requirement for value-moving transitions (RELEASED, REFUNDED) is enforced
// separately and independently, by Fabric's own commit-time validation of
// this chaincode's deploy-time endorsement policy. See NOTES.md / README
// for the exact policy string applied when this chaincode was deployed,
// and the integration test in test/integration/ for a live demonstration
// that a single-org-endorsed release is rejected.
func (s *SmartContract) transition(ctx contractapi.TransactionContextInterface, id string, from State, to State) (*Escrow, error) {
	escrow, err := s.readEscrow(ctx, id)
	if err != nil {
		return nil, err
	}
	if escrow.State != from {
		return nil, fmt.Errorf("escrow %q: cannot move to %s — current state is %s, this transition requires %s", id, to, escrow.State, from)
	}
	escrow.State = to
	if err := s.putEscrow(ctx, escrow); err != nil {
		return nil, err
	}
	return escrow, nil
}

// escrowExists reports whether an escrow record exists for id.
func (s *SmartContract) escrowExists(ctx contractapi.TransactionContextInterface, id string) (bool, error) {
	data, err := ctx.GetStub().GetState(id)
	if err != nil {
		return false, fmt.Errorf("failed to read escrow %q: %w", id, err)
	}
	return data != nil, nil
}

// readEscrow loads and unmarshals the escrow record for id, or returns an
// error if it does not exist.
func (s *SmartContract) readEscrow(ctx contractapi.TransactionContextInterface, id string) (*Escrow, error) {
	data, err := ctx.GetStub().GetState(id)
	if err != nil {
		return nil, fmt.Errorf("failed to read escrow %q: %w", id, err)
	}
	if data == nil {
		return nil, fmt.Errorf("escrow %q does not exist", id)
	}
	var escrow Escrow
	if err := json.Unmarshal(data, &escrow); err != nil {
		return nil, fmt.Errorf("failed to unmarshal escrow %q: %w", id, err)
	}
	return &escrow, nil
}

// putEscrow marshals and writes an escrow record.
func (s *SmartContract) putEscrow(ctx contractapi.TransactionContextInterface, escrow *Escrow) error {
	data, err := json.Marshal(escrow)
	if err != nil {
		return fmt.Errorf("failed to marshal escrow %q: %w", escrow.ID, err)
	}
	return ctx.GetStub().PutState(escrow.ID, data)
}
