# verify.sh <CHAIN>
CHAIN=$1

set -x

THE_COMPACT_ADDRESS=0x00000000000018DF021Ff2467dF97ff846E09f48
MAILBOX_ADDRESS=$(cat ~/.hyperlane/chains/$CHAIN/addresses.yaml | yq '.mailbox')
ARBITER_ADDRESS=$(cat hyperlane-arbiters.yaml | yq ".$CHAIN")
RPC_URL=$(cat ~/.hyperlane/chains/$CHAIN/metadata.yaml | yq '.rpcUrls[0].http')
ETHERSCAN_API_KEY=$(gcloud secrets versions access latest --secret "explorer-api-keys" | jq -r ".$CHAIN")

CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address,address)" $MAILBOX_ADDRESS $THE_COMPACT_ADDRESS)

forge verify-contract $ARBITER_ADDRESS \
    --rpc-url $RPC_URL \
    --verifier-api-key $ETHERSCAN_API_KEY \
    --constructor-args $CONSTRUCTOR_ARGS \
    --watch
