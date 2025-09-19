#!/usr/bin/env python3
import re
import time
import subprocess
import urllib.request
import json
import os
import urllib.parse
import threading
import logging
from datetime import datetime, timedelta

# Load environment variables from centralized file
def load_environment():
    """Load environment variables from hayek-monitor.env if available"""
    env_file = "/usr/local/etc/hayek-monitor.env"
    if os.path.exists(env_file):
        print(f"🔧 Loading environment variables from {env_file}")
        # Source the environment file by reading and setting variables
        with open(env_file, 'r') as f:
            for line in f:
                line = line.strip()
                if line.startswith('export ') and '=' in line:
                    # Remove 'export ' and split on first '='
                    var_assignment = line[7:]  # Remove 'export '
                    if '=' in var_assignment:
                        key, value = var_assignment.split('=', 1)
                        # Remove quotes if present
                        value = value.strip('"\'')
                        os.environ[key] = value
    else:
        print(f"⚠️ Environment file not found at {env_file}")

# Load environment variables at startup
load_environment()

# Validate critical environment variables
def validate_environment():
    """Validate that all critical environment variables are set"""
    missing_vars = []

    # Check critical variables
    critical_vars = [
        "HAYEK_MAINNET_IDENTITY",
        "HAYEK_TESTNET_IDENTITY",
        "SOLANA_MAINNET_RPC",
        "SOLANA_TESTNET_RPC",
        "TELEGRAM_BOT_TOKEN",
        "DISCORD_WEBHOOK_MAINNET",
        "DISCORD_WEBHOOK_TESTNET",
        "TELEGRAM_CHAT_ID_MAINNET",
        "TELEGRAM_CHAT_ID_TESTNET",
        "WATCHTOWER_MIN_BALANCE_MAINNET",
        "WATCHTOWER_MIN_BALANCE_TESTNET"
    ]

    for var in critical_vars:
        if not os.environ.get(var):
            missing_vars.append(var)

    if missing_vars:
        print("❌ ERROR: Missing required environment variables:")
        for var in missing_vars:
            print(f"  - {var}")
        print("")
        print("Please ensure these variables are defined in /usr/local/etc/hayek-monitor.env")
        print("The script cannot run safely without these credentials.")
        exit(1)

    print("✅ All critical environment variables are set")

# Validate environment variables
validate_environment()

