#!/bin/bash

###############################################################################
# Early safety: wait a bit and configure shell
###############################################################################
sleep 5                             # Give the environment a moment to settle
trap '' PIPE                        # Ignore SIGPIPE to avoid "Broken pipe"
set -euo pipefail                   # Abort on unhandled error / undefined var

###############################################################################
# Verify required binaries are present
###############################################################################
for bin in curl jq bc awk grep date; do
  command -v "$bin" >/dev/null || { echo "❌ Required binary '$bin' not found"; exit 1; }
done

###############################################################################
# UNIFIED CONFIGURATION (Using Environment Variables)
###############################################################################

# ===== LOAD ENVIRONMENT VARIABLES =====
# Try to source environment file if it exists
ENV_FILE="/usr/local/etc/hayek-monitor.env"
if [[ -f "$ENV_FILE" ]]; then
  echo "🔧 Loading environment variables from $ENV_FILE"
  source "$ENV_FILE"
else
  echo "⚠️ Environment file not found at $ENV_FILE, using fallback values"
fi

# ===== VALIDATOR CONFIGURATION BY NETWORK =====
# MAINNET - Use environment variables (NO FALLBACKS)
MAINNET_VOTE_ACCOUNT="${HAYEK_MAINNET_VOTE_ACCOUNT}"
MAINNET_IDENTITY_KEY="${HAYEK_MAINNET_IDENTITY}"
MAINNET_RPC_API="${SOLANA_MAINNET_RPC}"
MAINNET_HOST="${MAINNET_NAME_SUFFIX}"
MAINNET_STAKEWIZ_ENABLED=true
MAINNET_GOSSIP_ENABLED=true
MAINNET_JITO_MEV_ENABLED=true

# TESTNET - Use environment variables (NO FALLBACKS)
TESTNET_VOTE_ACCOUNT="${HAYEK_TESTNET_VOTE_ACCOUNT}"
TESTNET_IDENTITY_KEY="${HAYEK_TESTNET_IDENTITY}"
TESTNET_RPC_API="${SOLANA_TESTNET_RPC}"
TESTNET_HOST="${TESTNET_NAME_SUFFIX}"
TESTNET_STAKEWIZ_ENABLED=false
TESTNET_GOSSIP_ENABLED=true
TESTNET_JITO_MEV_ENABLED=true

# DEBUG - Use environment variables (NO FALLBACKS)
DEBUG_VOTE_ACCOUNT="${DEBUG_VOTE_ACCOUNT}"
DEBUG_IDENTITY_KEY="${DEBUG_IDENTITY_KEY}"
DEBUG_RPC_API="${SOLANA_MAINNET_RPC}"
DEBUG_HOST="${DEBUG_HOST}"
DEBUG_STAKEWIZ_ENABLED=false
DEBUG_GOSSIP_ENABLED=false
DEBUG_JITO_MEV_ENABLED=false

# ===== INFLUXDB CONFIGURATION =====
INFLUX_URL="${INFLUX_URL}"
INFLUX_USER="${INFLUX_USER}"
INFLUX_PASS="${INFLUX_PASS}"   # ⚠️ NO FALLBACK - Must be set in environment file

# ===== VALIDATE CRITICAL ENVIRONMENT VARIABLES =====
MISSING_VARS=()

# Check InfluxDB credentials
[[ -z "$INFLUX_URL" ]] && MISSING_VARS+=("INFLUX_URL")
[[ -z "$INFLUX_USER" ]] && MISSING_VARS+=("INFLUX_USER")
[[ -z "$INFLUX_PASS" ]] && MISSING_VARS+=("INFLUX_PASS")

# Check validator keys
[[ -z "$HAYEK_MAINNET_VOTE_ACCOUNT" ]] && MISSING_VARS+=("HAYEK_MAINNET_VOTE_ACCOUNT")
[[ -z "$HAYEK_MAINNET_IDENTITY" ]] && MISSING_VARS+=("HAYEK_MAINNET_IDENTITY")
[[ -z "$HAYEK_TESTNET_VOTE_ACCOUNT" ]] && MISSING_VARS+=("HAYEK_TESTNET_VOTE_ACCOUNT")
[[ -z "$HAYEK_TESTNET_IDENTITY" ]] && MISSING_VARS+=("HAYEK_TESTNET_IDENTITY")

# Check RPC endpoints
[[ -z "$SOLANA_MAINNET_RPC" ]] && MISSING_VARS+=("SOLANA_MAINNET_RPC")
[[ -z "$SOLANA_TESTNET_RPC" ]] && MISSING_VARS+=("SOLANA_TESTNET_RPC")

# Check host names
[[ -z "$MAINNET_NAME_SUFFIX" ]] && MISSING_VARS+=("MAINNET_NAME_SUFFIX")
[[ -z "$TESTNET_NAME_SUFFIX" ]] && MISSING_VARS+=("TESTNET_NAME_SUFFIX")

# Check database names
[[ -z "$INFLUX_DB_BLOCKS" ]] && MISSING_VARS+=("INFLUX_DB_BLOCKS")
[[ -z "$INFLUX_DB_VALIDATOR" ]] && MISSING_VARS+=("INFLUX_DB_VALIDATOR")

