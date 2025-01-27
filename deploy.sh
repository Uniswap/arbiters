# deploy.sh <CHAIN>
CHAIN=$1

THE_COMPACT_ADDRESS=0x00000000000018DF021Ff2467dF97ff846E09f48
MAILBOX_ADDRESS=$(cat ~/.hyperlane/chains/$CHAIN/addresses.yaml | yq '.mailbox')
RPC_URL=$(cat ~/.hyperlane/chains/$CHAIN/metadata.yaml | yq '.rpcUrls[0].http')
HYP_KEY=$(gcloud secrets versions access latest --secret "hyperlane-mainnet3-key-deployer" | jq ".privateKey" -c -r)
ARBITER_ADDRESS=$(forge create HyperlaneTribunal --json --broadcast \
    --rpc-url $RPC_URL \
    --private-key $HYP_KEY \
    --constructor-args $MAILBOX_ADDRESS $THE_COMPACT_ADDRESS \
    | jq -r '.deployedTo')
echo "$CHAIN: $ARBITER_ADDRESS" >> hyperlane-arbiters.yaml