# Multi-Validator Configuration
# Uses environment variables from /usr/local/etc/hayek-monitor.env
# Balance thresholds are now configurable via WATCHTOWER_MIN_BALANCE_* variables
VALIDATOR_CONFIGS = {
    "mainnet": {
        "name": "MAINNET",
        "validator_identity": os.environ.get("HAYEK_MAINNET_IDENTITY"),
        "rpc_url": os.environ.get("SOLANA_MAINNET_RPC"),
        "service_name": "agave-watchtower-mainnet.service",
        "suggested_balance": float(os.environ.get("WATCHTOWER_MIN_BALANCE_MAINNET", "0.5")),
        "solana_cli_args": ["-u", "mainnet-beta"],
        "discord_webhook": os.environ.get("DISCORD_WEBHOOK_MAINNET"),
        "telegram_chat_id": os.environ.get("TELEGRAM_CHAT_ID_MAINNET"),
        "alert_intervals": {
            "delinquent": 180,
            "balance": 300
        },
        "enabled": False,
        # Individual alert type controls for this validator
        "alerts": {
            "delinquent": True,      # Enable/disable delinquent alerts
            "recovery": True,        # Enable/disable recovery alerts
            "low_balance": True,     # Enable/disable low balance alerts
            "balance_recovery": True # Enable/disable balance recovery alerts
        }
    },
    "mainnet-debug": {
        "name": "MAINNET-DEBUG",
        "validator_identity": os.environ.get("HAYEK_DEBUG_IDENTITY"),  # Debug validator (specific identity)
        "rpc_url": os.environ.get("SOLANA_MAINNET_RPC"),
        "service_name": "agave-watchtower-debug.service",
        "suggested_balance": float(os.environ.get("WATCHTOWER_MIN_BALANCE_MAINNET", "0.1")),
        "solana_cli_args": ["-u", "mainnet-beta"],
        "discord_webhook": os.environ.get("DISCORD_WEBHOOK_MAINNET"),
        "telegram_chat_id": os.environ.get("TELEGRAM_CHAT_ID_MAINNET"),
        "alert_intervals": {
            "delinquent": 180,
            "balance": 300
        },
        "enabled": False,
        # Individual alert type controls for this validator
        "alerts": {
            "delinquent": True,      # Enable/disable delinquent alerts
            "recovery": True,        # Enable/disable recovery alerts
            "low_balance": True,     # Enable/disable low balance alerts
            "balance_recovery": True # Enable/disable balance recovery alerts
        }
    },
    "testnet": {
        "name": "TESTNET",
        "validator_identity": os.environ.get("HAYEK_TESTNET_IDENTITY"),
        "rpc_url": os.environ.get("SOLANA_TESTNET_RPC"),
        "service_name": "agave-watchtower-testnet.service",
        "suggested_balance": float(os.environ.get("WATCHTOWER_MIN_BALANCE_TESTNET", "1.0")),
        "solana_cli_args": ["-ut"],
        "discord_webhook": os.environ.get("DISCORD_WEBHOOK_TESTNET"),
        "telegram_chat_id": os.environ.get("TELEGRAM_CHAT_ID_TESTNET"),
        "alert_intervals": {
            "delinquent": 180,
            "balance": 300
        },
        "enabled": True,
        # Individual alert type controls for this validator
        "alerts": {
            "delinquent": True,     # Disable delinquent alerts for testnet
            "recovery": True,       # Disable recovery alerts for testnet
            "low_balance": True,    # Disable low balance alerts for testnet
            "balance_recovery": True # Disable balance recovery alerts for testnet
        }
    },
    "testing": {
        "name": "TESTING",
        "validator_identity": os.environ.get("HAYEK_TESTNET_IDENTITY"),  # Uses same testnet identity
        "rpc_url": os.environ.get("SOLANA_TESTNET_RPC"),
        "service_name": "agave-watchtower-testing.service",
        "suggested_balance": float(os.environ.get("WATCHTOWER_MIN_BALANCE_TESTNET", "100.952")),
        "solana_cli_args": ["-ut"],
        "discord_webhook": os.environ.get("DISCORD_WEBHOOK_GENERAL"),
        "telegram_chat_id": "",
        "alert_intervals": {
            "delinquent": 180,
            "balance": 60
        },
        "enabled": False,
        # Individual alert type controls for this validator
        "alerts": {
            "delinquent": True,      # Enable/disable delinquent alerts
            "recovery": True,        # Enable/disable recovery alerts
            "low_balance": True,     # Enable/disable low balance alerts
            "balance_recovery": True # Enable/disable balance recovery alerts
        }
    }
}

# Global Settings
ENABLE_DISCORD = True
ENABLE_TELEGRAM = True
SHOW_FULL_VALIDATOR_ID = True
TELEGRAM_BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN")
SOLANA_BIN = os.environ.get("SOLANA_BIN")

# Separate state tracking for each validator
validator_states = {
    "mainnet": {},
    "mainnet-debug": {},
    "testnet": {},
    "testing": {}
}

account_balance_states = {
    "mainnet": {},
    "mainnet-debug": {},
    "testnet": {},
    "testing": {}
}

# Enable/Disable specific alert types
ENABLE_DELINQUENT_ALERTS = True
ENABLE_RECOVERY_ALERTS = True
ENABLE_LOW_BALANCE_ALERTS = True
ENABLE_BALANCE_RECOVERY_ALERTS = True

def setup_logging_for_validator(validator_name):
    """
    Setup logging for a specific validator
    """
    logger = logging.getLogger(f"solana_alerts_{validator_name}")
    logger.setLevel(logging.INFO)

    # Clear existing handlers
    for handler in logger.handlers[:]:
        logger.removeHandler(handler)

    # File handler
    file_handler = logging.FileHandler(f"/var/log/solana-alerts-{validator_name}.log")
    file_handler.setLevel(logging.INFO)

    # Console handler
    console_handler = logging.StreamHandler()
    console_handler.setLevel(logging.INFO)

    # Formatter
    formatter = logging.Formatter(
        f'%(asctime)s - {validator_name.upper()} - %(levelname)s - %(message)s'
    )

    file_handler.setFormatter(formatter)
    console_handler.setFormatter(formatter)

    logger.addHandler(file_handler)
    logger.addHandler(console_handler)

    return logger