# Check Solana binary path
[[ -z "$SOLANA_BIN" ]] && MISSING_VARS+=("SOLANA_BIN")

# Exit if any critical variables are missing
if [[ ${#MISSING_VARS[@]} -gt 0 ]]; then
  echo "❌ ERROR: Missing required environment variables:"
  for var in "${MISSING_VARS[@]}"; do
    echo "  - $var"
  done
  echo ""
  echo "Please ensure these variables are defined in $ENV_FILE"
  echo "The script cannot run safely without these credentials."
  exit 1
fi

echo "✅ All critical environment variables are set"

# Database names for different metric types
INFLUX_DB_VALIDATOR="${INFLUX_DB_VALIDATOR}"  # For validator metrics (from env file)
INFLUX_DB_BLOCKS="${INFLUX_DB_BLOCKS}"        # For block metrics (from env file)

# ===== PROCESSING TOGGLES =====
PROCESS_MAINNET=true
PROCESS_TESTNET=true
PROCESS_DEBUG=false

# ===== ABSOLUTE PATH TO SOLANA BIN =====
SOLANA_BIN="${SOLANA_BIN}"

###############################################################################
# Locate Solana binary if the default path does not exist
###############################################################################
if [ ! -x "$SOLANA_BIN" ]; then
  echo "⚠️  Solana binary not found at $SOLANA_BIN — probing PATH"
  SOLANA_BIN="$(command -v solana || true)"
  [ -x "$SOLANA_BIN" ] || { echo "❌ Solana CLI not found"; exit 1; }
  echo "✅ Using Solana at $SOLANA_BIN"
fi

###############################################################################
# Basic connectivity checks (RPC endpoints and InfluxDB)
###############################################################################
check_endpoint () {
  local url="$1" name="$2"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" "$url")
  echo "- $name: HTTP $code"
  [ "$code" = "200" ] || [ "$code" = "204" ] || { echo "❌ Cannot reach $name"; exit 1; }
}

echo "🔍 Checking connectivity..."
$PROCESS_MAINNET  && check_endpoint "$MAINNET_RPC_API" "Mainnet RPC"
$PROCESS_TESTNET  && check_endpoint "$TESTNET_RPC_API" "Testnet RPC"
$PROCESS_DEBUG    && check_endpoint "$DEBUG_RPC_API"   "Debug RPC"
check_endpoint "$INFLUX_URL/ping" "InfluxDB"
echo

###############################################################################
# VALIDATOR METRICS FUNCTIONS (from send_validator_metrics_jito.sh)
###############################################################################

# ===== FUNCTION TO CALCULATE SLOT DURATION DYNAMICALLY =====
get_slot_duration_ms() {
  local RPC_URL="$1"
  local CLUSTER="$2"

  local CMD=""
  case "$CLUSTER" in
    mainnet) CMD="$SOLANA_BIN -u m epoch-info" ;;
    testnet) CMD="$SOLANA_BIN -u t epoch-info" ;;
    debug) CMD="$SOLANA_BIN -u m epoch-info" ;;
    *) CMD="$SOLANA_BIN epoch-info" ;;
  esac

  local EPOCH_CLI_INFO=$($CMD 2>/dev/null)
  if [[ -z "$EPOCH_CLI_INFO" ]]; then
    echo "420"
    return
  fi

  local EPOCH_TOTAL_TIME=$(echo "$EPOCH_CLI_INFO" | grep "Epoch Completed Time:" | sed 's/.*\/\(.*\) (.*/\1/')
  if [[ -z "$EPOCH_TOTAL_TIME" ]]; then
    echo "420"
    return
  fi

  local DAYS=$(echo "$EPOCH_TOTAL_TIME" | grep -o "[0-9]\+day" | sed 's/day//')
  local HOURS=$(echo "$EPOCH_TOTAL_TIME" | grep -o "[0-9]\+h" | sed 's/h//')
  local MINUTES=$(echo "$EPOCH_TOTAL_TIME" | grep -o "[0-9]\+m" | sed 's/m//')
  local SECONDS=$(echo "$EPOCH_TOTAL_TIME" | grep -o "[0-9]\+s" | sed 's/s//')

  DAYS=${DAYS:-0}
  HOURS=${HOURS:-0}
  MINUTES=${MINUTES:-0}
  SECONDS=${SECONDS:-0}

  local TOTAL_SECONDS=$((DAYS*86400 + HOURS*3600 + MINUTES*60 + SECONDS))
  local SLOTS_PER_EPOCH=432000
  local SLOT_DURATION_MS=$(awk -v secs="$TOTAL_SECONDS" -v slots="$SLOTS_PER_EPOCH" 'BEGIN { printf "%.0f", (secs / slots) * 1000 }')

  if [[ -z "$SLOT_DURATION_MS" || "$SLOT_DURATION_MS" -lt 100 || "$SLOT_DURATION_MS" -gt 1000 ]]; then
    echo "420"
  else
    echo "$SLOT_DURATION_MS"
  fi
}

# ===== FUNCTION TO GET RPC VERSION =====
get_rpc_version() {
  local IDENTITY_KEY="$1"
  local RPC_URL="$2"
  curl -s --max-time 10 "$RPC_URL" -X POST -H "Content-Type: application/json" -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "getAccountInfo",
    "params": ["'"$IDENTITY_KEY"'", {"encoding": "base58"}]
  }' | jq -r '.result.context.apiVersion'
}

