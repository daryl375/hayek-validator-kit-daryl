#!/bin/bash

set -e

echo "✅ All containers are healthy."
echo "🚀 Running solana-localnet initialization tasks..."
echo

LABEL="SOLANA LOCALNET"
echolog() {
  echo
  echo "$LABEL: $1"
  echo
}

HERE="$(dirname "$0")"
readlink_cmd="readlink"
echo "OSTYPE IS: $OSTYPE"
if [[ $OSTYPE == darwin* ]]; then
  # Mac OS X's version of `readlink` does not support the -f option,
  # But `greadlink` does, which you can get with `brew install coreutils`
  readlink_cmd="greadlink"

  if ! command -v ${readlink_cmd} &>/dev/null; then
    echo "${readlink_cmd} could not be found. You may need to install coreutils: \`brew install coreutils\`"
    exit 1
  fi
fi

RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color
CURRENT_SCRIPT_RUNTIME_DIR="$("${readlink_cmd}" -f "${HERE}")"

# setup solana cli default signer
if [ -f ~/.config/solana/id_maybe.json ] && [ $(solana-keygen pubkey ~/.config/solana/id_maybe.json 2>/dev/null) ]; then
  if [ -f ~/.config/solana/id.json ]; then mv ~/.config/solana/id.json ~/.config/solana/id.json.bak; fi
  ln -sf ~/.config/solana/id_maybe.json ~/.config/solana/id.json
  echo -e "${YELLOW}Default solana cli signer ($(solana-keygen pubkey ~/.config/solana/id.json)) was imported from host${NC}"
else
  if [ ! -f ~/.config/solana/id.json ]; then
    echo -e "${YELLOW}Default solana cli signer was NOT imported from host. Generating default signer...${NC}"
    solana-keygen new -s --no-bip39-passphrase -o ~/.config/solana/id.json
  fi
  echo -e "${RED}WARNING: THIS SIGNER ($(solana-keygen pubkey ~/.config/solana/id.json)) IS EPHEMERAL AND WILL BE DESTROYED WHEN THE ansible-control CONTAINER IS STOPPED OR DELETED!${NC}"
fi

MAX_SLEEP_SECONDS=120
CURRENT_SLEEP_SECONDS=0
MIN_FINALIZED_SLOT=20 # Recommended value is 100. See https://github.com/mvines/validator-Identity-transition-demo?tab=readme-ov-file#start-a-test-validator-to-simulate-the-overall-solana-cluster

# # authorized host to ssh into the validators using ssh key
# if [ ! -f ~/.ssh/id_ed25519 ]; then
#   echo "Generating SSH key..."
#   ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
# fi
# if [ ! -f ~/.ssh/id_ed25519.pub ]; then
#   echo "Public SSH key not found. Exiting..."
#   exit 1
# fi

# the following is not needed because it is done in the docker-compose file
# OPERATOR_AUTHORIZED_SSH_KEY=$(cat ~/.ssh/id_ed25519.pub)
# docker exec -it canopy bash -c "sudo echo $OPERATOR_AUTHORIZED_SSH_KEY >> /home/sol/.ssh/authorized_keys"
# docker exec -it secondary bash -c "sudo echo $OPERATOR_AUTHORIZED_SSH_KEY >> /home/sol/.ssh/authorized_keys"

echolog "Waiting for $MIN_FINALIZED_SLOT finalized slots..."

while [ $CURRENT_SLEEP_SECONDS -lt $MAX_SLEEP_SECONDS ]; do
  LATEST_FINALIZED_SLOT=$(solana -ul --commitment finalized block --output json | jq -r ".parentSlot" || 0)
  echo "Finalized Slot: $LATEST_FINALIZED_SLOT | Elapsed: $CURRENT_SLEEP_SECONDS seconds"
  if [ ! -z "$LATEST_FINALIZED_SLOT" ] && [ $LATEST_FINALIZED_SLOT -gt $MIN_FINALIZED_SLOT ]; then
    break
  fi
  sleep 1
  CURRENT_SLEEP_SECONDS=$((CURRENT_SLEEP_SECONDS + 1))
done

if [ ! $LATEST_FINALIZED_SLOT -ge $MIN_FINALIZED_SLOT ]; then
  echo "Entry point didn't reach $MIN_FINALIZED_SLOT finalized slots after $MAX_SLEEP_SECONDS seconds. Exiting..."
  exit 1
fi

CLUSTER_RPC=http://localhost:8899

# Get the identity public key of the gossip entrypoint validator by:
# 1. Querying the local validator list with --keep-unstaked-delinquents to include all validators
# 2. Getting JSON output and using jq to extract the first validator's identity pubkey
# This will be used later to configure other validators to connect to the gossipentrypoint
ENTRYPOINT_IDENTITY_PUBKEY=$(solana -ul validators --keep-unstaked-delinquents --output json | jq -r ".validators | .[0].identityPubkey")