def get_current_balance_for_validator(validator_name, config, account_id):
    """
    Get current balance for a specific validator using Solana CLI
    """
    try:
        cli_args = config["solana_cli_args"]
        cmd = [SOLANA_BIN] + cli_args + ["balance", account_id]
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)

        if result.returncode == 0:
            output = result.stdout.strip()
            balance_match = re.search(r'([\d.]+)\s+SOL', output)
            if balance_match:
                balance = float(balance_match.group(1))
                logger = setup_logging_for_validator(validator_name)
                logger.info(f"Retrieved balance for {account_id}: {balance} SOL")
                return balance
            else:
                logger = setup_logging_for_validator(validator_name)
                logger.error(f"Could not parse balance from output: {output}")
                return None
        else:
            logger = setup_logging_for_validator(validator_name)
            logger.error(f"Error getting balance for {account_id}: {result.stderr}")
            return None
    except subprocess.TimeoutExpired:
        logger = setup_logging_for_validator(validator_name)
        logger.error(f"Timeout getting balance for {account_id}")
        return None
    except Exception as e:
        logger = setup_logging_for_validator(validator_name)
        logger.error(f"Exception getting balance for {account_id}: {e}")
        return None

def format_validator_id(validator_id):
    """
    Format validator ID according to preference
    """
    if SHOW_FULL_VALIDATOR_ID:
        return validator_id
    else:
        return f"{validator_id[:10]}...{validator_id[-4:]}"

def format_duration(since_time):
    """
    Format duration from start time to now
    """
    if since_time:
        duration = datetime.now() - since_time
        hours, remainder = divmod(duration.total_seconds(), 3600)
        minutes, seconds = divmod(remainder, 60)
        return f"{int(hours)}h {int(minutes)}m {int(seconds)}s"
    else:
        return "just detected"

def format_balance_message(validator_name, config, account_id=None, balance=None, platform="discord"):
    """
    Format balance message for a specific validator
    """
    if not account_id or balance is None:
        return None

    NETWORK_NAME = config["name"]
    SUGGESTED_BALANCE = config["suggested_balance"]

    formatted_balance = f"{balance:.2f}"
    formatted_account = format_validator_id(account_id)

    # Get time in low balance state
    account_state = account_balance_states[validator_name]
    if account_id in account_state:
        time_in_state = format_duration(account_state[account_id]["first_alert_time"])
    else:
        time_in_state = "just detected"

    if platform == "discord":
        formatted_message = (
            f"**{NETWORK_NAME} IDENTITY LOW BALANCE**\n"
            f"**Account:** {formatted_account}\n"
            f"**Balance:** ◎{formatted_balance} SOL\n"
            f"**Suggested:** ◎{SUGGESTED_BALANCE} SOL\n"
            f"**Time in this state:** {time_in_state}"
        )
    elif platform == "telegram":
        formatted_message = (
            f"*{NETWORK_NAME} IDENTITY LOW BALANCE*\n"
            f"*Account*: `{formatted_account}`\n"
            f"*Balance:* ◎{formatted_balance} SOL\n"
            f"*Suggested:* ◎{SUGGESTED_BALANCE} SOL\n"
            f"*Time in this state:* {time_in_state}"
        )
    else:
        formatted_message = (
            f"{NETWORK_NAME} IDENTITY LOW BALANCE\n"
            f"Account: {formatted_account}\n"
            f"Balance: ◎{formatted_balance} SOL\n"
            f"Suggested: ◎{SUGGESTED_BALANCE} SOL\n"
            f"Time in this state: {time_in_state}"
        )

    return formatted_message

def format_balance_recovery_message(validator_name, config, account_id=None, balance=None, platform="discord"):
    """
    Format balance recovery message for a specific validator
    """
    if not account_id:
        return None

    NETWORK_NAME = config["name"]
    SUGGESTED_BALANCE = config["suggested_balance"]

    formatted_account = format_validator_id(account_id)
    formatted_balance = f"{balance:.2f}" if balance is not None else f"{SUGGESTED_BALANCE:.2f}"

    # Calculate time in low balance state
    account_state = account_balance_states[validator_name]
    time_str = "unknown time"
    if account_id in account_state and account_state[account_id].get("first_alert_time") is not None:
        time_in_low_balance = datetime.now() - account_state[account_id]["first_alert_time"]
        hours, remainder = divmod(time_in_low_balance.total_seconds(), 3600)
        minutes, seconds = divmod(remainder, 60)
        time_str = f"{int(hours)}h {int(minutes)}m {int(seconds)}s"

    if platform == "discord":
        formatted_message = (
            f"**✅ BALANCE RECOVERED: {NETWORK_NAME} IDENTITY BALANCE NORMAL ✅**\n"
            f"**Account:** {formatted_account}\n"
            f"**Current Balance:** ◎{formatted_balance} SOL\n"
            f"**Suggested:** ◎{SUGGESTED_BALANCE} SOL\n"
            f"**Time in low balance state:** {time_str}"
        )
    elif platform == "telegram":
        formatted_message = (
            f"*✅ BALANCE RECOVERED: {NETWORK_NAME} IDENTITY BALANCE NORMAL ✅*\n"
            f"*Account*: `{formatted_account}`\n"
            f"*Current Balance:* ◎{formatted_balance} SOL\n"
            f"*Suggested:* ◎{SUGGESTED_BALANCE} SOL\n"
            f"*Time in low balance state:* {time_str}"
        )
    else:
        formatted_message = (
            f"✅ BALANCE RECOVERED: {NETWORK_NAME} IDENTITY BALANCE NORMAL ✅\n"
            f"Account: {formatted_account}\n"
            f"Current Balance: ◎{formatted_balance} SOL\n"
            f"Suggested: ◎{SUGGESTED_BALANCE} SOL\n"
            f"Time in low balance state: {time_str}"
        )

    return formatted_message