# ===== FUNCTION TO GET GOSSIP VERSION FROM SOLANA CLI =====
get_gossip_version() {
  local IDENTITY_KEY="$1"
  local CLUSTER="$2"
  local CMD=""
  local GOSSIP_VERSION=""

  case "$CLUSTER" in
    mainnet) CMD="$SOLANA_BIN -u m -v gossip" ;;
    testnet) CMD="timeout 15 $SOLANA_BIN -u t -v gossip" ;;
    debug) CMD="$SOLANA_BIN -u m -v gossip" ;;
    *) return ;;
  esac

  GOSSIP_LINE=$($CMD 2>/dev/null | grep "$IDENTITY_KEY")
  if [[ -n "$GOSSIP_LINE" ]]; then
    GOSSIP_VERSION=$(echo "$GOSSIP_LINE" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $7); print $7}')
  fi

  echo "$GOSSIP_VERSION"
}

# ===== FUNCTION TO GET TVC RANK =====
get_tvc_rank() {
  local TVC_RANK_DATA=$(curl -s --max-time 5 "http://localhost:8000/tvc-rank")

  if echo "$TVC_RANK_DATA" | jq -e '.output' >/dev/null 2>&1; then
    local RANK=$(echo "$TVC_RANK_DATA" | jq -r '.output' | grep -o '[0-9]\+')
    echo "$RANK"
  else
    echo ""
  fi
}

# ===== FUNCTION TO GET AND SEND JITO MEV STATS PER EPOCH (NEW EPOCHS ONLY) =====
send_jito_mev_epochs_new_only() {
  local VOTE_ACCOUNT="$1"
  local IDENTITY_KEY="$2"
  local HOST="$3"
  local JITO_API_URL="https://kobe.mainnet.jito.network/api/v1/validators/${VOTE_ACCOUNT}"

  # Get the latest epoch from InfluxDB
  local LATEST_EPOCH_QUERY="SELECT max(epoch) FROM jito_mev_epochs WHERE host='${HOST}' AND pubkey='${IDENTITY_KEY}'"
  local LATEST_EPOCH_DATA=$(curl -s -G "${INFLUX_URL}/query" \
    --user "${INFLUX_USER}:${INFLUX_PASS}" \
    --data-urlencode "db=${INFLUX_DB_VALIDATOR}" \
    --data-urlencode "q=${LATEST_EPOCH_QUERY}")

  local LATEST_EPOCH=$(echo "$LATEST_EPOCH_DATA" | jq -r '.results[0].series[0].values[0][1] // 0')

  # Get Jito MEV data with 10 second timeout
  local JITO_MEV_DATA=$(curl -s --max-time 10 "$JITO_API_URL")

  # Check if we got valid JSON array response
  if echo "$JITO_MEV_DATA" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "🔍 Processing new Jito MEV epochs for $HOST (latest in DB: $LATEST_EPOCH)"

    # Process each epoch individually, only if it's newer than the latest in DB
    echo "$JITO_MEV_DATA" | jq -c '.[]' | while read -r EPOCH_DATA; do
      local EPOCH=$(echo "$EPOCH_DATA" | jq -r '.epoch')

      # Only process epochs newer than the latest in database
      if [[ "$EPOCH" -gt "$LATEST_EPOCH" ]]; then
        local MEV_REWARDS_LAMPORTS=$(echo "$EPOCH_DATA" | jq -r '.mev_rewards')
        local MEV_COMMISSION_BPS=$(echo "$EPOCH_DATA" | jq -r '.mev_commission_bps')

        # Calculate operator rewards in lamports for this epoch
        local OPERATOR_REWARDS_LAMPORTS=$(awk -v rewards="$MEV_REWARDS_LAMPORTS" -v commission="$MEV_COMMISSION_BPS" 'BEGIN { printf "%.0f", (rewards * commission) / 10000 }')

        # Convert lamports to SOL (1 SOL = 1,000,000,000 lamports)
        local MEV_REWARDS_SOL=$(awk -v lamports="$MEV_REWARDS_LAMPORTS" 'BEGIN { printf "%.9f", lamports / 1000000000 }')
        local OPERATOR_REWARDS_SOL=$(awk -v lamports="$OPERATOR_REWARDS_LAMPORTS" 'BEGIN { printf "%.9f", lamports / 1000000000 }')

        # Create InfluxDB line protocol with both lamports and SOL
        local TIMESTAMP=$(date +%s%N)
        local TAGS="host=${HOST},pubkey=${IDENTITY_KEY},epoch=${EPOCH}"
        local FIELDS="jito_mev_rewards_lamports=${MEV_REWARDS_LAMPORTS},jito_mev_rewards_sol=${MEV_REWARDS_SOL},jito_mev_commission_bps=${MEV_COMMISSION_BPS},jito_operator_rewards_lamports=${OPERATOR_REWARDS_LAMPORTS},jito_operator_rewards_sol=${OPERATOR_REWARDS_SOL}"

        local LINE="jito_mev_epochs,${TAGS} ${FIELDS} ${TIMESTAMP}"

        # Send to InfluxDB
        curl -s -XPOST "${INFLUX_URL}/write?db=${INFLUX_DB_VALIDATOR}" --user "${INFLUX_USER}:${INFLUX_PASS}" --data-binary "$LINE"

        echo "✅ New Epoch $EPOCH - MEV: ${MEV_REWARDS_SOL} SOL (${MEV_REWARDS_LAMPORTS} lamports), Operator: ${OPERATOR_REWARDS_SOL} SOL (${OPERATOR_REWARDS_LAMPORTS} lamports)"
      else
        echo "⏭️ Epoch $EPOCH already exists in database (<= $LATEST_EPOCH), skipping..."
      fi
    done

  else
    echo "❌ Error: Could not get Jito MEV data for $HOST"
  fi
}

