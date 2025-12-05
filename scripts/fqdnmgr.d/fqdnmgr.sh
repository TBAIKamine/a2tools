#!/bin/bash
# this script is designed to provision new domains: purchasing them, setting up the acme DNS record.
# it uses registrars creds saved in sqlite db.
# TODO: more error handling.

# Get the directory where this script is located
PROVIDERS_DIR="/etc/fqdnmgr/providers"

# Logging configuration
LOG_DIR="/var/log/fqdnmgr"
LOG_FILE="${LOG_DIR}/fqdnmgr.log"

# Initialize logging directory if it doesn't exist
init_logging() {
    if [ ! -d "$LOG_DIR" ]; then
        mkdir -p "$LOG_DIR" 2>/dev/null || true
    fi
    # Ensure log file exists and is writable
    touch "$LOG_FILE" 2>/dev/null || true
}

# Log curl request sent to provider
# Usage: log_request "provider_name" "curl_request"
log_request() {
    local provider="$1"
    local request="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    {
        echo "[$timestamp] *** sent $provider"
        echo "$request"
        echo ""
    } >> "$LOG_FILE" 2>/dev/null || true
}

# Log curl response from provider
# Usage: log_response "provider_name" "response"
log_response() {
    local provider="$1"
    local response="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    {
        echo "[$timestamp] *** response from $provider"
        echo "$response"
        echo ""
    } >> "$LOG_FILE" 2>/dev/null || true
}

# Initialize logging on script load
init_logging

# Database configuration
# Both DBs are stored under /etc/fqdntools (installer creates them)
DB_PATH="/etc/fqdntools/creds.db"
DOMAINS_DB_PATH="/etc/fqdntools/domains.db"