def format_delinquent_message(validator_name, config, validator_id, platform="discord"):
    """
    Format delinquent validator message for a specific validator
    """
    NETWORK_NAME = config["name"]
    validator_state = validator_states[validator_name]

    if validator_id not in validator_state:
        validator_state[validator_id] = {
            "is_delinquent": True,
            "delinquent_since": datetime.now(),
            "last_alert_time": datetime.now()
        }

    formatted_validator_id = format_validator_id(validator_id)
    time_str = format_duration(validator_state[validator_id]["delinquent_since"])

    if platform == "discord":
        formatted_message = (
            f"**⚠️ ALERT: {NETWORK_NAME} VALIDATOR DELINQUENT ⚠️**\n"
            f"**Validator:** {formatted_validator_id}\n"
            f"**Time in this state:** {time_str}\n"
            f"**Network:** {NETWORK_NAME}"
        )
    elif platform == "telegram":
        formatted_message = (
            f"*⚠️ ALERT: {NETWORK_NAME} VALIDATOR DELINQUENT ⚠️*\n"
            f"*Validator*: `{formatted_validator_id}`\n"
            f"*Time in this state*: {time_str}\n"
            f"*Network*: {NETWORK_NAME}"
        )
    else:
        formatted_message = (
            f"⚠️ ALERT: {NETWORK_NAME} VALIDATOR DELINQUENT ⚠️\n"
            f"Validator: {formatted_validator_id}\n"
            f"Time in this state: {time_str}\n"
            f"Network: {NETWORK_NAME}"
        )

    return formatted_message

def format_recovery_message(validator_name, config, validator_id, platform="discord"):
    """
    Format validator recovery message for a specific validator
    """
    NETWORK_NAME = config["name"]
    validator_state = validator_states[validator_name]

    formatted_validator_id = format_validator_id(validator_id)

    time_str = "unknown time"
    if validator_id in validator_state and validator_state[validator_id].get("delinquent_since"):
        time_str = format_duration(validator_state[validator_id]["delinquent_since"])

    if platform == "discord":
        formatted_message = (
            f"**✅ RECOVERED: {NETWORK_NAME} VALIDATOR ACTIVE AGAIN ✅**\n"
            f"**Validator:** {formatted_validator_id}\n"
            f"**Time in delinquent state:** {time_str}\n"
            f"**Network:** {NETWORK_NAME}"
        )
    elif platform == "telegram":
        formatted_message = (
            f"*✅ RECOVERED: {NETWORK_NAME} VALIDATOR ACTIVE AGAIN ✅*\n"
            f"*Validator*: `{formatted_validator_id}`\n"
            f"*Time in delinquent state*: {time_str}\n"
            f"*Network*: {NETWORK_NAME}"
        )
    else:
        formatted_message = (
            f"✅ RECOVERED: {NETWORK_NAME} VALIDATOR ACTIVE AGAIN ✅\n"
            f"Validator: {formatted_validator_id}\n"
            f"Time in delinquent state: {time_str}\n"
            f"Network: {NETWORK_NAME}"
        )

    return formatted_message

def send_to_discord_custom(webhook_url, message):
    """
    Send message to Discord with specific webhook
    """
    if not ENABLE_DISCORD or not webhook_url:
        return

    payload = json.dumps({
        "content": message,
        "username": "Solana Multi-Validator Alerts",
        "avatar_url": "https://solana.com/src/img/branding/solanaLogoMark.svg"
    }).encode('utf-8')

    headers = {
        'Content-Type': 'application/json',
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
    }

    req = urllib.request.Request(webhook_url, data=payload, headers=headers, method='POST')

    try:
        with urllib.request.urlopen(req) as response:
            if response.status == 204:
                print("Discord message sent successfully")
            else:
                print(f"Failed to send Discord message: {response.status}")
    except Exception as e:
        print(f"Error sending Discord message: {e}")

