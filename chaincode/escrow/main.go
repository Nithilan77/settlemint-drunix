// Command escrow is the chaincode entrypoint. It wires up SmartContract as
// the sole contract in this chaincode package.
package main

import (
	"log"

	"github.com/hyperledger/fabric-contract-api-go/v2/contractapi"
)

func main() {
	chaincode, err := contractapi.NewChaincode(&SmartContract{})
	if err != nil {
		log.Panicf("error creating escrow chaincode: %v", err)
	}
	if err := chaincode.Start(); err != nil {
		log.Panicf("error starting escrow chaincode: %v", err)
	}
}