# Helper: validate IPv4 address format
is_valid_ipv4() {
    local ip="$1"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        # Check each octet is <= 255
        local IFS='.'
        read -ra octets <<< "$ip"
        for octet in "${octets[@]}"; do
            if [ "$octet" -gt 255 ]; then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

# Helper: get WAN_IP - checks if already set and valid, otherwise fetches and caches to ~/.bashrc
get_wan_ip() {
    # Check if WAN_IP is already set and valid
    if [ -n "$WAN_IP" ] && is_valid_ipv4 "$WAN_IP"; then
        export WAN_IP
        return 0
    fi
    
    # Fetch WAN IP
    WAN_IP=$(curl -s ifconfig.me)
    
    if [ -z "$WAN_IP" ] || ! is_valid_ipv4 "$WAN_IP"; then
        echo "Error: Failed to determine a valid WAN IP" >&2
        return 1
    fi
    
    # Cache to ~/.bashrc if not already present
    local bashrc_file="$HOME/.bashrc"
    if [ -f "$bashrc_file" ]; then
        # Check if WAN_IP export already exists in .bashrc
        if ! grep -q "^export WAN_IP=" "$bashrc_file" 2>/dev/null; then
            echo "export WAN_IP=\"$WAN_IP\"" >> "$bashrc_file"
        else
            # Update existing entry if different
            local existing_ip
            existing_ip=$(grep "^export WAN_IP=" "$bashrc_file" | sed 's/export WAN_IP="\?\([^"]*\)"\?/\1/')
            if [ "$existing_ip" != "$WAN_IP" ]; then
                sed -i.bak "s|^export WAN_IP=.*|export WAN_IP=\"$WAN_IP\"|" "$bashrc_file"
            fi
        fi
    else
        echo "export WAN_IP=\"$WAN_IP\"" >> "$bashrc_file"
    fi
    
    export WAN_IP
    return 0
}

# Function to get credentials from database and export them for provider use
get_credentials() {
    local registrar="$1"
    local function_type="$2"
    
    # Check database exists
    if [ ! -f "$DB_PATH" ]; then
        echo "Error: Database file $DB_PATH not found"
        exit 1
    fi
    
    # Query for provider credentials (table: creds, columns: username, key)
    local creds=$(sqlite3 "$DB_PATH" "SELECT username, key FROM creds WHERE provider='$registrar' LIMIT 1;" 2>/dev/null)
    
    # Parse the credentials (format: username|api_key)
    PROVIDER_USERNAME=$(echo "$creds" | cut -d'|' -f1)
    PROVIDER_API_KEY=$(echo "$creds" | cut -d'|' -f2)
    
    if [ -z "$creds" ]; then
        if [ "$function_type" = "certify" ]; then
            echo "No credentials found for $registrar in database"
            echo "Would you like to add credentials now? (y/n):"
            read -r response
            if [ "$response" = "y" ] || [ "$response" = "Y" ]; then
                echo "Enter username:"
                read -r PROVIDER_USERNAME
                echo "Enter API key:"
                read -r PROVIDER_API_KEY
                sqlite3 "$DB_PATH" "INSERT INTO credentials (provider, username, api_key) VALUES ('$registrar', '$PROVIDER_USERNAME', '$PROVIDER_API_KEY');"
            else
                exit 1
            fi
        else
            echo "Error: No credentials found for $registrar in database"
            exit 1
        fi
    fi
    
    if [ -z "$PROVIDER_USERNAME" ] || [ -z "$PROVIDER_API_KEY" ]; then
        echo "USERNAME or API_KEY is empty. Please fix that first. bye"
        exit 1
    fi
    
    # Export for provider use
    export PROVIDER_USERNAME
    export PROVIDER_API_KEY
}

# Load provider plugin
load_provider() {
    local registrar="$1"
    local provider_file="$PROVIDERS_DIR/${registrar}.provider"
    
    if [ ! -f "$provider_file" ]; then
        echo "Error: Provider file not found for '$registrar'"
        echo "Expected: $provider_file"
        echo ""
        echo "Available providers:"
        for provider in "$PROVIDERS_DIR"/*.provider; do
            if [ -f "$provider" ]; then
                basename "$provider" .provider
            fi
        done
        exit 1
    fi
    
    # Source the provider file to load its functions
    source "$provider_file"
}

# Function to display usage information (reads external usage.txt only)
usage() {
    local providers_text=""
    for provider in "$PROVIDERS_DIR"/*.provider; do
        if [ -f "$provider" ]; then
            providers_text+=$(printf '  - %s\n' "$(basename "$provider" .provider)")
        fi
    done

    # Determine script directory and external usage file
    local script_dir usage_file
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/fqdnmgr.d"
    usage_file="$script_dir/usage.txt"

    if [ ! -f "$usage_file" ]; then
        echo "Error: usage file not found: $usage_file" >&2
        exit 1
    fi

    cat "$usage_file"

    # Print available providers collected earlier
    printf '%b' "$providers_text"
    exit 1
}

# Common initialization for certify and cleanup - DRY principle
init_provider_for_dns_operation() {
    local registrar="$1"
    local operation="$2"  # "certify" or "cleanup"
    
    # Check required environment variables
    if [ -z "$CERTBOT_DOMAIN" ]; then
        echo "Error: CERTBOT_DOMAIN environment variable not set" 2>/dev/null
        exit 1
    fi
    
    if [ -z "$CERTBOT_VALIDATION" ]; then
        echo "Error: CERTBOT_VALIDATION environment variable not set" 2>/dev/null
        exit 1
    fi
    
    # Load the provider
    load_provider "$registrar"
    
    # Check database
    if [ ! -f "$DB_PATH" ]; then
        echo "Error: Database file $DB_PATH not found"
        exit 1
    fi
    
    # Get credentials for provider
    get_credentials "$registrar" "$operation"
    
    # Get WAN IP (required by some providers)
    if ! get_wan_ip; then
        exit 1
    fi
}

# Main certify function - orchestrates DNS challenge setup
certify() {
    local registrar="$1"
    init_provider_for_dns_operation "$registrar" "certify"
    
    # Call provider-specific certify implementation
    provider_certify "$CERTBOT_DOMAIN" "$CERTBOT_VALIDATION" "$WAN_IP"
    
    # Check DNS propagation
    check_dns_propagation "$CERTBOT_DOMAIN" "$CERTBOT_VALIDATION"
}

# Main cleanup function - orchestrates DNS challenge removal
cleanup() {
    local registrar="$1"
    init_provider_for_dns_operation "$registrar" "cleanup"
    
    # Call provider-specific cleanup implementation
    provider_cleanup "$CERTBOT_DOMAIN" "$CERTBOT_VALIDATION" "$WAN_IP"
}

# Main purchase function - orchestrates domain purchase
purchase() {
    local fqdn="$1"
    local registrar="$2"
    
    # Load the provider
    load_provider "$registrar"
    
    # Check database
    if [ ! -f "$DB_PATH" ]; then
        echo "Error: Database file $DB_PATH not found"
        exit 1
    fi
    
    # Get credentials for provider
    get_credentials "$registrar" "purchase"
    
    # Export FQDN for provider use
    export FQDN="$fqdn"
    
    # Call provider-specific purchase implementation
    provider_purchase "$fqdn"
    local result=$?
    
    # Return status: 0=success, 1=insufficient balance, 2=other error
    exit $result
}

# Ensure domains DB exists with correct schema
ensure_domains_db() {
    # Database initialization is handled by the installer; fail fast if missing
    if [ ! -f "$DOMAINS_DB_PATH" ]; then
        echo "Error: Domains DB $DOMAINS_DB_PATH not found. Run the installer to initialize the database." >&2
        exit 1
    fi
}

# Helper to read existing status from local domains DB
get_local_domain_status() {
    local domain="$1"
    ensure_domains_db
    sqlite3 "$DOMAINS_DB_PATH" "SELECT status, registrar FROM domains WHERE domain='$domain' LIMIT 1;" 2>/dev/null
}

# Helper to upsert status into local domains DB
save_domain_status() {
    local domain="$1"; local status="$2"; local registrar="$3"
    ensure_domains_db
    sqlite3 "$DOMAINS_DB_PATH" "INSERT INTO domains (domain, status, registrar) VALUES ('$domain', '$status', CASE WHEN '$registrar' = '' THEN NULL ELSE '$registrar' END) ON CONFLICT(domain) DO UPDATE SET status=excluded.status, registrar=excluded.registrar;" 2>/dev/null
}

# Helper: check if local certificate exists for domain (very simple heuristic)
has_local_certificate() {
    local domain="$1"
    if [ -d "/etc/letsencrypt/live/$domain" ]; then
        return 0
    fi
    return 1
}

# Helper: perform whois lookup and extract registrar (very naive parsing)
whois_registrar_lookup() {
    local domain="$1"
    local cache_file="/tmp/fqdnmgr_whois_${domain}.cache"
    local now_ts
    now_ts=$(date +%s)
    if [ -f "$cache_file" ]; then
        local mtime
        # Linux uses stat -c %Y, macOS uses stat -f %m
        mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0)
        if [ $((now_ts - mtime)) -lt 3600 ]; then
            cat "$cache_file"
            return 0
        fi
    fi
    if ! command -v whois >/dev/null 2>&1; then
        return 1
    fi
    local out
    out=$(whois "$domain" 2>/dev/null || true)
    echo "$out" >"$cache_file"
    echo "$out"
}

# Helper: normalize registrar name to canonical form for database storage
# Detects known registrars via regex and returns normalized name
normalize_registrar() {
    local raw="$1"
    local lower
    lower=$(echo "$raw" | tr '[:upper:]' '[:lower:]')
    
    # Match known registrars using regex patterns
    # Return canonical names matching provider files (with .com where applicable)
    if [[ "$lower" =~ namecheap ]]; then
        echo "namecheap.com"
    elif [[ "$lower" =~ godaddy ]]; then
        echo "godaddy"
    elif [[ "$lower" =~ cloudflare ]]; then
        echo "cloudflare"
    elif [[ "$lower" =~ google ]]; then
        echo "google"
    elif [[ "$lower" =~ aws|amazon|route.?53 ]]; then
        echo "aws"
    elif [[ "$lower" =~ gandi ]]; then
        echo "gandi"
    elif [[ "$lower" =~ hover ]]; then
        echo "hover"
    elif [[ "$lower" =~ dynadot ]]; then
        echo "dynadot"
    elif [[ "$lower" =~ porkbun ]]; then
        echo "porkbun"
    elif [[ "$lower" =~ name\.com|name,?.inc ]]; then
        echo "name.com"
    elif [[ "$lower" =~ ionos|1and1|1\&1 ]]; then
        echo "ionos"
    elif [[ "$lower" =~ ovh ]]; then
        echo "ovh"
    elif [ -n "$raw" ]; then
        # Unknown registrar - keep original lowercased and trimmed
        echo "$lower" | sed 's/[^a-z0-9.-]//g'
    else
        echo ""
    fi
}

# Main setInitRecords function - sets initial DNS records for a domain
# Sets: A @ -> WAN_IP, A * -> WAN_IP, MX @ -> mail.$FQDN (priority 10)
# All with 60s TTL. This REPLACES all existing DNS records.
# If -sync flag is passed, waits for DNS propagation before returning.
setInitRecords() {
    local fqdn="$1"
    local registrar="$2"
    local sync_mode="$3"  # "sync" if -sync flag was passed
    
    if [ -z "$fqdn" ] || [ -z "$registrar" ]; then
        echo "Error: setInitRecords requires FQDN and REGISTRAR arguments" >&2
        return 1
    fi
    
    # Load the provider
    load_provider "$registrar"
    
    # Check database
    if [ ! -f "$DB_PATH" ]; then
        echo "Error: Database file $DB_PATH not found" >&2
        return 1
    fi
    
    # Get credentials for provider
    get_credentials "$registrar" "setInitRecords"
    
    # Get WAN IP
    if ! get_wan_ip; then
        echo "Error: Failed to determine WAN IP" >&2
        return 1
    fi
    
    # Call provider-specific setInitRecords implementation
    provider_set_init_records "$fqdn" "$WAN_IP"
    local result=$?
    
    if [ $result -ne 0 ]; then
        return $result
    fi
    
    # If sync mode, wait for DNS propagation
    if [ "$sync_mode" = "sync" ]; then
        echo "Waiting for DNS propagation (this may take up to 10 minutes)..."
        local max_wait=600  # 10 minutes
        local wait_interval=5
        local elapsed=0
        
        while [ $elapsed -lt $max_wait ]; do
            if check_init_dns_propagation "$fqdn" "$WAN_IP"; then
                echo "DNS propagation complete."
                
                # Re-set records with production TTL (7200s = 2 hours)
                echo "Updating TTL to 7200s for production use..."
                provider_set_init_records "$fqdn" "$WAN_IP" 7200
                
                return 0
            fi
            sleep $wait_interval
            elapsed=$((elapsed + wait_interval))
        done
        
        echo "Error: DNS propagation timed out" >&2
        return 1
    fi
    
    return 0
}

# Main check_status implementation
check_status() {
    local fqdn="$1"
    local provided_registrar="$2"
    local strict_mode="$3"  # 1=strict, 0=non-strict

    if [ -z "$fqdn" ]; then
        echo "Error: FQDN is required" >&2
        return 1
    fi

    # Normalize provided registrar upfront
    local provided_registrar_norm=""
    if [ -n "$provided_registrar" ]; then
        provided_registrar_norm=$(normalize_registrar "$provided_registrar")
    fi

    # 1) Check local domains DB first
    local db_row db_status db_registrar
    db_row=$(get_local_domain_status "$fqdn")
    if [ -n "$db_row" ]; then
        db_status=$(echo "$db_row" | cut -d'|' -f1)
        db_registrar=$(echo "$db_row" | cut -d'|' -f2)
        # Final statuses: free, owned, taken - return immediately
        # Transient status: unavailable - continue checking to resolve
        if [ "$db_status" = "free" ] || [ "$db_status" = "owned" ] || [ "$db_status" = "taken" ]; then
            echo "status=$db_status registrar=${db_registrar:-}" 
            return 0
        fi
        # unavailable is transient, continue to re-check
    fi

    # 2) Check local certificate existence
    if has_local_certificate "$fqdn"; then
        save_domain_status "$fqdn" "owned" "$provided_registrar_norm"
        echo "status=owned registrar=${provided_registrar_norm:-}"
        return 0
    fi

    # 3) Use whois lookup to infer registrar and basic availability
    local whois_out whois_registrar whois_registrar_norm status_decision registrar_to_save
    whois_out=$(whois_registrar_lookup "$fqdn" || true)

    if echo "$whois_out" | grep -qi "No match for"; then
        status_decision="free"
        registrar_to_save=""
        save_domain_status "$fqdn" "$status_decision" "$registrar_to_save"
        echo "status=$status_decision registrar="
        return 0
    fi

    # Extract and normalize whois registrar
    whois_registrar=$(echo "$whois_out" | awk -F: '/Registrar:/ {gsub(/^ +| +$/,"",$2); print $2; exit}')
    whois_registrar_norm=$(normalize_registrar "$whois_registrar")

    status_decision="unavailable"
    registrar_to_save="$whois_registrar_norm"

    # Compare normalized registrars
    if [ -n "$provided_registrar_norm" ] && [ -n "$whois_registrar_norm" ]; then
        if [ "$provided_registrar_norm" != "$whois_registrar_norm" ]; then
            if [ "$strict_mode" = "1" ]; then
                echo "Error: Registrar mismatch (provided '$provided_registrar_norm' vs whois '$whois_registrar_norm')" >&2
                return 1
            else
                echo "Warning: Registrar mismatch (provided '$provided_registrar_norm' vs whois '$whois_registrar_norm'), continuing with unavailable status" >&2
            fi
        else
            registrar_to_save="$provided_registrar_norm"
        fi
    elif [ -n "$provided_registrar_norm" ] && [ -z "$whois_registrar_norm" ]; then
        registrar_to_save="$provided_registrar_norm"
    fi

    # 4) If status is still "unavailable", try provider-specific API to
    #     disambiguate into "owned" vs "taken" when we know the registrar.
    if [ "$status_decision" = "unavailable" ] && [ -n "$registrar_to_save" ]; then
        case "$registrar_to_save" in
            namecheap.com)
                # Use Namecheap provider helper if available
                if command -v curl >/dev/null 2>&1; then
                    # Get WAN_IP using centralized helper
                    if get_wan_ip; then
                        # Load credentials for Namecheap API
                        get_credentials "namecheap.com" "check" 2>/dev/null || true
                        if [ -n "$PROVIDER_USERNAME" ] && [ -n "$PROVIDER_API_KEY" ]; then
                            load_provider "namecheap.com" 2>/dev/null || true
                            if declare -F provider_check_domain_status >/dev/null 2>&1; then
                                local provider_result provider_status
                                provider_result=$(provider_check_domain_status "$fqdn" "$WAN_IP" 2>/dev/null || true)
                                provider_status=$(echo "$provider_result" | awk -F'=' '/^status=/{print $2; exit}')
                                if [ "$provider_status" = "owned" ] || [ "$provider_status" = "taken" ]; then
                                    status_decision="$provider_status"
                                fi
                            fi
                        fi
                    fi
                fi
                ;;
        esac
    fi

    save_domain_status "$fqdn" "$status_decision" "$registrar_to_save"
    echo "status=$status_decision registrar=${registrar_to_save:-}"
}

# Function to check DNS propagation for initial DNS records (A @, A *, MX @)
# This verifies the records set by provider_set_init_records()
# Returns 0 if all records are propagated, 1 otherwise (single check, no loop)
check_init_dns_propagation() {
    local domain="$1"
    local wan_ip="$2"
    
    local a_root_ok=false
    local a_wildcard_ok=false
    local mx_ok=false
    
    # Phase 1: Check authoritative nameserver first (avoid negative caching at Google)
    # Get the authoritative NS for this domain
    local ns_server=$(dig +short NS "$domain" | head -1)
    if [ -z "$ns_server" ]; then
        ns_server="dns1.registrar-servers.com"  # Fallback for Namecheap
    fi
    
    # Check A record for @ (root domain) at authoritative NS
    local a_root_auth=$(dig +short @"$ns_server" "$domain" A 2>/dev/null)
    if [ -z "$a_root_auth" ] || ! echo "$a_root_auth" | grep -q "$wan_ip"; then
        echo "  [Auth NS] A @ not ready yet..."
        return 1
    fi
    
    # Check A record for wildcard at authoritative NS
    local a_wildcard_auth=$(dig +short @"$ns_server" "wildcard-test.${domain}" A 2>/dev/null)
    if [ -z "$a_wildcard_auth" ] || ! echo "$a_wildcard_auth" | grep -q "$wan_ip"; then
        echo "  [Auth NS] A * not ready yet..."
        return 1
    fi
    
    # Check MX record at authoritative NS
    local mx_auth=$(dig +short @"$ns_server" "$domain" MX 2>/dev/null)
    if [ -z "$mx_auth" ] || ! echo "$mx_auth" | grep -q "mail.${domain}"; then
        echo "  [Auth NS] MX not ready yet..."
        return 1
    fi
    
    echo "  [Auth NS] All records confirmed at authoritative nameserver"
    
    # Phase 2: Now safe to check Google DNS for global propagation
    # Check A record for @ (root domain)
    local a_root_response=$(curl -s "https://dns.google/resolve?name=${domain}&type=A" 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$a_root_response" ]; then
        if echo "$a_root_response" | grep -q "\"$wan_ip\""; then
            a_root_ok=true
        fi
    fi
    
    # Check A record for * (wildcard) - query a random subdomain
    local a_wildcard_response=$(curl -s "https://dns.google/resolve?name=wildcard-test.${domain}&type=A" 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$a_wildcard_response" ]; then
        if echo "$a_wildcard_response" | grep -q "\"$wan_ip\""; then
            a_wildcard_ok=true
        fi
    fi
    
    # Check MX record for @ (root domain) - mail.$domain with priority 10
    local mx_response=$(curl -s "https://dns.google/resolve?name=${domain}&type=MX" 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$mx_response" ]; then
        if echo "$mx_response" | grep -q "mail.${domain}"; then
            mx_ok=true
        fi
    fi
    
    # All records propagated
    if [ "$a_root_ok" = true ] && [ "$a_wildcard_ok" = true ] && [ "$mx_ok" = true ]; then
        return 0  # Success
    fi
    
    echo "  [Google DNS] Waiting for global propagation..."
    return 1
}

# Function to check DNS propagation for ACME TXT record
check_dns_propagation() {
    local domain="$1"
    local expected_value="$2"
    local acme_domain="_acme-challenge.$domain"
    local max_wait=600  # 10 minutes
    local wait_interval=5
    local elapsed=0
    
    # Get the authoritative NS for this domain
    local ns_server=$(dig +short NS "$domain" | head -1)
    
    echo "Waiting for ACME TXT record propagation..."
    
    while [ $elapsed -lt $max_wait ]; do
        # Phase 1: Check authoritative nameserver first (avoid negative caching)
        local auth_txt=$(dig +short @"$ns_server" "$acme_domain" TXT 2>/dev/null | tr -d '"')
        
        if [ -z "$auth_txt" ] || ! echo "$auth_txt" | grep -q "$expected_value"; then
            echo "  [Auth NS] TXT record not ready yet... (${elapsed}s)"
            sleep $wait_interval
            elapsed=$((elapsed + wait_interval))
            continue
        fi
        
        echo "  [Auth NS] TXT record confirmed at authoritative nameserver"
        
        # Phase 2: Now safe to check Google DNS for global propagation
        local response=$(curl -s "https://dns.google/resolve?name=${acme_domain}&type=TXT" 2>/dev/null)
        
        if [ $? -eq 0 ] && [ -n "$response" ]; then
            # Check if the expected value is in the response
            if echo "$response" | grep -q "\"$expected_value\""; then
                echo "  [Google DNS] TXT record propagated globally"
                return 0  # Success - DNS propagated
            fi
        fi
        
        echo "  [Google DNS] Waiting for global propagation... (${elapsed}s)"
        sleep $wait_interval
        elapsed=$((elapsed + wait_interval))
    done
    
    return 1  # Timeout - DNS did not propagate within max_wait
}

# List all owned domains from a registrar
# Usage: list <REGISTRAR>
list() {
    local registrar="$1"
    
    if [ -z "$registrar" ]; then
        echo "Error: REGISTRAR is required" >&2
        return 1
    fi
    
    # Load the provider
    load_provider "$registrar"
    
    # Check database
    if [ ! -f "$DB_PATH" ]; then
        echo "Error: Database file $DB_PATH not found" >&2
        return 1
    fi
    
    # Get credentials for provider
    get_credentials "$registrar" "list"
    
    # Get WAN IP
    if ! get_wan_ip; then
        echo "Error: Failed to determine WAN IP" >&2
        return 1
    fi
    
    # Call provider to list all owned domains (unfiltered)
    echo "Fetching owned domains from $registrar..."
    provider_list_all_domains "$WAN_IP"
    return $?
}

# Main migrate2local implementation - batch initialize DNS for owned domains
# Interactive mode: shows numbered list, prompts for selection
# Non-interactive: pass domain_selection argument (e.g., "1,3-5" or "all")
migrate2local() {
    local registrar="$1"
    local domain_selection="$2"
    
    if [ -z "$registrar" ]; then
        echo "Error: REGISTRAR is required" >&2
        return 1
    fi
    
    # Load the provider
    load_provider "$registrar"
    
    # Check database
    if [ ! -f "$DB_PATH" ]; then
        echo "Error: Database file $DB_PATH not found" >&2
        return 1
    fi
    
    # Get credentials for provider
    get_credentials "$registrar" "migrate2local"
    
    # Get WAN IP
    if ! get_wan_ip; then
        echo "Error: Failed to determine WAN IP" >&2
        return 1
    fi
    
    # List owned domains (this calls the provider function and populates OWNED_DOMAINS_LIST)
    echo "Fetching owned domains from $registrar..."
    provider_list_owned_domains "$WAN_IP"
    local list_result=$?
    
    if [ $list_result -eq 2 ]; then
        # All domains already initialized
        return 0
    elif [ $list_result -ne 0 ]; then
        echo "Error: Failed to fetch domain list" >&2
        return 1
    fi
    
    local domain_count=${#OWNED_DOMAINS_LIST[@]}
    
    if [ -z "$domain_selection" ]; then
        # Interactive mode: prompt for selection
        echo ""
        echo "Enter domain numbers to initialize (e.g., 1,3-5 or 'all'):"
        echo "Press Enter for all, or Ctrl+C to cancel"
        read -t 30 -p "> " domain_selection
        
        # Default to all if empty or timeout
        if [ -z "$domain_selection" ]; then
            domain_selection="all"
            echo "Auto-selecting all domains"
        fi
    fi
    
    # Parse the selection
    parse_domain_selection "$domain_selection" "$domain_count"
    
    if [ ${#SELECTED_INDICES[@]} -eq 0 ]; then
        echo "No valid domains selected" >&2
        return 1
    fi
    
    # Build list of selected domain names
    local selected_domains=()
    for idx in "${SELECTED_INDICES[@]}"; do
        selected_domains+=("${OWNED_DOMAINS_LIST[$idx]}")
    done
    
    echo ""
    echo "Selected ${#selected_domains[@]} domain(s) for DNS initialization"
    
    # Call the batch init function
    provider_batch_init_dns "$WAN_IP" "${selected_domains[@]}"
    return $?
}

# Check for help flag
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    usage
fi

# Check if at least one argument is provided
if [ $# -lt 1 ]; then
    usage
fi

# Get the function name from the first argument
FUNCTION_NAME="$1"
shift  # Remove the first argument, leaving any additional arguments

# Check if the function exists and call it
case "$FUNCTION_NAME" in
    "certify")
        if [ $# -lt 1 ]; then
            echo "Error: certify function requires REGISTRAR argument"
            echo "Usage: $0 certify <REGISTRAR>"
            exit 1
        fi
        REGISTRAR="$1"
        certify "$REGISTRAR"
        ;;
    "purchase")
        if [ $# -lt 2 ]; then
            echo "Error: purchase function requires FQDN and REGISTRAR arguments"
            echo "Usage: $0 purchase <FQDN> <REGISTRAR>"
            exit 1
        fi
        FQDN="$1"
        REGISTRAR="$2"
        purchase "$FQDN" "$REGISTRAR"
        ;;
    "cleanup")
        if [ $# -lt 1 ]; then
            echo "Error: cleanup function requires REGISTRAR argument"
            echo "Usage: $0 cleanup <REGISTRAR>"
            exit 1
        fi
        REGISTRAR="$1"
        cleanup "$REGISTRAR"
        ;;
    "check")
        if [ $# -lt 1 ]; then
            echo "Error: check function requires FQDN argument"
            echo "Usage: $0 check <FQDN> [REGISTRAR] [--strict]"
            exit 1
        fi
        FQDN="$1"; shift
        REGISTRAR=""
        STRICT_MODE=0
        while [ $# -gt 0 ]; do
            case "$1" in
                --strict)
                    STRICT_MODE=1
                    ;;
                *)
                    if [ -z "$REGISTRAR" ]; then
                        REGISTRAR="$1"
                    else
                        echo "Error: unexpected argument '$1'"
                        echo "Usage: $0 check <FQDN> [REGISTRAR] [--strict]"
                        exit 1
                    fi
                    ;;
            esac
            shift
        done
        check_status "$FQDN" "$REGISTRAR" "$STRICT_MODE"
        ;;
    "setInitRecords")
        if [ $# -lt 2 ]; then
            echo "Error: setInitRecords function requires FQDN and REGISTRAR arguments"
            echo "Usage: $0 setInitRecords <FQDN> <REGISTRAR> [-sync]"
            exit 1
        fi
        FQDN="$1"; shift
        REGISTRAR="$1"; shift
        SYNC_MODE=""
        while [ $# -gt 0 ]; do
            case "$1" in
                -sync|--sync)
                    SYNC_MODE="sync"
                    ;;
                *)
                    echo "Error: unexpected argument '$1'"
                    echo "Usage: $0 setInitRecords <FQDN> <REGISTRAR> [-sync]"
                    exit 1
                    ;;
            esac
            shift
        done
        setInitRecords "$FQDN" "$REGISTRAR" "$SYNC_MODE"
        ;;
    "checkInitDns")
        if [ $# -lt 2 ]; then
            echo "Error: checkInitDns function requires FQDN and WAN_IP arguments"
            echo "Usage: $0 checkInitDns <FQDN> <WAN_IP>"
            exit 1
        fi
        FQDN="$1"
        WAN_IP="$2"
        check_init_dns_propagation "$FQDN" "$WAN_IP"
        ;;
    "list")
        if [ $# -lt 1 ]; then
            echo "Error: list function requires REGISTRAR argument"
            echo "Usage: $0 list <REGISTRAR>"
            exit 1
        fi
        REGISTRAR="$1"
        list "$REGISTRAR"
        ;;
    "migrate2local")
        if [ $# -lt 1 ]; then
            echo "Error: migrate2local function requires REGISTRAR argument"
            echo "Usage: $0 migrate2local <REGISTRAR> [--domains \"1,3-5\"]"
            exit 1
        fi
        REGISTRAR="$1"; shift
        DOMAIN_SELECTION=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --domains)
                    shift
                    DOMAIN_SELECTION="$1"
                    ;;
                *)
                    echo "Error: unexpected argument '$1'"
                    echo "Usage: $0 migrate2local <REGISTRAR> [--domains \"1,3-5\"]"
                    exit 1
                    ;;
            esac
            shift
        done
        migrate2local "$REGISTRAR" "$DOMAIN_SELECTION"
        ;;
    *)
        echo "Error: Unknown function '$FUNCTION_NAME'"
        echo "Available functions: certify, purchase, cleanup, check, setInitRecords, checkInitDns, list, migrate2local"
        ;;
esac
