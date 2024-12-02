# enroll.sh <CHAIN> <CHAINS>
CHAIN=$1
CHAINS=$2

RPC_URL=$(cat ~/.hyperlane/chains/$CHAIN/metadata.yaml | yq '.rpcUrls[0].http')
HYP_KEY=$(gcloud secrets versions access latest --secret "hyperlane-mainnet3-key-deployer" | jq ".privateKey" -c -r)
ARBITER_ADDRESS=$(cat hyperlane-arbiters.yaml | yq ".$CHAIN")

# loop over each chain in chains
for DESTINATION in $CHAINS; do
    DESTINATION_DOMAIN=$(cat ~/.hyperlane/chains/$DESTINATION/metadata.yaml | yq '.domainId')
    ROUTER_ADDRESS=$(cat hyperlane-arbiters.yaml | yq ".$DESTINATION")
    echo "Enrolling $DESTINATION on $CHAIN"
    cast send $ARBITER_ADDRESS \
        --rpc-url $RPC_URL \
        --private-key $HYP_KEY \
        "enrollRemoteRouter(uint32,bytes32)" $DESTINATION_DOMAIN $(yarn leftpad $ROUTER_ADDRESS)
done