def send_to_telegram_custom(bot_token, chat_id, message):
    """
    Send message to Telegram with specific chat ID
    """
    if not ENABLE_TELEGRAM or not bot_token or not chat_id:
        return

    encoded_message = urllib.parse.quote(message)
    telegram_url = f"https://api.telegram.org/bot{bot_token}/sendMessage?chat_id={chat_id}&text={encoded_message}&parse_mode=Markdown"

    headers = {
        'Content-Type': 'application/json',
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
    }

    req = urllib.request.Request(telegram_url, headers=headers, method='GET')

    try:
        with urllib.request.urlopen(req) as response:
            response_data = json.loads(response.read().decode('utf-8'))
            if response_data.get('ok'):
                print("Telegram message sent successfully")
            else:
                print(f"Failed to send Telegram message: {response_data}")
    except Exception as e:
        print(f"Error sending Telegram message: {e}")

def send_alert_for_validator(validator_name, config, alert_type, format_function, **kwargs):
    """
    Send alert for a specific validator
    """
    DISCORD_WEBHOOK = config["discord_webhook"]
    TELEGRAM_CHAT_ID = config["telegram_chat_id"]

    # Send to Discord
    if ENABLE_DISCORD and DISCORD_WEBHOOK:
        discord_message = format_function(platform="discord", **kwargs)
        if discord_message:
            logger = setup_logging_for_validator(validator_name)
            logger.info(f"Sending Discord alert: {alert_type}")
            send_to_discord_custom(DISCORD_WEBHOOK, discord_message)

    # Send to Telegram
    if ENABLE_TELEGRAM and TELEGRAM_CHAT_ID:
        telegram_message = format_function(platform="telegram", **kwargs)
        if telegram_message:
            logger = setup_logging_for_validator(validator_name)
            logger.info(f"Sending Telegram alert: {alert_type}")
            send_to_telegram_custom(TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, telegram_message)

def should_send_delinquent_alert(validator_name, validator_id):
    """
    Check if should send delinquent alert based on time interval
    """
    validator_state = validator_states[validator_name]
    config = VALIDATOR_CONFIGS[validator_name]
    interval = config["alert_intervals"]["delinquent"]

    if validator_id not in validator_state or "last_alert_time" not in validator_state[validator_id]:
        return True

    time_since_last_alert = datetime.now() - validator_state[validator_id]["last_alert_time"]
    return time_since_last_alert.total_seconds() >= interval

def should_send_low_balance_alert(validator_name, account_id):
    """
    Check if should send low balance alert based on time interval
    """
    account_state = account_balance_states[validator_name]
    config = VALIDATOR_CONFIGS[validator_name]
    interval = config["alert_intervals"]["balance"]

    if account_id not in account_state or "last_alert_time" not in account_state[account_id]:
        return True

    time_since_last_alert = datetime.now() - account_state[account_id]["last_alert_time"]
    return time_since_last_alert.total_seconds() >= interval

def extract_balance_info(line):
    """
    Extract account ID and balance from log line
    """
    match = re.search(r'balance sanity failure: (\w+) has ◎([\d.]+)', line)
    if not match:
        match = re.search(r'balance: (\w+) has ◎([\d.]+)', line)
        if not match:
            return None, None

    account_id = match.group(1)
    balance = float(match.group(2))
    return account_id, balance

def check_balance_recovery_for_validator(validator_name, config, account_state):
    """
    Check balance recovery for a specific validator
    """
    logger = setup_logging_for_validator(validator_name)
    logger.info("Detected 'watchtower-sanity ok=true' - checking for accounts to mark as recovered")

    # Check if balance recovery alerts are enabled for this validator
    if not config["alerts"]["balance_recovery"]:
        logger.info("Balance recovery alerts disabled for this validator")
        return

    for account_id, state in list(account_state.items()):
        if state.get("first_alert_time") is None:
            continue

        current_balance = get_current_balance_for_validator(validator_name, config, account_id)
        balance_to_use = current_balance if current_balance is not None else config["suggested_balance"]

        logger.info(f"Balance recovery inferred for {account_id} with balance {balance_to_use}")
        send_alert_for_validator(
            validator_name, config, "balance_recovery",
            lambda **kwargs: format_balance_recovery_message(validator_name, config, **kwargs),
            account_id=account_id, balance=balance_to_use
        )

        state["first_alert_time"] = None
        logger.info(f"Account {account_id} marked as recovered")

