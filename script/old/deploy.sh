# deploy.sh <CHAIN>
CHAIN=$1

# ethereum EX37XY5GTC34GQQ6UYGYJ8N97VT45HSHYN
# optimism W49V4DQIE7TZH7U81I3VJKI5KRQS8ZFNTK
# base     NVNHERKD1JEVFA83A5Z61BI32UHG1CWEN5
# unichain CUU1U6PR8KRZQTAJ41CM1WA18EXXB4R5QI

THE_COMPACT_ADDRESS=0x00000000000018DF021Ff2467dF97ff846E09f48
MAILBOX_ADDRESS=$(cat ~/.hyperlane/chains/$CHAIN/addresses.yaml | yq '.mailbox')
RPC_URL=$(cat ~/.hyperlane/chains/$CHAIN/metadata.yaml | yq '.rpcUrls[0].http')
ARBITER_ADDRESS=$(forge create HyperlaneTribunal --json --broadcast \
    --rpc-url $RPC_URL \
    -l --mnemonic-derivation-path "m/44'/60'/0'/4" \
    --constructor-args $MAILBOX_ADDRESS $THE_COMPACT_ADDRESS \
    --verify \
    --etherscan-api-key "EX37XY5GTC34GQQ6UYGYJ8N97VT45HSHYN" \
    | jq -r '.deployedTo')
echo "$CHAIN: $ARBITER_ADDRESS" >> hyperlane-arbiters.yaml