# ===== FUNCTION TO GET NEXT EPOCH LEADER SLOT COUNT =====
get_next_epoch_leader_slot_count() {
  local IDENTITY_KEY="$1"
  local CLUSTER="$2"
  local CURRENT_EPOCH
  local NEXT_EPOCH
  local SLOTS_RAW
  local CMD=""

  case "$CLUSTER" in
    mainnet) CMD="$SOLANA_BIN -u m" ;;
    testnet) CMD="$SOLANA_BIN -u t" ;;
    debug) CMD="$SOLANA_BIN -u m" ;;
    *) echo "0"; return ;;
  esac

  CURRENT_EPOCH=$($CMD epoch 2>/dev/null | awk '{print $1}')
  if [[ -z "$CURRENT_EPOCH" || ! "$CURRENT_EPOCH" =~ ^[0-9]+$ ]]; then
    echo ""
    return
  fi

  NEXT_EPOCH=$((CURRENT_EPOCH + 1))
  SLOTS_RAW=$($CMD leader-schedule --epoch "$NEXT_EPOCH" 2>/dev/null | grep "$IDENTITY_KEY")

  if [[ -n "$SLOTS_RAW" ]]; then
    echo "$SLOTS_RAW" | awk -F':' '{gsub(/[ \[\]]/, "", $2); print $2}' | tr ',' '\n' | wc -l
  else
    echo "0"
  fi
}

