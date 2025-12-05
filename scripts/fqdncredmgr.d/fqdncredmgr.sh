#!/bin/bash

# this command manages FQDN credentials for domain name providers
# it does not set any dns, and does not purchase domains

# List of acceptable providers (populated dynamically from ./providers)
# `VALID_PROVIDERS` will be populated after `DIR` is known
VALID_PROVIDERS=()

# Database path
DB_PATH="/etc/fqdntools/creds.db"
DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fqdncredmgr.d"
# Files bundled with this command live in the same directory as the
# script (eg `.../fqdncredmgr.d`). The `getinput` helper is provided
# as a sibling `.d` directory under the parent directory (eg
# `/usr/local/bin/getinput.d/getinput.sh`), so compute `BASE_DIR` as
# the parent of `DIR`.
USAGE_FILE="$DIR/usage.txt"
SCHEMA_FILE="$DIR/schema.sql"
BASE_DIR="$(dirname "$DIR")"

# Helper script for interactive input (sibling under the parent dir)
GETINPUT_SCRIPT="$BASE_DIR/getinput.d/getinput.sh"

# Populate VALID_PROVIDERS by inspecting the bundled providers directory
PROVIDERS_DIR="/etc/fqdnmgr/providers"
if [ -d "$PROVIDERS_DIR" ]; then
    for f in "$PROVIDERS_DIR"/*.provider; do
        [ -e "$f" ] || continue
        fbase="$(basename "$f")"
        provider_name="${fbase%.provider}"
        VALID_PROVIDERS+=("$provider_name")
    done
fi

# Ensure required external files exist (no fallback)
if [ ! -f "$USAGE_FILE" ]; then
    echo "Error: Missing required file $USAGE_FILE" >&2
    exit 1
fi
if [ ! -f "$SCHEMA_FILE" ]; then
    echo "Error: Missing required file $SCHEMA_FILE" >&2
    exit 1
fi
if [ ! -f "$GETINPUT_SCRIPT" ]; then
    echo "Error: Missing required file $GETINPUT_SCRIPT" >&2
    exit 1
fi

# Source the getinput helper
source "$GETINPUT_SCRIPT"

# Function to prompt for API key interactively (dotted, no timeout, with confirmation)
prompt_api_key() {
    local api_key
    api_key=$(getInput "Enter API key" "" 0 "dotted" "true" "true" "false")
    local exit_code=$?
    if [ $exit_code -eq 200 ]; then
        echo "Error: API key cannot be empty" >&2
        exit 1
    fi
    printf "%s" "$api_key"
}

# Function to display usage
usage() {
        cat "$USAGE_FILE"
        exit 1
}

# Function to validate provider
validate_provider() {
    local provider="$1"
    for valid in "${VALID_PROVIDERS[@]}"; do
        if [ "$provider" = "$valid" ]; then
            return 0
        fi
    done
    return 1
}

# Function to initialize database
# Database initialization is handled by the installer (`setup.sh`).
# Here we only verify the DB exists; fail fast if not present.
init_db() {
    if [ ! -f "$DB_PATH" ]; then
        echo "Error: Database $DB_PATH not found. Run the installer to initialize the database." >&2
        exit 1
    fi
}

# Function to add credentials
add_creds() {
    local provider="$1"
    local username="$2"
    local api_key="$3"

    # Escape single quotes for SQL
    escape_sql() { printf '%s' "$1" | sed "s/'/''/g"; }
    local es_user=$(escape_sql "$username")
    local es_key=$(escape_sql "$api_key")
    local es_provider=$(escape_sql "$provider")

    sqlite3 "$DB_PATH" "INSERT INTO creds (username, key, provider) VALUES ('$es_user', '$es_key', '$es_provider');"
    if [ $? -eq 0 ]; then
        echo "Credentials added successfully for $username@$provider"
    else
        echo "Error: Failed to add credentials. They may already exist." >&2
        exit 1
    fi
}

# Function to update credentials
update_creds() {
    local provider="$1"
    local username="$2"
    local api_key="$3"

    escape_sql() { printf '%s' "$1" | sed "s/'/''/g"; }
    local es_user=$(escape_sql "$username")
    local es_key=$(escape_sql "$api_key")
    local es_provider=$(escape_sql "$provider")

    sqlite3 "$DB_PATH" "UPDATE creds SET key = '$es_key' WHERE provider = '$es_provider' AND username = '$es_user';"

    local changes=$(sqlite3 "$DB_PATH" "SELECT changes();")
    if [ "$changes" -gt 0 ]; then
        echo "Credentials updated successfully for $username@$provider"
    else
        echo "Error: No matching credentials found to update." >&2
        exit 1
    fi
}

# Function to delete credentials
delete_creds() {
    local provider="$1"
    local username="$2"

    escape_sql() { printf '%s' "$1" | sed "s/'/''/g"; }
    local es_user=$(escape_sql "$username")
    local es_provider=$(escape_sql "$provider")

    sqlite3 "$DB_PATH" "DELETE FROM creds WHERE provider = '$es_provider' AND username = '$es_user';"

    local changes=$(sqlite3 "$DB_PATH" "SELECT changes();")
    if [ "$changes" -gt 0 ]; then
        echo "Credentials deleted successfully for $username@$provider"
    else
        echo "Error: No matching credentials found to delete." >&2
        exit 1
    fi
}

# Main script logic
if [ $# -lt 2 ]; then
    echo "Error: Insufficient arguments" >&2
    usage
fi

ACTION="$1"
PROVIDER="$2"
USERNAME=""
API_KEY=""

# Parse remaining arguments
shift 2
while [ $# -gt 0 ]; do
    case "$1" in
        -p)
            if [ $# -lt 2 ]; then
                echo "Error: -p requires an argument" >&2
                usage
            fi
            API_KEY="$2"
            shift 2
            ;;
        *)
            if [ -z "$USERNAME" ]; then
                USERNAME="$1"
                shift
            else
                echo "Error: Unexpected argument '$1'" >&2
                usage
            fi
            ;;
    esac
done

# Validate that username is provided
if [ -z "$USERNAME" ]; then
    echo "Error: USERNAME is required" >&2
    usage
fi

# Validate action and prompt for API key if needed
case "$ACTION" in
    add|update)
        # If API key not provided via -p, prompt interactively
        if [ -z "$API_KEY" ]; then
            API_KEY=$(prompt_api_key)
        fi
        if [ -z "$API_KEY" ]; then
            echo "Error: API key is required for $ACTION" >&2
            exit 1
        fi
        ;;
    delete)
        # API key not needed for delete
        ;;
    *)
        echo "Error: Invalid action '$ACTION'" >&2
        usage
        ;;
esac

# Validate provider
if ! validate_provider "$PROVIDER"; then
    echo "Error: Invalid provider '$PROVIDER'" >&2
    echo "Valid providers: ${VALID_PROVIDERS[*]}" >&2
    exit 1
fi

# Initialize database
init_db

# Execute action
case "$ACTION" in
    add)
        add_creds "$PROVIDER" "$USERNAME" "$API_KEY"
        ;;
    update)
        update_creds "$PROVIDER" "$USERNAME" "$API_KEY"
        ;;
    delete)
        delete_creds "$PROVIDER" "$USERNAME"
        ;;
esac