def check_validator_recovery_for_validator(validator_name, config, validator_state):
    """
    Check validator recovery for a specific validator
    """
    logger = setup_logging_for_validator(validator_name)
    logger.info("Detected recovery signal - checking for validator recovery")

    # Check if recovery alerts are enabled for this validator
    if not config["alerts"]["recovery"]:
        logger.info("Recovery alerts disabled for this validator")
        return

    for validator_id, state in list(validator_state.items()):
        if state.get("is_delinquent", False):
            logger.info(f"Validator {validator_id} recovery detected!")
            state["is_delinquent"] = False

            send_alert_for_validator(
                validator_name, config, "recovery",
                lambda **kwargs: format_recovery_message(validator_name, config, **kwargs),
                validator_id=validator_id
            )

def check_periodic_alerts_for_validator(validator_name, config, validator_state, account_state):
    """
    Check periodic alerts for a specific validator
    """
    current_time = datetime.now()
    SUGGESTED_BALANCE = config["suggested_balance"]

    # Check balance recovery during periodic check
    for account_id, state in list(account_state.items()):
        if state.get("first_alert_time") is None:
            continue

        last_known_balance = state.get("last_known_balance", 0.0)

        if (config["alerts"]["balance_recovery"] and
            last_known_balance >= SUGGESTED_BALANCE):
            logger = setup_logging_for_validator(validator_name)
            logger.info(f"Balance recovery detected during periodic check for {account_id}")
            send_alert_for_validator(
                validator_name, config, "balance_recovery",
                lambda **kwargs: format_balance_recovery_message(validator_name, config, **kwargs),
                account_id=account_id, balance=last_known_balance
            )
            state["first_alert_time"] = None
            continue

        # Check if should send periodic low balance alert
        if config["alerts"]["low_balance"]:
            time_since_last_alert = current_time - state["last_alert_time"]
            interval = config["alert_intervals"]["balance"]
            if time_since_last_alert.total_seconds() >= interval:
                state["last_alert_time"] = current_time
                logger = setup_logging_for_validator(validator_name)
                logger.info(f"Sending periodic low balance alert for {account_id}")
                send_alert_for_validator(
                    validator_name, config, "balance",
                    lambda **kwargs: format_balance_message(validator_name, config, **kwargs),
                    account_id=account_id, balance=last_known_balance
                )