ANSIBLE_VALIDATORS_KEYS_DIR=/hayek-validator-kit/solana-localnet/validator-keys
ANSIBLE_CANOPY_KEYS_DIR="$ANSIBLE_VALIDATORS_KEYS_DIR/canopy"
ALPHA_CANOPY_KEYS_DIR="/home/sol/keys/canopy"
# We have the CANOPY SERVER BOX
# We have the CANOPY VALIDATOR KEY SET
# We could have the SEED VALIDATOR KEY SET deployed on the CANOPY SERVER BOX

MOUNT_ROOT_DIR=/mnt
LEDGER_DIR="${MOUNT_ROOT_DIR}/ledger"
ACCOUNTS_DIR="${MOUNT_ROOT_DIR}/accounts"
SNAPSHOTS_DIR="${MOUNT_ROOT_DIR}/snapshots"
LOGS_DIR="~/logs"
BIN_DIR="~/bin"

solana -u $CLUSTER_RPC epoch-info
# Airdrop 500k SOL to the default CLI signer at ~/.config/solana/id.json
solana -u $CLUSTER_RPC airdrop 500000

# Generate Canopy Accounts and Keys on the Ansible Control.
# They'll be used to configure the Canopy Validator in the script below.
echo "---   GENERATING ANSIBLE CANOPY VALIDATOR ACCOUNT KEYS...   ---"

echo ">>> ANSIBLE_CANOPY_KEYS_DIR: $ANSIBLE_CANOPY_KEYS_DIR"
echo ">>> ANSIBLE_VALIDATORS_KEYS_DIR: $ANSIBLE_VALIDATORS_KEYS_DIR"
mkdir -p "$ANSIBLE_CANOPY_KEYS_DIR"
cd "$ANSIBLE_CANOPY_KEYS_DIR"
source "$ANSIBLE_VALIDATORS_KEYS_DIR/_gen-validator-keys.sh"
#Airdrop 42 localnet SOL to the Canopy validator
solana -u $CLUSTER_RPC --keypair primary-target-identity.json airdrop 42
#Create a vote account for the Canopy validator
solana -u $CLUSTER_RPC create-vote-account vote-account.json primary-target-identity.json authorized-withdrawer.json
#Create a stake account with 200k SOL in it
solana -u $CLUSTER_RPC create-stake-account stake-account.json 200000
#Delegate the stake account to the vote account of the Canopy validator
solana -u $CLUSTER_RPC delegate-stake stake-account.json vote-account.json --force

# Generate ALPHA CANOPY validator startup script
echo "---   SETTING UP CANOPY VALIDATOR SCRIPT WITH ACCOUNT KEYS...   ---"
VOTE_ACCOUNT_PUBKEY=$(solana address -k $ANSIBLE_CANOPY_KEYS_DIR/vote-account.json)
EXPECTED_GENESIS_HASH=$(solana -u $CLUSTER_RPC genesis-hash)

CLUSTER_NAME=localnet
TMP_DIR=$(mktemp --directory)

# Function to log messages
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Function to handle errors
handle_error() {
    log "ERROR: $1"
    rm -rf "$TMP_DIR"
    exit 1
}

# Function to generate validator config
generate_tmp_validator_startup_script() {
    local output_file="${TMP_DIR}/agave-validator-$CLUSTER_NAME.sh"
    # Create the configuration file
    cat > "$output_file" << EOF
#!/bin/bash
agave-validator \\
    --identity ${ALPHA_CANOPY_KEYS_DIR}/identity.json \\
    --vote-account ${VOTE_ACCOUNT_PUBKEY} \\
    --authorized-voter ${ALPHA_CANOPY_KEYS_DIR}/primary-target-identity.json \\
    --known-validator ${ENTRYPOINT_IDENTITY_PUBKEY} \\
    --only-known-rpc \\
    --log /home/sol/logs/agave-validator.log \\
    --ledger /mnt/ledger \\
    --accounts /mnt/accounts \\
    --snapshots /mnt/snapshots \\
    --entrypoint gossip-entrypoint:8001 \\
    --expected-genesis-hash ${EXPECTED_GENESIS_HASH} \\
    --allow-private-addr \\
    --rpc-port 8899 \\
    --no-os-network-limits-test \\
    --limit-ledger-size 50000000
EOF
}

cleanup-tmp-dir() {
  trap 'rm -rf "$TMP_DIR"' EXIT
}

# Cleanup the host of the validator
# Parameters: HOST, SSH_PORT, USER
# USE: cleanup-host HOST SSH_PORT USER
cleanup-host() {
  USER=sol
  SSH_PORT=22
  : ${1?"Requires HOST"}
  HOST=$1

  # cleanup existing sol service
  ssh -o "StrictHostKeyChecking=no" -o "UserKnownHostsFile=/dev/null" "$USER@$HOST" -p $SSH_PORT "
    set -e

    sudo systemctl stop sol 2> /dev/null || true
    sudo systemctl disable sol 2> /dev/null || true
    sudo rm /etc/systemd/system/sol.service 2> /dev/null || true
    sudo rm /etc/systemd/system/sol.service 2> /dev/null || true # and symlinks that might be related
    sudo systemctl daemon-reload
    sudo systemctl reset-failed
  "
}