# ===== FUNCTION TO SEND VALIDATOR METRICS TO INFLUXDB =====
send_validator_metrics() {
  local VOTE_ACCOUNT="$1"
  local IDENTITY_KEY="$2"
  local RPC_URL="$3"
  local HOST="$4"
  local STAKEWIZ_ENABLED="$5"
  local GOSSIP_ENABLED="$6"
  local JITO_MEV_ENABLED="$7"

  echo "📊 Collecting validator metrics for $HOST..."

  ACTIVATING_STAKE=""
  RANK=""
  WIZ_SCORE=""
  IS_JITO=""
  GOSSIP_VERSION=""
  TVC_RANK=""

  if [[ "$STAKEWIZ_ENABLED" == true ]]; then
    STAKEWIZ_EPOCH_DATA=$(curl -s --max-time 5 "https://api.stakewiz.com/validator_epoch_stakes/${VOTE_ACCOUNT}")
    if echo "$STAKEWIZ_EPOCH_DATA" | jq -e 'type == "array"' >/dev/null 2>&1; then
      ACTIVATING_STAKE=$(echo "$STAKEWIZ_EPOCH_DATA" | jq -r '.[0].activating_stake // empty')
    fi

    STAKEWIZ_VAL_DATA=$(curl -s --max-time 5 "https://api.stakewiz.com/validator/${VOTE_ACCOUNT}")
    if echo "$STAKEWIZ_VAL_DATA" | jq -e 'type == "object"' >/dev/null 2>&1; then
      RANK=$(echo "$STAKEWIZ_VAL_DATA" | jq -r '.rank // empty')
      WIZ_SCORE=$(echo "$STAKEWIZ_VAL_DATA" | jq -r '.wiz_score // empty')
      IS_JITO=$(echo "$STAKEWIZ_VAL_DATA" | jq -r '.is_jito // empty')
    fi
  fi

  # Determine the cluster based on the host
  CLUSTER=""
  [[ "$HOST" == "$MAINNET_HOST" ]] && CLUSTER="mainnet"
  [[ "$HOST" == "$TESTNET_HOST" ]] && CLUSTER="testnet"
  [[ "$HOST" == "$DEBUG_HOST" ]] && CLUSTER="debug"

  # Get TVC Rank for MAINNET only
  if [[ "$HOST" == "$MAINNET_HOST" ]]; then
    TVC_RANK=$(get_tvc_rank)
  fi

  # Get and send Jito MEV metrics per epoch (mainnet only)
  if [[ "$JITO_MEV_ENABLED" == true && "$HOST" == "$MAINNET_HOST" ]]; then
    send_jito_mev_epochs_new_only "$VOTE_ACCOUNT" "$IDENTITY_KEY" "$HOST"
  fi

  RPC_VERSION=$(get_rpc_version "$IDENTITY_KEY" "$RPC_URL")

  if [[ "$GOSSIP_ENABLED" == true ]]; then
    GOSSIP_VERSION=$(get_gossip_version "$IDENTITY_KEY" "$CLUSTER")
  fi

  # Get the slot duration for this specific cluster
  SLOT_DURATION_MS=$(get_slot_duration_ms "$RPC_URL" "$CLUSTER")

  EPOCH_INFO=$(curl -s --max-time 10 "$RPC_URL" -X POST -H "Content-Type: application/json" -d '{"jsonrpc": "2.0", "id": 1, "method": "getEpochInfo"}')
  LEADER_SCHEDULE=$(curl -s --max-time 10 "$RPC_URL" -X POST -H "Content-Type: application/json" -d '{"jsonrpc": "2.0", "id": 1, "method": "getLeaderSchedule", "params": [null, {"identity": "'"$IDENTITY_KEY"'"}]}')
  CURRENT_SLOT=$(curl -s --max-time 10 "$RPC_URL" -X POST -H "Content-Type: application/json" -d '{"jsonrpc": "2.0", "id": 1, "method": "getSlot"}' | jq -r '.result')
  SLOT_INDEX=$(echo "$EPOCH_INFO" | jq -r '.result.slotIndex')

  # Calculate the time until the end of the epoch
  SLOTS_PER_EPOCH=$(echo "$EPOCH_INFO" | jq -r '.result.slotsInEpoch')
  SLOTS_REMAINING_IN_EPOCH=$((SLOTS_PER_EPOCH - SLOT_INDEX))
  TIME_TO_EPOCH_END_S=$(awk -v slots="$SLOTS_REMAINING_IN_EPOCH" -v dur="$SLOT_DURATION_MS" 'BEGIN { printf "%.2f", (slots * dur) / 1000 }')

  # Convert to human-readable format (days, hours, minutes, seconds)
  EPOCH_END_DAYS=$(awk -v time="$TIME_TO_EPOCH_END_S" 'BEGIN { printf "%.0f", int(time / 86400) }')
  EPOCH_END_HOURS=$(awk -v time="$TIME_TO_EPOCH_END_S" -v days="$EPOCH_END_DAYS" 'BEGIN { printf "%.0f", int((time - days * 86400) / 3600) }')
  EPOCH_END_MINUTES=$(awk -v time="$TIME_TO_EPOCH_END_S" -v days="$EPOCH_END_DAYS" -v hours="$EPOCH_END_HOURS" 'BEGIN { printf "%.0f", int((time - days * 86400 - hours * 3600) / 60) }')
  EPOCH_END_SECONDS=$(awk -v time="$TIME_TO_EPOCH_END_S" -v days="$EPOCH_END_DAYS" -v hours="$EPOCH_END_HOURS" -v mins="$EPOCH_END_MINUTES" 'BEGIN { printf "%.0f", int(time - days * 86400 - hours * 3600 - mins * 60) }')

  # Create human-readable string
  EPOCH_END_HUMAN="${EPOCH_END_DAYS}d ${EPOCH_END_HOURS}h ${EPOCH_END_MINUTES}m ${EPOCH_END_SECONDS}s"

  # Calculate epoch completion percentage
  EPOCH_COMPLETED_PCT=$(awk -v current="$SLOT_INDEX" -v total="$SLOTS_PER_EPOCH" 'BEGIN { printf "%.2f", (current / total) * 100 }')

  LEADER_SLOTS_RAW=$(echo "$LEADER_SCHEDULE" | jq -r '.result."'"$IDENTITY_KEY"'" // empty')
  LEADER_SLOTS=$(echo "$LEADER_SLOTS_RAW" | jq -c '.')
  TOTAL_LEADER_SLOTS=$(echo "$LEADER_SLOTS" | jq 'length')

  if [[ -n "$ACTIVATING_STAKE" || -n "$RANK" || -n "$WIZ_SCORE" || -n "$RPC_VERSION" || -n "$GOSSIP_VERSION" || -n "$TVC_RANK" ]]; then
    TIMESTAMP=$(date +%s%N)
    TAGS="host=${HOST},pubkey=${IDENTITY_KEY}"
    FIELDS=""

    [[ -n "$ACTIVATING_STAKE" && "$ACTIVATING_STAKE" != "null" ]] && FIELDS+="activating_stake=${ACTIVATING_STAKE}"
    [[ -n "$RANK" ]] && FIELDS+="${FIELDS:+,}rank=${RANK}"
    [[ -n "$WIZ_SCORE" ]] && FIELDS+="${FIELDS:+,}wiz_score=${WIZ_SCORE}"
    [[ -n "$RPC_VERSION" && "$RPC_VERSION" != "null" ]] && FIELDS+="${FIELDS:+,}rpc_version=\"${RPC_VERSION}\""
    [[ -n "$GOSSIP_VERSION" ]] && FIELDS+="${FIELDS:+,}gossip_version=\"${GOSSIP_VERSION}\""
    [[ "$IS_JITO" == "true" ]] && FIELDS+="${FIELDS:+,}is_jito=t"
    [[ "$IS_JITO" == "false" ]] && FIELDS+="${FIELDS:+,}is_jito=f"
    [[ -n "$TVC_RANK" ]] && FIELDS+="${FIELDS:+,}tvc_rank=${TVC_RANK}"

    # Add the new slot duration and epoch end metrics
    FIELDS+="${FIELDS:+,}slot_duration_ms=${SLOT_DURATION_MS}"
    FIELDS+="${FIELDS:+,}time_to_epoch_end_s=${TIME_TO_EPOCH_END_S}"
    FIELDS+="${FIELDS:+,}time_to_epoch_end_human=\"${EPOCH_END_HUMAN}\""
    FIELDS+="${FIELDS:+,}epoch_completed_pct=${EPOCH_COMPLETED_PCT}"

    if [[ "$TOTAL_LEADER_SLOTS" -gt 0 && "$SLOT_INDEX" -ge 0 ]]; then
      NEXT_LEADER_SLOT=$(echo "$LEADER_SLOTS" | jq '[.[] | select(. > '"$SLOT_INDEX"')] | min // empty')
      LAST_LEADER_SLOT=$(echo "$LEADER_SLOTS" | jq '[.[] | select(. <= '"$SLOT_INDEX"')] | max // empty')
      LEADER_SLOTS_PASSED=$(echo "$LEADER_SLOTS" | jq '[.[] | select(. <= '"$SLOT_INDEX"')] | length')
      LEADER_SLOTS_REMAINING=$(echo "$LEADER_SLOTS" | jq '[.[] | select(. > '"$SLOT_INDEX"')] | length')
      REMAINING_RATIO=$(awk -v rem="$LEADER_SLOTS_REMAINING" -v total="$TOTAL_LEADER_SLOTS" 'BEGIN { if (total>0) printf "%.2f", (rem / total) * 100; else print 0 }')

      FIELDS+="${FIELDS:+,}leader_slot_count=${TOTAL_LEADER_SLOTS},leader_slots_passed=${LEADER_SLOTS_PASSED},leader_slots_remaining=${LEADER_SLOTS_REMAINING},leader_slots_remaining_ratio=${REMAINING_RATIO}"

      if [[ -n "$NEXT_LEADER_SLOT" ]]; then
        SLOTS_REMAINING=$((NEXT_LEADER_SLOT - SLOT_INDEX))
        TIME_TO_NEXT_LEADER_SLOT_S=$(awk -v slots="$SLOTS_REMAINING" -v dur="$SLOT_DURATION_MS" 'BEGIN { printf "%.2f", (slots * dur) / 1000 }')
        PROGRESS_TO_NEXT=$(awk -v a="$SLOT_INDEX" -v b="$NEXT_LEADER_SLOT" 'BEGIN { if (b>0) printf "%.2f", (a/b)*100; else print 0 }')
        FIELDS+="${FIELDS:+,}time_to_next_leader_slot_s=${TIME_TO_NEXT_LEADER_SLOT_S},leader_progress_percentage=${PROGRESS_TO_NEXT}"

        if [[ -n "$LAST_LEADER_SLOT" && "$NEXT_LEADER_SLOT" -ne "$LAST_LEADER_SLOT" ]]; then
          PROGRESS_SINCE_LAST=$(awk -v current="$SLOT_INDEX" -v last="$LAST_LEADER_SLOT" -v next_slot="$NEXT_LEADER_SLOT" 'BEGIN { if ((next_slot - last) > 0) printf "%.2f", ((current - last) / (next_slot - last)) * 100; else printf "0.00" }')
        else
          PROGRESS_SINCE_LAST=$(awk -v current="$SLOT_INDEX" -v next_slot="$NEXT_LEADER_SLOT" 'BEGIN { if (next_slot > 0) printf "%.2f", (current / next_slot) * 100; else printf "0.00" }')
        fi
        FIELDS+="${FIELDS:+,}leader_progress_since_last=${PROGRESS_SINCE_LAST}"

        # Add time between leader slots metric
        if [[ -n "$LAST_LEADER_SLOT" ]]; then
          SLOTS_BETWEEN=$((NEXT_LEADER_SLOT - LAST_LEADER_SLOT))
          TIME_BETWEEN_LEADER_SLOTS_S=$(awk -v slots="$SLOTS_BETWEEN" -v dur="$SLOT_DURATION_MS" 'BEGIN { printf "%.2f", (slots * dur) / 1000 }')
          FIELDS+="${FIELDS:+,}time_between_leader_slots_s=${TIME_BETWEEN_LEADER_SLOTS_S}"
        fi
      else
        FIELDS+="${FIELDS:+,}time_to_next_leader_slot_s=0,leader_progress_percentage=0.00,leader_progress_since_last=0.00"
      fi
    fi

    NEXT_EPOCH_SLOT_COUNT=$(get_next_epoch_leader_slot_count "$IDENTITY_KEY" "$CLUSTER")
    if [[ -n "$NEXT_EPOCH_SLOT_COUNT" ]]; then
      FIELDS+="${FIELDS:+,}next_epoch_leader_slot_count=${NEXT_EPOCH_SLOT_COUNT}"
    fi

    LINE="nodemonitor,${TAGS} ${FIELDS} ${TIMESTAMP}"
    curl -s -XPOST "${INFLUX_URL}/write?db=${INFLUX_DB_VALIDATOR}" --user "${INFLUX_USER}:${INFLUX_PASS}" --data-binary "$LINE"
    echo "✅ Validator metrics sent for $HOST"
  else
    echo "❌ Error: invalid validator metrics for $HOST (vote=$VOTE_ACCOUNT, id=$IDENTITY_KEY)"
  fi
}