def process_log_line_for_validator(line, validator_name, config, validator_state, account_state):
    """
    Process a log line for a specific validator
    """
    NETWORK_NAME = config["name"]
    SUGGESTED_BALANCE = config["suggested_balance"]
    logger = setup_logging_for_validator(validator_name)

    # Check for balance recovery indicators
    if "datapoint: watchtower-sanity ok=true" in line:
        check_balance_recovery_for_validator(validator_name, config, account_state)

    # Check for validator recovery indicators
    if "All clear after" in line or "datapoint: watchtower-sanity ok=true" in line:
        check_validator_recovery_for_validator(validator_name, config, validator_state)

    # Extract balance info from log lines
    if "balance sanity failure:" in line or "Error: balance:" in line:
        account_id, balance = extract_balance_info(line)
        if account_id and balance is not None:
            # Update balance tracking
            if account_id in account_state:
                previous_balance = account_state[account_id].get("last_known_balance", 0.0)
                was_below_threshold = previous_balance < SUGGESTED_BALANCE
                is_above_threshold = balance >= SUGGESTED_BALANCE

                account_state[account_id]["last_known_balance"] = balance
                logger.info(f"Updated balance for {account_id}: {balance}")

                # Check for balance recovery
                if (ENABLE_BALANCE_RECOVERY_ALERTS and was_below_threshold and
                    is_above_threshold and account_state[account_id].get("first_alert_time") is not None):
                    logger.info(f"Balance recovery detected for {account_id}: {balance} >= {SUGGESTED_BALANCE}")
                    send_alert_for_validator(
                        validator_name, config, "balance_recovery",
                        lambda **kwargs: format_balance_recovery_message(validator_name, config, **kwargs),
                        account_id=account_id, balance=balance
                    )
                    account_state[account_id]["first_alert_time"] = None

                # Reset if balance drops below threshold again
                elif not was_below_threshold and balance < SUGGESTED_BALANCE:
                    account_state[account_id]["first_alert_time"] = datetime.now()
                    logger.info(f"Account {account_id} balance dropped below threshold again")
            else:
                # Initialize new account
                is_below_threshold = balance < SUGGESTED_BALANCE
                account_state[account_id] = {
                    "first_alert_time": datetime.now() if is_below_threshold else None,
                    "last_alert_time": datetime.now(),
                    "last_known_balance": balance
                }
                if is_below_threshold:
                    logger.info(f"New account {account_id} detected with low balance {balance}")
                else:
                    logger.info(f"New account {account_id} detected with normal balance {balance}")

    # Check for delinquent messages
    if config["alerts"]["delinquent"]:
        delinquent_match = re.search(r'delinquent sanity failure: (\w+) delinquent', line)
        if delinquent_match:
            validator_id = delinquent_match.group(1)

            if validator_id not in validator_state or not validator_state[validator_id].get("is_delinquent", False):
                if validator_id not in validator_state:
                    validator_state[validator_id] = {}

                validator_state[validator_id]["is_delinquent"] = True
                validator_state[validator_id]["delinquent_since"] = datetime.now()
                validator_state[validator_id]["last_alert_time"] = datetime.now()

                logger.info(f"Validator {validator_id} DELINQUENT state detected!")
                send_alert_for_validator(
                    validator_name, config, "delinquent",
                    lambda **kwargs: format_delinquent_message(validator_name, config, **kwargs),
                    validator_id=validator_id
                )

            elif should_send_delinquent_alert(validator_name, validator_id):
                validator_state[validator_id]["last_alert_time"] = datetime.now()
                logger.info(f"Sending periodic DELINQUENT alert for {validator_id}")
                send_alert_for_validator(
                    validator_name, config, "delinquent",
                    lambda **kwargs: format_delinquent_message(validator_name, config, **kwargs),
                    validator_id=validator_id
                )

    # Check for recovery messages
    if config["alerts"]["recovery"]:
        recovery_match = re.search(r'validator (\w+) is now active', line)
        if recovery_match:
            validator_id = recovery_match.group(1)

            if validator_id in validator_state and validator_state[validator_id].get("is_delinquent", False):
                validator_state[validator_id]["is_delinquent"] = False
                logger.info(f"Validator {validator_id} RECOVERY detected!")
                send_alert_for_validator(
                    validator_name, config, "recovery",
                    lambda **kwargs: format_recovery_message(validator_name, config, **kwargs),
                    validator_id=validator_id
                )

    # Check for balance alert messages
    if config["alerts"]["low_balance"] and ("balance sanity failure:" in line or "Error: balance:" in line):
        account_id, balance = extract_balance_info(line)

        if account_id and balance is not None and balance < SUGGESTED_BALANCE:
            if should_send_low_balance_alert(validator_name, account_id):
                if account_id not in account_state:
                    account_state[account_id] = {
                        "first_alert_time": datetime.now(),
                        "last_alert_time": datetime.now(),
                        "last_known_balance": balance
                    }
                else:
                    if account_state[account_id].get("first_alert_time") is None:
                        account_state[account_id]["first_alert_time"] = datetime.now()
                    account_state[account_id]["last_alert_time"] = datetime.now()

                logger.info(f"Low balance alert detected for account {account_id} with balance {balance}")
                send_alert_for_validator(
                    validator_name, config, "balance",
                    lambda **kwargs: format_balance_message(validator_name, config, **kwargs),
                    account_id=account_id, balance=balance
                )

def monitor_single_validator(validator_name, config):
    """
    Monitor a single validator
    """
    NETWORK_NAME = config["name"]
    VALIDATOR_IDENTITY = config["validator_identity"]
    LOG_CMD = ["journalctl", "-u", config["service_name"], "-f", "-n", "0"]

    logger = setup_logging_for_validator(validator_name)
    logger.info(f"Starting monitoring for {validator_name} validator: {VALIDATOR_IDENTITY}")
    logger.info(f"Network: {NETWORK_NAME}, Service: {config['service_name']}")
    logger.info(f"Suggested balance: {config['suggested_balance']} SOL")

    # Get validator-specific state
    validator_state = validator_states[validator_name]
    account_state = account_balance_states[validator_name]

    # Track last check time for periodic alerts
    last_periodic_check = datetime.now()

    # Start the log process
    process = subprocess.Popen(LOG_CMD, stdout=subprocess.PIPE, text=True)

    try:
        for line in process.stdout:
            line = line.strip()
            logger.debug(f"Log: {line}")

            # Process log line for this validator
            process_log_line_for_validator(line, validator_name, config, validator_state, account_state)

            # Periodic checks
            current_time = datetime.now()
            if (current_time - last_periodic_check).total_seconds() >= 10:
                check_periodic_alerts_for_validator(validator_name, config, validator_state, account_state)
                last_periodic_check = current_time

    except KeyboardInterrupt:
        logger.info(f"Stopping {validator_name} monitor...")
    except Exception as e:
        logger.error(f"Error in {validator_name} monitor: {e}")
        raise
    finally:
        process.terminate()
        process.wait()