# Configure the validator on the host
# USE: configure-canopy-in-host HOST
configure-canopy-in-host() {
  USER=sol
  SSH_PORT=22
  : ${1?"Requires HOST"}
  HOST=$1

  HOST_SOLANA_BIN="~/.local/share/solana/install/active_release/bin"

  # Copy the primary-target-identity.json from the Ansible Control to the host
  scp -o "StrictHostKeyChecking=no" -o "UserKnownHostsFile=/dev/null" -P $SSH_PORT $ANSIBLE_CANOPY_KEYS_DIR/primary-target-identity.json "$USER@$HOST:~/primary-target-identity.json"

  # Generate the validator startup script
  ANSIBLE_CANOPY_STARTUP_SCRIPT=$CURRENT_SCRIPT_RUNTIME_DIR/agave-validator-localnet.sh
  generate_tmp_validator_startup_script
  cp -f $TMP_DIR/agave-validator-localnet.sh $ANSIBLE_CANOPY_STARTUP_SCRIPT
  chmod +x $ANSIBLE_CANOPY_STARTUP_SCRIPT
  if [ ! -f $ANSIBLE_CANOPY_STARTUP_SCRIPT ]; then
    echo "Validator startup script could not be created."
    exit 1
  fi

  echo "cat validator startup script at $ANSIBLE_CANOPY_STARTUP_SCRIPT"
  cat $ANSIBLE_CANOPY_STARTUP_SCRIPT
  echo

  # Transfer the validator startup script from Ansible to the Host's sol user's bin directory
  ssh -o "StrictHostKeyChecking=no" -o "UserKnownHostsFile=/dev/null" "$USER@$HOST" -p $SSH_PORT "mkdir -p ~/bin && chmod 754 ~/bin"
  scp -o "StrictHostKeyChecking=no" -o "UserKnownHostsFile=/dev/null" -P $SSH_PORT $ANSIBLE_CANOPY_STARTUP_SCRIPT "$USER@$HOST:~/bin/run-validator-canopy.sh"
  rm -rf $ANSIBLE_CANOPY_STARTUP_SCRIPT

  # Transfer the validator keys from Ansible to the Host's sol user's keys directory and create symlinks for identity.json
  ssh -o "StrictHostKeyChecking=no" -o "UserKnownHostsFile=/dev/null" "$USER@$HOST" -p $SSH_PORT "
    set -e
    # source ~/.profile
    PATH=$HOST_SOLANA_BIN:$PATH
    mkdir -p $ALPHA_CANOPY_KEYS_DIR && chmod 755 $ALPHA_CANOPY_KEYS_DIR
    mkdir -p ~/logs && chmod 755 ~/logs
    mv ~/primary-target-identity.json $ALPHA_CANOPY_KEYS_DIR/primary-target-identity.json
    ln -sf "$ALPHA_CANOPY_KEYS_DIR/primary-target-identity.json" "$ALPHA_CANOPY_KEYS_DIR/identity.json"

    if [ ! -f "$ALPHA_CANOPY_KEYS_DIR/hot-spare-identity.json" ]; then
      echo "Generating hot-spare-identity.json..."
      solana-keygen new -s --no-bip39-passphrase -o "$ALPHA_CANOPY_KEYS_DIR/hot-spare-identity.json"
    fi

(cat | sudo tee -a /etc/systemd/system/sol.service) <<EOF
[Unit]
Description=Solana Validator
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=5
User=sol
LimitNOFILE=1000000
LogRateLimitIntervalSec=0
Environment="PATH=/bin:/usr/bin:$HOST_SOLANA_BIN"
ExecStart=/home/sol/bin/run-validator-canopy.sh

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl enable --now sol
  "
}

echo
echo "---   Configuring Alpha Host with the Canopy Validator Node   ---"
echo
cleanup-host host-alpha
# docker exec -it primary bash -c 'sudo chown -R sol:sol /mnt/ledger && sudo chown -R sol:sol /mnt/accounts && sudo chown -R sol:sol /mnt/snapshots'
configure-canopy-in-host host-alpha

echo
echo "---   Configuring Bravo Host as a server that is ready for, but NOT running a validator   ---"
echo
cleanup-host host-bravo
# docker exec -it secondary bash -c 'sudo chown -R sol:sol /mnt/ledger && sudo chown -R sol:sol /mnt/accounts && sudo chown -R sol:sol /mnt/snapshots'
echo "---   ALL DONE. LOCALNET IS RUNNING.   ---"
