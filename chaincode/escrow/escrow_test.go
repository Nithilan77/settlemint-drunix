package main

import (
	"testing"

	"escrow/mocks"

	"github.com/stretchr/testify/require"
)

// newTestContext returns a TransactionContext backed by a ChaincodeStub
// whose GetState/PutState are wired to a real in-memory map, so that a
// sequence of calls within one test (e.g. Initiate, then Lock, then
// Release) sees the effects of the calls before it — exactly like a real
// ledger, just in memory instead of Yugabyte.
func newTestContext() *mocks.TransactionContext {
	state := map[string][]byte{}

	stub := &mocks.ChaincodeStub{}
	stub.GetStateStub = func(key string) ([]byte, error) {
		return state[key], nil // nil, nil for a missing key matches real GetState semantics
	}
	stub.PutStateStub = func(key string, value []byte) error {
		state[key] = value
		return nil
	}

	ctx := &mocks.TransactionContext{}
	ctx.GetStubReturns(stub)
	return ctx
}

const (
	testPayer = "payer-account-ref-1"
	testPayee = "payee-account-ref-1"
)

func TestInitiateEscrow(t *testing.T) {
	sc := SmartContract{}
	ctx := newTestContext()

	err := sc.InitiateEscrow(ctx, "esc1", 10000, testPayer, testPayee)
	require.NoError(t, err)

	escrow, err := sc.ReadEscrow(ctx, "esc1")
	require.NoError(t, err)
	require.Equal(t, StateInitiated, escrow.State)
	require.Equal(t, int64(10000), escrow.ClaimAmountPaise)

	// Re-initiating the same ID is rejected.
	err = sc.InitiateEscrow(ctx, "esc1", 10000, testPayer, testPayee)
	require.ErrorContains(t, err, "already exists")

	// A non-positive claim amount is rejected.
	err = sc.InitiateEscrow(ctx, "esc2", 0, testPayer, testPayee)
	require.ErrorContains(t, err, "must be positive")
}

func TestLockThenReleaseHappyPath(t *testing.T) {
	sc := SmartContract{}
	ctx := newTestContext()

	require.NoError(t, sc.InitiateEscrow(ctx, "esc1", 500, testPayer, testPayee))
	require.NoError(t, sc.LockEscrow(ctx, "esc1"))

	escrow, err := sc.ReadEscrow(ctx, "esc1")
	require.NoError(t, err)
	require.Equal(t, StateLocked, escrow.State)

	require.NoError(t, sc.ReleaseEscrow(ctx, "esc1"))

	escrow, err = sc.ReadEscrow(ctx, "esc1")
	require.NoError(t, err)
	require.Equal(t, StateReleased, escrow.State)
}

func TestLockThenRefundHappyPath(t *testing.T) {
	sc := SmartContract{}
	ctx := newTestContext()

	require.NoError(t, sc.InitiateEscrow(ctx, "esc1", 500, testPayer, testPayee))
	require.NoError(t, sc.LockEscrow(ctx, "esc1"))
	require.NoError(t, sc.RefundEscrow(ctx, "esc1"))

	escrow, err := sc.ReadEscrow(ctx, "esc1")
	require.NoError(t, err)
	require.Equal(t, StateRefunded, escrow.State)
}

// --- Hard requirement (b): every illegal transition rejected at chaincode
// level, one test each. ---

func TestIllegalTransition_ReleaseWithoutLock(t *testing.T) {
	sc := SmartContract{}
	ctx := newTestContext()

	require.NoError(t, sc.InitiateEscrow(ctx, "esc1", 500, testPayer, testPayee))
	// esc1 is still INITIATED — never locked.

	err := sc.ReleaseEscrow(ctx, "esc1")
	require.Error(t, err)
	require.ErrorContains(t, err, "current state is INITIATED")
	require.ErrorContains(t, err, "requires LOCKED")

	// Confirm the rejection did not mutate state.
	escrow, err := sc.ReadEscrow(ctx, "esc1")
	require.NoError(t, err)
	require.Equal(t, StateInitiated, escrow.State)
}

func TestIllegalTransition_DoubleRelease(t *testing.T) {
	sc := SmartContract{}
	ctx := newTestContext()

	require.NoError(t, sc.InitiateEscrow(ctx, "esc1", 500, testPayer, testPayee))
	require.NoError(t, sc.LockEscrow(ctx, "esc1"))
	require.NoError(t, sc.ReleaseEscrow(ctx, "esc1"))

	// Second release attempt on an already-RELEASED escrow.
	err := sc.ReleaseEscrow(ctx, "esc1")
	require.Error(t, err)
	require.ErrorContains(t, err, "current state is RELEASED")
	require.ErrorContains(t, err, "requires LOCKED")

	escrow, err := sc.ReadEscrow(ctx, "esc1")
	require.NoError(t, err)
	require.Equal(t, StateReleased, escrow.State)
}

func TestIllegalTransition_RefundAfterRelease(t *testing.T) {
	sc := SmartContract{}
	ctx := newTestContext()

	require.NoError(t, sc.InitiateEscrow(ctx, "esc1", 500, testPayer, testPayee))
	require.NoError(t, sc.LockEscrow(ctx, "esc1"))
	require.NoError(t, sc.ReleaseEscrow(ctx, "esc1"))

	err := sc.RefundEscrow(ctx, "esc1")
	require.Error(t, err)
	require.ErrorContains(t, err, "current state is RELEASED")
	require.ErrorContains(t, err, "requires LOCKED")

	escrow, err := sc.ReadEscrow(ctx, "esc1")
	require.NoError(t, err)
	require.Equal(t, StateReleased, escrow.State) // unchanged
}

func TestIllegalTransition_ReleaseAfterRefund(t *testing.T) {
	sc := SmartContract{}
	ctx := newTestContext()

	require.NoError(t, sc.InitiateEscrow(ctx, "esc1", 500, testPayer, testPayee))
	require.NoError(t, sc.LockEscrow(ctx, "esc1"))
	require.NoError(t, sc.RefundEscrow(ctx, "esc1"))

	err := sc.ReleaseEscrow(ctx, "esc1")
	require.Error(t, err)
	require.ErrorContains(t, err, "current state is REFUNDED")
	require.ErrorContains(t, err, "requires LOCKED")

	escrow, err := sc.ReadEscrow(ctx, "esc1")
	require.NoError(t, err)
	require.Equal(t, StateRefunded, escrow.State) // unchanged
}

func TestIllegalTransition_ActOnNonExistentEscrow(t *testing.T) {
	sc := SmartContract{}
	ctx := newTestContext()

	// No InitiateEscrow call at all for "ghost".
	_, readErr := sc.ReadEscrow(ctx, "ghost")
	require.ErrorContains(t, readErr, `escrow "ghost" does not exist`)

	lockErr := sc.LockEscrow(ctx, "ghost")
	require.ErrorContains(t, lockErr, `escrow "ghost" does not exist`)

	releaseErr := sc.ReleaseEscrow(ctx, "ghost")
	require.ErrorContains(t, releaseErr, `escrow "ghost" does not exist`)

	refundErr := sc.RefundEscrow(ctx, "ghost")
	require.ErrorContains(t, refundErr, `escrow "ghost" does not exist`)
}