###############################################################################
# BLOCK METRICS FUNCTIONS
###############################################################################

# ===== FUNCTION: CHECK PRODUCED BLOCKS FOR A SINGLE CLUSTER =====
check_produced_blocks () {
  local IDENTITY_KEY="$1" HOST="$2" CLUSTER="$3"
  local CMD

  case "$CLUSTER" in
    mainnet) CMD="$SOLANA_BIN -u m" ;;
    testnet) CMD="$SOLANA_BIN -u t" ;;
    debug)   CMD="$SOLANA_BIN -u m" ;;
    *)       echo "Unknown cluster $CLUSTER"; return 1 ;;
  esac

  echo "🔍 Checking blocks for $HOST on $CLUSTER"

  local CURRENT_SLOT CURRENT_EPOCH
  CURRENT_SLOT="$($CMD slot 2>/dev/null || true)"
  CURRENT_EPOCH="$($CMD epoch 2>/dev/null | awk '{print $1}')"

  [ -n "$CURRENT_SLOT" ] || { echo "⚠️  Cannot fetch current slot"; return 1; }
  [ -n "$CURRENT_EPOCH" ] || { echo "⚠️  Cannot fetch current epoch"; return 1; }

  echo "ℹ️  Current epoch $CURRENT_EPOCH • current slot $CURRENT_SLOT"

  # Collect validator leader slots
  local SLOTS
  SLOTS="$($CMD leader-schedule 2>/dev/null | awk -v key="$IDENTITY_KEY" '$0 ~ key {print $1}')"

  [ -n "$SLOTS" ] || { echo "ℹ️  No leader slots found"; return 0; }

  # Stats counters
  local PRODUCED=0 SKIPPED=0 CACHED=0 UPDATED=0 TOTAL_REWARD=0
  local SLOTS_24H_AGO=$((CURRENT_SLOT - 216000))   # ~24h worth of slots (0.4 s/slot)

  # Iterate leader slots
  for SLOT in $SLOTS; do
    (( SLOT < SLOTS_24H_AGO )) && continue
    # Skip if data already exists and was produced
    local RESPONSE PRODUCED_IN_DB
    RESPONSE=$(curl -sG "$INFLUX_URL/query" \
                --user "$INFLUX_USER:$INFLUX_PASS" \
                --data-urlencode "db=$INFLUX_DB_BLOCKS" \
                --data-urlencode "q=SELECT produced FROM blockmetrics WHERE slot='$SLOT' AND host='$HOST' LIMIT 1")
    PRODUCED_IN_DB=$(echo "$RESPONSE" | jq -r '.results[0].series[0].values[0][1]' 2>/dev/null || echo "")
    [ "$PRODUCED_IN_DB" = "1" ] && { ((CACHED++)); continue; }

    # Only evaluate past slots
    if (( SLOT <= CURRENT_SLOT )); then
      local OUTPUT BLOCK_PRODUCED=0 REWARD="0.000000000"
      OUTPUT="$($CMD block "$SLOT" 2>&1 || true)"

      if [[ $OUTPUT == *"Total Rewards:"* ]]; then
        ((PRODUCED++))
        REWARD=$(awk '/Total Rewards:/ {print $3}' <<< "$OUTPUT" | sed 's/◎//')
        BLOCK_PRODUCED=1
        TOTAL_REWARD=$(bc -l <<< "$TOTAL_REWARD + $REWARD")
        echo "✅ Slot $SLOT produced • reward $REWARD SOL"
      elif [[ $OUTPUT == *"was skipped,"* ]]; then
        ((SKIPPED++))
        echo "❌ Slot $SLOT skipped"
      elif [ "$PRODUCED_IN_DB" = "0" ]; then
        ((UPDATED++))
        echo "🔄 Slot $SLOT updated"
      fi

      # Write single-slot metrics to InfluxDB
      local TIMESTAMP LINE
      TIMESTAMP=$(date +%s%N)
      LINE="blockmetrics,host=${HOST},epoch=${CURRENT_EPOCH},slot=${SLOT},pubkey=${IDENTITY_KEY} produced=${BLOCK_PRODUCED},reward=${REWARD} ${TIMESTAMP}"
      curl -s -XPOST "$INFLUX_URL/write?db=$INFLUX_DB_BLOCKS" \
           --user "$INFLUX_USER:$INFLUX_PASS" \
           --data-binary "$LINE" >/dev/null
    fi
  done

  # Store total reward per epoch if any
  if [[ $TOTAL_REWARD != 0 ]]; then
    local TS
    TS=$(date +%s%N)
    curl -s -XPOST "$INFLUX_URL/write?db=$INFLUX_DB_BLOCKS" \
      --user "$INFLUX_USER:$INFLUX_PASS" \
      --data-binary "epoch_rewards,host=${HOST},epoch=${CURRENT_EPOCH} pubkey=\"${IDENTITY_KEY}\",total_reward_sol=${TOTAL_REWARD} ${TS}" >/dev/null
    echo "💰 Total reward for $HOST: $TOTAL_REWARD SOL"
  fi

  # Echo stats for caller
  printf "PRODUCED=%d\nSKIPPED=%d\nCACHED=%d\nUPDATED=%d\nTOTAL_REWARD=%s\n" \
         "$PRODUCED" "$SKIPPED" "$CACHED" "$UPDATED" "$TOTAL_REWARD"
}