def print_validator_status():
    """
    Print status of all validators
    """
    print("\n=== Validator Status ===")

    for validator_name, config in VALIDATOR_CONFIGS.items():
        if not config.get("enabled", True):
            continue

        validator_state = validator_states[validator_name]
        account_state = account_balance_states[validator_name]

        delinquent_count = len([v for v in validator_state.values() if v.get('is_delinquent')])
        low_balance_count = len([a for a in account_state.values() if a.get('first_alert_time') is not None])

        print(f"\n{validator_name.upper()}:")
        print(f"  Network: {config['name']}")
        print(f"  Validator ID: {config['validator_identity']}")
        print(f"  Suggested Balance: {config['suggested_balance']} SOL")
        print(f"  Delinquent Validators: {delinquent_count}")
        print(f"  Low Balance Accounts: {low_balance_count}")

        # Show alert settings
        print(f"  Alert Settings:")
        for alert_type, enabled in config["alerts"].items():
            status = "✅ ENABLED" if enabled else "❌ DISABLED"
            print(f"    - {alert_type}: {status}")

def print_alert_configuration():
    """
    Print detailed alert configuration for all validators
    """
    print("\n=== Alert Configuration ===")

    for validator_name, config in VALIDATOR_CONFIGS.items():
        if not config.get("enabled", True):
            continue

        print(f"\n{validator_name.upper()} ({config['name']}):")
        print(f"  Validator ID: {config['validator_identity']}")
        print(f"  Service: {config['service_name']}")
        print(f"  Suggested Balance: {config['suggested_balance']} SOL")

        print(f"  Alert Types:")
        for alert_type, enabled in config["alerts"].items():
            status = "✅ ENABLED" if enabled else "❌ DISABLED"
            print(f"    - {alert_type.replace('_', ' ').title()}: {status}")

        print(f"  Alert Intervals:")
        for interval_type, seconds in config["alert_intervals"].items():
            print(f"    - {interval_type}: {seconds} seconds")

        print(f"  Notification Channels:")
        if config["discord_webhook"]:
            print(f"    - Discord: ✅ CONFIGURED")
        else:
            print(f"    - Discord: ❌ NOT CONFIGURED")

        if config["telegram_chat_id"]:
            print(f"    - Telegram: ✅ CONFIGURED")
        else:
            print(f"    - Telegram: ❌ NOT CONFIGURED")

def monitor_all_validators():
    """
    Monitor all validators simultaneously
    """
    print("Starting Solana Multi-Validator Alert System")
    print(f"Monitoring {len(VALIDATOR_CONFIGS)} validators:")

    for validator_name, config in VALIDATOR_CONFIGS.items():
        if config.get("enabled", True):
            enabled_alerts = [alert for alert, enabled in config["alerts"].items() if enabled]
            disabled_alerts = [alert for alert, enabled in config["alerts"].items() if not enabled]

            print(f"  - {validator_name}: {config['validator_identity']} ({config['name']})")
            if enabled_alerts:
                print(f"    ✅ Enabled alerts: {', '.join(enabled_alerts)}")
            if disabled_alerts:
                print(f"    ❌ Disabled alerts: {', '.join(disabled_alerts)}")

    # Start monitoring threads for each validator
    threads = []

    for validator_name, config in VALIDATOR_CONFIGS.items():
        if not config.get("enabled", True):
            continue

        thread = threading.Thread(
            target=monitor_single_validator,
            args=(validator_name, config),
            name=f"monitor-{validator_name}",
            daemon=True
        )
        thread.start()
        threads.append(thread)
        print(f"Started monitoring thread for {validator_name}")

    # Wait for all threads (they should run indefinitely)
    for thread in threads:
        thread.join()

if __name__ == "__main__":
    # Main loop with retry on error for continuous operation
    print("Solana Multi-Validator Alert Formatter")
    print(f"Discord enabled: {ENABLE_DISCORD}, Telegram enabled: {ENABLE_TELEGRAM}")
    print(f"Solana CLI path: {SOLANA_BIN}")

    # Show alert configuration at startup
    print_alert_configuration()

    while True:
        try:
            monitor_all_validators()
        except Exception as e:
            print(f"Error in multi-validator monitor: {e}")
            print("Restarting in 10 seconds...")
            time.sleep(10)
