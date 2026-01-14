# verify.sh <CHAIN>
CHAIN=$1

# ethereum EX37XY5GTC34GQQ6UYGYJ8N97VT45HSHYN
# optimism W49V4DQIE7TZH7U81I3VJKI5KRQS8ZFNTK
# base     NVNHERKD1JEVFA83A5Z61BI32UHG1CWEN5
# unichain CUU1U6PR8KRZQTAJ41CM1WA18EXXB4R5QI

set -x

THE_COMPACT_ADDRESS=0x00000000000018DF021Ff2467dF97ff846E09f48
MAILBOX_ADDRESS=$(cat ~/.hyperlane/chains/$CHAIN/addresses.yaml | yq '.mailbox')
ARBITER_ADDRESS=$(cat hyperlane-arbiters.yaml | yq ".$CHAIN")
RPC_URL=$(cat ~/.hyperlane/chains/$CHAIN/metadata.yaml | yq '.rpcUrls[0].http')
ETHERSCAN_API_KEY=CUU1U6PR8KRZQTAJ41CM1WA18EXXB4R5QI

CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address,address)" $MAILBOX_ADDRESS $THE_COMPACT_ADDRESS)

forge verify-contract $ARBITER_ADDRESS \
    --rpc-url $RPC_URL \
    --verifier-api-key $ETHERSCAN_API_KEY \
    --constructor-args $CONSTRUCTOR_ARGS \
    --watch
