# The core guarantee: a single-org release does not commit

This is the single most important result in the project: **`RELEASED` and `REFUNDED`
cannot happen without both the payer-bank org (`Org1MSP`) and the settlement org
(`Org2MSP`) endorsing.** Isolated here from the full run in
[`01-live-demonstrations.md`](01-live-demonstrations.md).

Escrow `test-single-org-reject-1790329467`, already `LOCKED`.

## Before

```
$ peer chaincode query -C mychannel -n escrow -c '{"Args":["ReadEscrow","test-single-org-reject-1790329467"]}'

State: LOCKED
```

## The attempt — endorsed by Org1MSP only, Org2MSP never asked

```
$ peer chaincode invoke \
    -o localhost:7050 --ordererTLSHostnameOverride orderer.example.com \
    -C mychannel -n escrow \
    -c '{"Args":["ReleaseEscrow","test-single-org-reject-1790329467"]}' \
    --tls --cafile <orderer-ca> \
    --peerAddresses localhost:7051 --tlsRootCertFiles <org1-tls-ca-ONLY>

Chaincode invoke successful. result: status:200
exit code: 0
```

Note what this line does **not** prove: `status:200` here is the *proposal simulation*
result from the one peer that was asked — the chaincode's own transition logic has no
way to see who else will or won't co-sign, so it has no reason to refuse. The
transaction is still submitted to the orderer and still gets ordered into a block.

## After

```
$ peer chaincode query -C mychannel -n escrow -c '{"Args":["ReadEscrow","test-single-org-reject-1790329467"]}'

State: LOCKED
```

**Unchanged.** The single-org-endorsed transaction was ordered into a block, then
rejected at block-validation time (VSCC checking the block against this chaincode's
`AND('Org1MSP.peer','Org2MSP.peer')` endorsement policy — see
[`04-endorsement-policy.md`](04-endorsement-policy.md)) and excluded from the world-state
update. It never touched the escrow's recorded state, on either org — confirmed
independently, straight out of the SQL state DB, in
[`03-yugabyte-sql-state.md`](03-yugabyte-sql-state.md).
