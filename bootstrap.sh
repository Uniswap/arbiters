#!/bin/bash

# Function to load environment variables from a file
load_env() {
    local env_file="bootstrap.config"
    
    # Check if file exists
    if [ ! -f "$env_file" ]; then
        echo "Error: Environment file $env_file not found"
        return 1
    fi
    
    # Read file line by line
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip empty lines and comments
        if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi
        
        # Remove any trailing comments
        line="${line%%#*}"
        
        # Trim whitespace
        line="$(echo -e "${line}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        
        # Export the variable
        export "$line"
    done < "$env_file"
}

# Load environment variables
load_env

echo "Starting supersim..."

# Start supersim in a new screen session
screen -dmS supersim supersim

# Wait a moment for supersim to start
sleep 1

# Deploy Permit2 and The Compact to chain one
chain_one_batch() {
    {
        cast send --unlocked --from "$DEFAULT_DEPLOYER" "$PERMIT2_FACTORY_DEPLOYER" --value "$TEN_ETH" --rpc-url "$CHAIN_ONE_RPC"
        cast rpc anvil_impersonateAccount "$PERMIT2_FACTORY_DEPLOYER" --rpc-url "$CHAIN_ONE_RPC"
        cast send --unlocked --from "$PERMIT2_FACTORY_DEPLOYER" "$PERMIT2_FACTORY_ADDRESS" "$PERMIT2_CREATION_CODE" --rpc-url "$CHAIN_ONE_RPC"
        cast rpc anvil_stopImpersonatingAccount "$PERMIT2_FACTORY_DEPLOYER" --rpc-url "$CHAIN_ONE_RPC"

        cast rpc anvil_setCode "$IMMUTABLE_CREATE2_FACTORY_ADDRESS" "$IMMUTABLE_CREATE2_FACTORY_CODE" --rpc-url "$CHAIN_ONE_RPC"
        cast send --unlocked --from "$DEFAULT_DEPLOYER" "$IMMUTABLE_CREATE2_FACTORY_ADDRESS" "$THE_COMPACT_CREATION_CALLDATA" --rpc-url "$CHAIN_ONE_RPC"
        cast rpc anvil_setCode "$DEFAULT_SPONSOR" "$ALWAYS_VALID_1271_CODE" --rpc-url "$CHAIN_ONE_RPC"
        cast rpc anvil_setCode "$DEFAULT_ALLOCATOR" "$ALWAYS_VALID_1271_CODE" --rpc-url "$CHAIN_ONE_RPC"
        cast send --unlocked --from "$DEFAULT_DEPLOYER" "$THE_COMPACT_ADDRESS" "$REGISTER_DEFAULT_ALLOCATOR_CALLDATA" --rpc-url "$CHAIN_ONE_RPC"
        cast send --unlocked --from "$DEFAULT_SPONSOR" --value "$TEN_ETH" "$THE_COMPACT_ADDRESS" "$DEPOSIT_USING_DEFAULT_ALLOCATOR_CALLDATA" --rpc-url "$CHAIN_ONE_RPC"
    } &>/dev/null
}

# Deploy The Compact to chain two (Permit2 already there)
chain_two_batch() {
    {
        cast rpc anvil_setCode "$IMMUTABLE_CREATE2_FACTORY_ADDRESS" "$IMMUTABLE_CREATE2_FACTORY_CODE" --rpc-url "$CHAIN_TWO_RPC"
        cast send --unlocked --from "$DEFAULT_DEPLOYER" "$IMMUTABLE_CREATE2_FACTORY_ADDRESS" "$THE_COMPACT_CREATION_CALLDATA" --rpc-url "$CHAIN_TWO_RPC"
        cast rpc anvil_setCode "$DEFAULT_SPONSOR" "$ALWAYS_VALID_1271_CODE" --rpc-url "$CHAIN_TWO_RPC"
        cast rpc anvil_setCode "$DEFAULT_ALLOCATOR" "$ALWAYS_VALID_1271_CODE" --rpc-url "$CHAIN_TWO_RPC"
        cast send --unlocked --from "$DEFAULT_DEPLOYER" "$THE_COMPACT_ADDRESS" "$REGISTER_DEFAULT_ALLOCATOR_CALLDATA" --rpc-url "$CHAIN_TWO_RPC"
        cast send --unlocked --from "$DEFAULT_SPONSOR" --value "$TEN_ETH" "$THE_COMPACT_ADDRESS" "$DEPOSIT_USING_DEFAULT_ALLOCATOR_CALLDATA" --rpc-url "$CHAIN_TWO_RPC"
    } &>/dev/null
}