###############################################################################
# MAIN EXECUTION FUNCTIONS
###############################################################################

# ===== FUNCTION TO COLLECT VALIDATOR METRICS FOR ALL NETWORKS =====
collect_all_validator_metrics() {
  echo "=========================================="
  echo "    COLLECTING VALIDATOR METRICS"
  echo "=========================================="

  # Process validator metrics for each configured network
  send_validator_metrics "$MAINNET_VOTE_ACCOUNT" "$MAINNET_IDENTITY_KEY" "$MAINNET_RPC_API" "$MAINNET_HOST" "$MAINNET_STAKEWIZ_ENABLED" "$MAINNET_GOSSIP_ENABLED" "$MAINNET_JITO_MEV_ENABLED"
  send_validator_metrics "$TESTNET_VOTE_ACCOUNT" "$TESTNET_IDENTITY_KEY" "$TESTNET_RPC_API" "$TESTNET_HOST" "$TESTNET_STAKEWIZ_ENABLED" "$TESTNET_GOSSIP_ENABLED" "$TESTNET_JITO_MEV_ENABLED"
  send_validator_metrics "$DEBUG_VOTE_ACCOUNT" "$DEBUG_IDENTITY_KEY" "$DEBUG_RPC_API" "$DEBUG_HOST" "$DEBUG_STAKEWIZ_ENABLED" "$DEBUG_GOSSIP_ENABLED" "$DEBUG_JITO_MEV_ENABLED"

  echo "✅ Validator metrics collection completed"
  echo
}

