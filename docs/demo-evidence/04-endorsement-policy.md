# Endorsement policy, as it actually exists on the committed ledger

Not the deploy command's echo of what was requested — this is
`peer lifecycle chaincode querycommitted` read back from the channel itself, after both
orgs approved and the definition committed.

```
$ peer lifecycle chaincode querycommitted --channelID mychannel --name escrow

Committed chaincode definition for chaincode 'escrow' on channel 'mychannel':
Version: 1.0, Sequence: 1, Endorsement Plugin: escc, Validation Plugin: vscc, Approvals: [Org1MSP: true, Org2MSP: true]
```

```
$ peer lifecycle chaincode querycommitted --channelID mychannel --name escrow --output json

{
	"sequence": 1,
	"version": "1.0",
	"endorsement_plugin": "escc",
	"validation_plugin": "vscc",
	"validation_parameter": "CiwSDBIKCAISAggAEgIIARoNEgsKB09yZzFNU1AQAxoNEgsKB09yZzJNU1AQAw==",
	"collections": {},
	"approvals": {
		"Org1MSP": true,
		"Org2MSP": true
	}
}
```

`validation_parameter` is the base64-encoded, serialized signature policy `vscc` (the
validation plugin) checks every block against — this is the actual bytes enforcing
`AND('Org1MSP.peer','Org2MSP.peer')` at commit-time validation. `Approvals` confirms
both orgs signed off on this exact definition (version 1.0, sequence 1) before it could
commit at all — a single org approving is not enough to even commit the chaincode
*definition*, let alone endorse a transaction against it.

Deploy command that produced this (via `network/net.sh deploy-cc`,
`CC_END_POLICY="AND('Org1MSP.peer','Org2MSP.peer')"`), for reference — the flag threads
through to every lifecycle step identically:

```
$ peer lifecycle chaincode commit -o localhost:7050 --ordererTLSHostnameOverride orderer.example.com \
    --tls --cafile <orderer-ca> --channelID mychannel --name escrow \
    --peerAddresses localhost:7061 --tlsRootCertFiles <org1-ca> \
    --peerAddresses localhost:9061 --tlsRootCertFiles <org2-ca> \
    --version 1.0 --sequence 1 \
    --signature-policy "AND('Org1MSP.peer','Org2MSP.peer')"

txid [...] committed with status (VALID) at localhost:7061
txid [...] committed with status (VALID) at localhost:9061
Chaincode definition committed on channel 'mychannel'
```