# Deploy The Compact to chain three (Permit2 already there)
chain_three_batch() {
    {
        cast rpc anvil_setCode "$IMMUTABLE_CREATE2_FACTORY_ADDRESS" "$IMMUTABLE_CREATE2_FACTORY_CODE" --rpc-url "$CHAIN_THREE_RPC"
        cast send --unlocked --from "$DEFAULT_DEPLOYER" "$IMMUTABLE_CREATE2_FACTORY_ADDRESS" "$THE_COMPACT_CREATION_CALLDATA" --rpc-url "$CHAIN_THREE_RPC"
        cast rpc anvil_setCode "$DEFAULT_SPONSOR" "$ALWAYS_VALID_1271_CODE" --rpc-url "$CHAIN_THREE_RPC"
        cast rpc anvil_setCode "$DEFAULT_ALLOCATOR" "$ALWAYS_VALID_1271_CODE" --rpc-url "$CHAIN_THREE_RPC"
        cast send --unlocked --from "$DEFAULT_DEPLOYER" "$THE_COMPACT_ADDRESS" "$REGISTER_DEFAULT_ALLOCATOR_CALLDATA" --rpc-url "$CHAIN_THREE_RPC"
        cast send --unlocked --from "$DEFAULT_SPONSOR" --value "$TEN_ETH" "$THE_COMPACT_ADDRESS" "$DEPOSIT_USING_DEFAULT_ALLOCATOR_CALLDATA" --rpc-url "$CHAIN_THREE_RPC"
    } &>/dev/null
}

# Run all batches in parallel
echo "Starting contract deployments..."
chain_one_batch & 
PID1=$!
chain_two_batch &
PID2=$!
chain_three_batch &
PID3=$!

# Wait for all batches to complete
wait $PID1 $PID2 $PID3
echo "All contract deployments completed."

# echo "PERMIT2 domain separators:"
# cast call "$PERMIT2_ADDRESS" "DOMAIN_SEPARATOR()" --rpc-url "$CHAIN_ONE_RPC"
# cast call "$PERMIT2_ADDRESS" "DOMAIN_SEPARATOR()" --rpc-url "$CHAIN_TWO_RPC"
# cast call "$PERMIT2_ADDRESS" "DOMAIN_SEPARATOR()" --rpc-url "$CHAIN_THREE_RPC"

# echo "The Compact Deployments:"
# cast call "$THE_COMPACT_ADDRESS" "name()" --rpc-url "$CHAIN_ONE_RPC" | cast --to-ascii
# cast call "$THE_COMPACT_ADDRESS" "name()" --rpc-url "$CHAIN_TWO_RPC" | cast --to-ascii
# cast call "$THE_COMPACT_ADDRESS" "name()" --rpc-url "$CHAIN_THREE_RPC" | cast --to-ascii

# NOTE: bootstrap each chain with some claimable tokens:
#  - deploy an AlwaysOKAllocator and register it
#  - deploy an AlwaysOKSponsor and deposit some tokens using AlwaysOKAllocator to it

## NOTE: this is where arbiter deployments and test scripts will go!

# Wait a moment before switching over to supersim screen
sleep 0.1

# Switch over to supersim screen (then ctrl+c to shut down)
screen -r supersim