# ===== FUNCTION TO COLLECT BLOCK METRICS FOR ALL NETWORKS =====
collect_all_block_metrics() {
  echo "=========================================="
  echo "      COLLECTING BLOCK METRICS"
  echo "=========================================="

  # Get the current epoch from Mainnet RPC (used for summary queries)
  CURRENT_EPOCH=$(curl -s "$MAINNET_RPC_API" -X POST -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"getEpochInfo"}' | jq -r '.result.epoch')
  echo "📊 Current epoch: $CURRENT_EPOCH"
  echo

  # Process clusters
  declare -A STATS

  if $PROCESS_MAINNET; then
    echo "🔄 Processing Mainnet blocks"
    readarray -t arr <<< "$(check_produced_blocks "$MAINNET_IDENTITY_KEY" "$MAINNET_HOST" mainnet)"
    for kv in "${arr[@]}"; do STATS["MAINNET_${kv%%=*}"]="${kv#*=}"; done
    echo
  fi

  if $PROCESS_TESTNET; then
    echo "🔄 Processing Testnet blocks"
    readarray -t arr <<< "$(check_produced_blocks "$TESTNET_IDENTITY_KEY" "$TESTNET_HOST" testnet)"
    for kv in "${arr[@]}"; do STATS["TESTNET_${kv%%=*}"]="${kv#*=}"; done
    echo
  fi

  if $PROCESS_DEBUG; then
    echo "🔄 Processing Debug blocks"
    readarray -t arr <<< "$(check_produced_blocks "$DEBUG_IDENTITY_KEY" "$DEBUG_HOST" debug)"
    for kv in "${arr[@]}"; do STATS["DEBUG_${kv%%=*}"]="${kv#*=}"; done
    echo
  fi

  # Final summary
  format_number () { [[ -z $1 || $1 = "null" ]] && echo 0 || echo "$1"; }

  TOTAL_PRODUCED=$(( $(format_number "${STATS[MAINNET_PRODUCED]:-0}") +
                      $(format_number "${STATS[TESTNET_PRODUCED]:-0}") +
                      $(format_number "${STATS[DEBUG_PRODUCED]:-0}") ))

  TOTAL_SKIPPED=$((  $(format_number "${STATS[MAINNET_SKIPPED]:-0}") +
                      $(format_number "${STATS[TESTNET_SKIPPED]:-0}") +
                      $(format_number "${STATS[DEBUG_SKIPPED]:-0}") ))

  TOTAL_CACHED=$((   $(format_number "${STATS[MAINNET_CACHED]:-0}") +
                      $(format_number "${STATS[TESTNET_CACHED]:-0}") +
                      $(format_number "${STATS[DEBUG_CACHED]:-0}") ))

  echo "=================================================="
  echo "            BLOCK METRICS SUMMARY                 "
  echo "=================================================="
  echo "✅ Produced blocks:      $TOTAL_PRODUCED"
  echo "❌ Skipped blocks:       $TOTAL_SKIPPED"
  echo "🗃️  Cached blocks:        $TOTAL_CACHED"
  echo "🔢 Slots processed:      $((TOTAL_PRODUCED + TOTAL_SKIPPED + TOTAL_CACHED))"
  echo "✅ Block metrics collection completed"
  echo
}

###############################################################################
# MAIN EXECUTION
###############################################################################

main() {
  echo "=================================================="
  echo "    SOLANA VALIDATOR METRICS COLLECTOR"
  echo "=================================================="
  echo "🚀 Starting metrics collection at $(date)"
  echo

  # Sequential execution to ensure reliability
  collect_all_validator_metrics
  collect_all_block_metrics

  echo "=================================================="
  echo "🎉 All metrics collection completed successfully!"
  echo "📅 Finished at $(date)"
  echo "=================================================="
}

# Execute main function
main "$@"
