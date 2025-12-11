#!/bin/bash

# source prerequisites
. /usr/local/bin/getinput.d/getinput.sh

# Initialize variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/a2sitemgr.d"
MODE="domain"

# Helper: get WAN_IP - reads from /etc/environment, falls back to curl, caches for system-wide access
get_wan_ip() {
    # Check if WAN_IP is already set in environment
    if [ -n "$WAN_IP" ]; then
        export WAN_IP
        return 0
    fi
    
    # Try to read from /etc/environment
    if [ -f /etc/environment ]; then
        WAN_IP=$(grep -E "^WAN_IP=" /etc/environment 2>/dev/null | cut -d= -f2 | tr -d '"')
        if [ -n "$WAN_IP" ]; then
            export WAN_IP
            return 0
        fi
    fi
    
    # Fetch WAN IP from external service
    WAN_IP=$(curl -s ifconfig.me)
    
    if [ -z "$WAN_IP" ]; then
        echo "Error: Failed to determine WAN IP" >&2
        return 1
    fi
    
    # Cache to /etc/environment for system-wide access (requires root)
    if [ "$(id -u)" -eq 0 ]; then
        if grep -q "^WAN_IP=" /etc/environment 2>/dev/null; then
            sed -i "s|^WAN_IP=.*|WAN_IP=\"$WAN_IP\"|" /etc/environment
        else
            echo "WAN_IP=\"$WAN_IP\"" >> /etc/environment
        fi
    fi
    
    export WAN_IP
    return 0
}
PROXY_PORT=""
SECURED=false
FQDN=""
REGISTRAR=""
NON_INTERACTIVE=false
STRICT_MODE=false
VERBOSE=false
SET_INIT_DNS=false
SET_INIT_DNS_OVERRIDE=false
SET_INIT_DNS_SYNC=false

# Verbose echo - only prints when VERBOSE=true
vecho() { [ "$VERBOSE" = true ] && echo "$@" || true; }

# helper functions
handle_fqdnmgr_error() {
    local exit_code="$1"
    local output="$2"
    local context="$3"
    
    case "$exit_code" in
        10)
            echo "Error: Credentials daemon not running (socket not found)." >&2
            echo "Please ensure fqdncredmgrd service is running: sudo systemctl start fqdncredmgrd" >&2
            exit 1
            ;;
        11)
            local provider=$(echo "$output" | grep -oE 'CREDS_ERROR:no_credentials:(.+)' | cut -d: -f3)
            echo "Error: No credentials found for provider '$provider'." >&2
            echo "Please add credentials: sudo fqdncredmgr add $provider <username> -p <api_key>" >&2
            exit 1
            ;;
        12)
            echo "Error: Credentials database not found." >&2
            echo "Please run the installer to initialize the database." >&2
            exit 1
            ;;
        13|14|15)
            local err_detail=$(echo "$output" | grep -oE 'CREDS_ERROR:(.+)' | cut -d: -f2-)
            echo "Error: Credential error during $context: $err_detail" >&2
            exit 1
            ;;
        *)
            return 1
            ;;
    esac
}

usage() {
    local exit_code="${1:-0}"
    cat "$SCRIPT_DIR/usage.txt"
    exit "$exit_code"
}
check_prerequisites() {
    # Check if Apache is installed
    if ! command -v apache2 >/dev/null 2>&1 ; then
        echo "Error: Apache is not installed" >&2
        exit 1
    fi
    
    # Check required Apache modules
    local required_modules="rewrite ssl"
    if [ "$MODE" = "proxypass" ]; then
        required_modules="$required_modules proxy proxy_http"
    fi
    
    for module in $required_modules; do
        if ! apache2ctl -M 2>/dev/null | grep -q "${module}_module"; then
            echo "Warning: Apache module 'mod_$module' does not appear to be enabled" >&2
            echo "You may need to run: a2enmod $module" >&2
        fi
    done
}
render_from_template_to_path() {
    local tpl="$1"; local target="$2"; local timeout="${3:-10}"

    # If target exists, prompt once with the provided timeout.
    if [ -f "$target" ]; then
        vecho "Warning: $target already exists."
        if [ "$NON_INTERACTIVE" = true ]; then
            vecho "Non-interactive mode: auto-accepting default (overwrite)."
            overwrite="Y"
        else
            overwrite=$(getInput "Overwrite $target? [Y/n] (auto-accept in ${timeout}s)" "Y" "$timeout" visible false true true)
            overwrite=${overwrite:-Y}
        fi
        case "$overwrite" in
            [Nn]* )
                vecho "Keeping existing $target. Exiting."
                exit 0
                ;;
            * )
                vecho "Overwriting $target"
                ;;
        esac
    fi

    # General substitutions (available in all modes)
    sed \
        -e "s|{{FQDN}}|${FQDN:-}|g" \
        "$tpl" > "$target"

    # Mode-specific substitutions
    case "$MODE" in
        domain)
            sed -i \
                -e "s|{{CERT_DOMAIN}}|$CERT_DOMAIN|g" \
                -e "s|{{FQDN_BASE}}|${FQDN_BASE:-}|g" \
                "$target"
            ;;
        swc)
            sed -i \
                -e "s|{{SUBDOMAIN}}|$SUBDOMAIN|g" \
                "$target"
            ;;
        proxypass)
            sed -i \
                -e "s|{{SUBDOMAIN}}|$SUBDOMAIN|g" \
                -e "s|{{FQDN_BASE}}|${FQDN_BASE:-}|g" \
                -e "s|{{CERT_DOMAIN}}|$CERT_DOMAIN|g" \
                -e "s|{{ACTUAL_SERVER_NAME}}|$ACTUAL_SERVER_NAME|g" \
                -e "s|{{PROXY_PROTOCOL}}|$PROXY_PROTOCOL|g" \
                -e "s|{{PROXY_PORT}}|$PROXY_PORT|g" \
                "$target"
            ;;
    esac
}
do_config(){
    # 1) Standard mode
    if [ "$MODE" = "domain" ]; then
        # Ensure document root and log directory exist
        if [ ! -d "/var/www/$FQDN/public_html" ]; then
            mkdir -p /var/www/$FQDN/public_html
            mkdir -p /var/www/$FQDN/log
            chown -R www-data:www-data /var/www/$FQDN
        fi

        CONF="/etc/apache2/sites-available/${FQDN_BASE}.conf"
        render_from_template_to_path "$SCRIPT_DIR/init_standard.conf.tpl" "$CONF" 10
        return 0
    fi

    # 2) Subdomain Wildcard (SWC) mode
    if [ "$MODE" = "swc" ]; then
        # Validate FQDN format: subdomain.*
        if [[ ! "$FQDN" =~ ^[a-zA-Z0-9-]+\.\*$ ]]; then
            echo "Error: In subdomain wildcard mode (--swc), FQDN must be in format 'subdomain.*' (e.g., 'api.*')" >&2
            exit 1
        fi

        SUBDOMAIN="${FQDN%.*}"

        if [ "$SECURED" = true ] || [ -n "$PROXY_PORT" ] || [ -n "$REGISTRAR" ]; then
            echo "Error: Options -s/-p/-r are not valid with subdomain wildcard mode (use -m swc)" >&2
            exit 1
        fi

        CONF="/etc/apache2/sites-available/${SUBDOMAIN}.conf"
        render_from_template_to_path "$SCRIPT_DIR/swc_min.conf.tpl" "$CONF" 10

        vecho "Created subdomain wildcard config: $CONF"

        if command -v a2wcrecalc >/dev/null 2>&1; then
            vecho "Calling a2wcrecalc $SUBDOMAIN..."
            a2wcrecalc "$SUBDOMAIN"
        else
            echo "Warning: a2wcrecalc not found. Please run it manually: a2wcrecalc $SUBDOMAIN" >&2
        fi

        if command -v a2wcrecalc-dms >/dev/null 2>&1; then
            vecho "Calling a2wcrecalc-dms..."
            a2wcrecalc-dms
        fi

        vecho "Subdomain wildcard configuration complete for $FQDN"
        exit 0
    fi

    # 3) ProxyPass mode
    if [ "$MODE" = "proxypass" ]; then
        # Ensure log directory under base domain exists: /var/www/$CERT_DOMAIN/$SUBDOMAIN/log/
        LOG_DIR="/var/www/$CERT_DOMAIN/$SUBDOMAIN/log"
        if [ ! -d "$LOG_DIR" ]; then
            mkdir -p "$LOG_DIR"
            chown -R www-data:www-data "/var/www/$CERT_DOMAIN"
        fi

        CONF="/etc/apache2/sites-available/${FQDN_BASE}.conf"
        render_from_template_to_path "$SCRIPT_DIR/init_proxypass.conf.tpl" "$CONF" 10
        return 0
    fi
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -d=*|--fqdn=*)
            # Assigned-style: -d=example.com or --fqdn=example.com
            FQDN="${1#*=}"
            shift
            ;;
        -d|--fqdn)
            # Separate-arg style: -d example.com or --fqdn example.com
            FQDN="$2"
            shift 2
            ;;
        -m=*|--mode=*)
            # Assigned-style: -m=pp or --mode=proxypass
            MODE="${1#*=}"
            shift
            ;;
        -m|--mode)
            # Separate-arg style: -m pp or --mode proxypass
            MODE="$2"
            shift 2
            ;;
        -r=*|--registrar=*)
            # Assigned-style: -r=namecheap or --registrar=namecheap
            REGISTRAR="${1#*=}"
            shift
            ;;
        -r|--registrar)
            # Separate-arg style: -r namecheap or --registrar namecheap
            REGISTRAR="$2"
            shift 2
            ;;
        -s|--secured)
            # Use HTTPS for ProxyPass
            SECURED=true
            shift
            ;;
        -p=*|--port=*)
            # Assigned-style: -p=3000 or --port=3000
            PROXY_PORT="${1#*=}"
            shift
            ;;
        -p|--port)
            # Separate-arg style: -p 3000 or --port 3000
            PROXY_PORT="$2"
            shift 2
            ;;
        -ni|--non-interactive)
            NON_INTERACTIVE=true
            shift
            ;;
        -c|--strict)
            STRICT_MODE=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        --setInitDNSRecords)
            SET_INIT_DNS=true
            shift
            ;;
        -o|--override)
            SET_INIT_DNS_OVERRIDE=true
            shift
            ;;
        --sync)
            SET_INIT_DNS_SYNC=true
            shift
            ;;
        -h|--help)
            usage 0
            ;;
        -*)
            echo "Unknown option $1"
            usage 1
            ;;
        *)
            # Positional arguments
            if [ -z "$FQDN" ]; then
                FQDN="$1"
            else
                echo "Too many arguments"
                usage 1
            fi
            shift
            ;;
    esac
done
case "$MODE" in
    domain)
        MODE="domain"
        ;;
    pp|proxypass)
        MODE="proxypass"
        ;;
    swc|subdomainWildCard)
        MODE="swc"
        ;;
    *)
        echo "Error: Unknown mode: $MODE" >&2
        usage 1
        ;;
esac

# Resolve registrar names strictly via `fqdncredmgr list` (no fallbacks)
if [ -n "$REGISTRAR" ]; then
    # Require fqdncredmgr to be available — no local fallbacks or hardcoded mappings
    if ! command -v fqdncredmgr >/dev/null 2>&1; then
        echo "Error: Registrar resolution requires 'fqdncredmgr' but it was not found in PATH." >&2
        exit 1
    fi

    if [ "$VERBOSE" = true ]; then
        CRED_LIST=$(fqdncredmgr list -v 2>/dev/null || true)
    else
        CRED_LIST=$(fqdncredmgr list 2>/dev/null || true)
    fi
    if [ -z "$CRED_LIST" ]; then
        echo "Error: 'fqdncredmgr list' returned no credentials; cannot resolve registrar '$REGISTRAR'." >&2
        exit 1
    fi

    # If user provided a full hostname (contains a dot), require an exact match in the creds list
    if [[ "$REGISTRAR" == *.* ]]; then
        if echo "$CRED_LIST" | grep -qw -- "$REGISTRAR"; then
            : # exact match found, keep as-is
        else
            echo "Error: Registrar '$REGISTRAR' not found in fqdncredmgr credentials." >&2
            exit 1
        fi
    else
        # Short name provided: attempt to find a credential entry containing the short name
        MATCH=$(echo "$CRED_LIST" | grep -Eo "[A-Za-z0-9._-]*${REGISTRAR}[A-Za-z0-9._-]*" | head -n1 || true)
        if [ -n "$MATCH" ]; then
            REGISTRAR="$MATCH"
        else
            echo "Error: Registrar short-name '$REGISTRAR' could not be resolved from fqdncredmgr list." >&2
            exit 1
        fi
    fi

    # Final validation: resolved registrar must look like a hostname
    if [[ ! "$REGISTRAR" =~ \.[A-Za-z0-9] ]]; then
        echo "Error: Resolved registrar '$REGISTRAR' does not appear to be a hostname." >&2
        exit 1
    fi
fi

check_prerequisites
# Validations
if [ -z "$FQDN" ]; then
    echo "Error: FQDN is required" >&2
    exit 1
fi

# Early validation and variable setup for all modes
if [ "$MODE" = "domain" ]; then
    # Validate general FQDN format
    if [[ ! "$FQDN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]; then
        echo "Error: Invalid FQDN format: $FQDN" >&2
        exit 1
    fi

    # proxypass-only options are invalid for domain mode
    if [ "$SECURED" = true ]; then
        echo "Error: -s/--secured option is only valid with proxypass mode (use -m pp)" >&2
        exit 1
    fi
    if [ -n "$PROXY_PORT" ]; then
        echo "Error: -p/--port option is only valid with proxypass mode (use -m pp)" >&2
        exit 1
    fi

    FQDN_BASE="${FQDN%%.*}"
    CERT_DOMAIN="$FQDN"
    
    # For non-.com TLDs, include the TLD in the config filename
    if [[ ! "$FQDN" =~ \.com$ ]]; then
        TLD="${FQDN##*.}"
        FQDN_BASE="${FQDN_BASE}.${TLD}"
    fi

elif [ "$MODE" = "proxypass" ]; then
    # Validate FQDN for proxypass (should be subdomain.base)
    if [[ "$FQDN" =~ ^([^.]+)\.(.+)$ ]]; then
        SUBDOMAIN="${BASH_REMATCH[1]}"
        FQDN_BASE="$SUBDOMAIN"
        CERT_DOMAIN="${BASH_REMATCH[2]}"
    else
        echo "Error: In proxypass mode, FQDN must be a subdomain (e.g., something.example.com)" >&2
        exit 1
    fi

    # PROXY_PORT is required for proxypass mode
    if [ -z "$PROXY_PORT" ]; then
        echo "Error: Proxy port (-p/--port) is required when using proxypass mode (use -m pp)" >&2
        exit 1
    fi

    # Set proxypass-specific variables early for template rendering
    if [ "$SECURED" = true ]; then
        PROXY_PROTOCOL="https"
    else
        PROXY_PROTOCOL="http"
    fi
    ACTUAL_SERVER_NAME="$FQDN"
    
    # Check if base domain configuration exists; if not, create it first
    BASE_DOMAIN_CONF="/etc/apache2/sites-available/${CERT_DOMAIN%%.*}.conf"
    if [ ! -f "$BASE_DOMAIN_CONF" ]; then
        vecho "Base domain configuration not found at $BASE_DOMAIN_CONF"
        vecho "Creating base domain configuration for $CERT_DOMAIN first..."
        # Call this script recursively for domain mode
        RECURSIVE_ARGS=(-d "$CERT_DOMAIN" -m domain)
        [ -n "$REGISTRAR" ] && RECURSIVE_ARGS+=(-r "$REGISTRAR")
        [ "$NON_INTERACTIVE" = true ] && RECURSIVE_ARGS+=(-ni)
        [ "$STRICT_MODE" = true ] && RECURSIVE_ARGS+=(-c)
        [ "$VERBOSE" = true ] && RECURSIVE_ARGS+=(-v)
        
        if ! "$0" "${RECURSIVE_ARGS[@]}"; then
            echo "Error: Failed to create base domain configuration for $CERT_DOMAIN" >&2
            exit 1
        fi
        vecho "Base domain configuration created. Continuing with proxypass setup..."
    fi
fi

# STEP 1: Determine domain status and handle purchase / availability
{
    if [ "$MODE" = "domain" ] || [ "$MODE" = "proxypass" ]; then
        TARGET_DOMAIN="$FQDN"
        if [ "$MODE" = "proxypass" ]; then
            TARGET_DOMAIN="$CERT_DOMAIN"
        fi

        DOMAIN_STATUS="unknown"

        # Use fqdnmgr as single source of truth for status
        if ! command -v fqdnmgr >/dev/null 2>&1; then
            echo "Warning: fqdnmgr not found; domain ownership cannot be checked automatically." >&2
            echo "Please ensure domain $TARGET_DOMAIN is registered and DNS is configured before proceeding." >&2
        else
            FQDNMGR_ARGS=(check "$TARGET_DOMAIN")
            if [ -n "$REGISTRAR" ]; then
                FQDNMGR_ARGS+=("$REGISTRAR")
            fi
            if [ "$STRICT_MODE" = true ]; then
                FQDNMGR_ARGS+=("--strict")
            fi
            if [ "$VERBOSE" = true ]; then
                FQDNMGR_ARGS+=("-v")
            fi

            # Run fqdnmgr and show any prompts to the user if possible; otherwise, run it quietly without waiting for input.
            if [ -c /dev/tty ]; then
                # Let fqdnmgr show prompts to the user and capture its output.
                FQDNMGR_OUTPUT=$(fqdnmgr "${FQDNMGR_ARGS[@]}" < /dev/tty 2>&1)
            elif [ -t 0 ]; then
                # stdin is a terminal (fd 0); allow interactive reads from it.
                FQDNMGR_OUTPUT=$(fqdnmgr "${FQDNMGR_ARGS[@]}" 2>&1)
            else
                # If not interactive, run fqdnmgr quietly so it doesn't wait for user input.                echo "debug: No interactive terminal available; running fqdnmgr non-interactively"
                FQDNMGR_OUTPUT=$(fqdnmgr "${FQDNMGR_ARGS[@]}" < /dev/null 2>&1)
            fi
            FQDNMGR_EXIT=$?

            if [ $FQDNMGR_EXIT -ne 0 ]; then
                if ! handle_fqdnmgr_error "$FQDNMGR_EXIT" "$FQDNMGR_OUTPUT" "domain status check"; then
                    echo "Warning: fqdnmgr status check failed: $FQDNMGR_OUTPUT" >&2
                fi
            else
                # Get status and registrar from fqdnmgr output (preserve newlines with quotes)
                echo "$FQDNMGR_OUTPUT"
                STATUS_VAL=$(echo "$FQDNMGR_OUTPUT" | grep -oE 'status=[^ ]+' | cut -d= -f2)
                REGISTRAR_VAL=$(echo "$FQDNMGR_OUTPUT" | grep -oE 'registrar=[^ ]+' | cut -d= -f2)

                if [ -n "$REGISTRAR_VAL" ]; then
                    REGISTRAR="$REGISTRAR_VAL"
                fi

                if [ -n "$STATUS_VAL" ]; then
                    DOMAIN_STATUS="$STATUS_VAL"
                fi
            fi
        fi

        case "$DOMAIN_STATUS" in
            free)
                if [ -z "$REGISTRAR" ]; then
                    echo "Error: Domain $TARGET_DOMAIN is free but no registrar specified (-r/--registrar)" >&2
                    exit 1
                fi
                if [ "$NON_INTERACTIVE" = true ]; then
                    vecho "Domain $TARGET_DOMAIN appears to be free. Non-interactive mode: defaulting to not purchasing and exiting."
                    exit 0
                fi
                purchase_ans=$(getInput "Domain $TARGET_DOMAIN appears to be free. Purchase it now? [y/N] (timeout in 10s)" "N" 10 visible false true true)
                purchase_ans=${purchase_ans:-N}
                case "$purchase_ans" in
                    [Yy]*)
                        vecho "Attempting to purchase $TARGET_DOMAIN via $REGISTRAR..."
                        if [ "$VERBOSE" = true ]; then
                            PURCHASE_OUTPUT=$(fqdnmgr purchase "$REGISTRAR" "$TARGET_DOMAIN" -v 2>&1)
                        else
                            PURCHASE_OUTPUT=$(fqdnmgr purchase "$REGISTRAR" "$TARGET_DOMAIN" 2>&1)
                        fi
                        purchase_result=$?
                        if handle_fqdnmgr_error "$purchase_result" "$PURCHASE_OUTPUT" "domain purchase"; then
                            :
                        else
                            case $purchase_result in
                                0)
                                    vecho "Successfully purchased $TARGET_DOMAIN"
                                    ;;
                                1)
                                    echo "Error: Insufficient balance to purchase $TARGET_DOMAIN" >&2
                                    exit 1
                                    ;;
                                2)
                                    echo "Error: Failed to purchase $TARGET_DOMAIN (see /var/log/fqdnmgr/fqdnmgr.log for details)" >&2
                                    exit 1
                                    ;;
                                *)
                                    echo "Error: Unknown error purchasing $TARGET_DOMAIN (exit code: $purchase_result)" >&2
                                    exit 1
                                    ;;
                            esac
                        fi
                        ;;
                    *)
                        vecho "User declined to purchase $TARGET_DOMAIN. Exiting gracefully."
                        exit 0
                        ;;
                esac
                ;;
            owned)
                # Nothing special here yet; certificate existence will be checked later
                ;;
            taken)
                echo "Error: Domain $TARGET_DOMAIN is already taken by another owner." >&2
                exit 1
                ;;
            unavailable)
                echo "Error: Domain ownership for $TARGET_DOMAIN could not be determined (status=unavailable)." >&2
                echo "If you are sure you own it, please add it manually to the domains database and retry." >&2
                exit 1
                ;;
            *)
                # Unknown or not provided status: continue but warn the user
                echo "Warning: Unknown domain status for $TARGET_DOMAIN (status='$DOMAIN_STATUS'). Proceeding, but ensure you own the domain." >&2
                ;;
        esac
    fi
}

# STEP 2: Configure Apache site
do_config

# STEP 3: Set up SSL certificates (only if none exist yet)
{
    # only domain and proxypass modes reach this step, swc left the journey earlier
    CERT_PATH_BASE="/etc/letsencrypt/live/$CERT_DOMAIN"
    if [ -d "$CERT_PATH_BASE" ] && [ -f "$CERT_PATH_BASE/fullchain.pem" ] && [ -f "$CERT_PATH_BASE/privkey.pem" ]; then
        vecho "Existing certificates found for $CERT_DOMAIN at $CERT_PATH_BASE. Reusing them."
    else
        # Handle DNS record initialization
        if [ "$SET_INIT_DNS" = true ]; then
            # User requested setInitDNSRecords - call fqdnmgr to set them (it will check first internally)
            INIT_DNS_ARGS=(setInitDNSRecords -d "$CERT_DOMAIN")
            [ -n "$REGISTRAR" ] && INIT_DNS_ARGS+=(-r "$REGISTRAR")
            [ "$SET_INIT_DNS_OVERRIDE" = true ] && INIT_DNS_ARGS+=(-o)
            [ "$SET_INIT_DNS_SYNC" = true ] && INIT_DNS_ARGS+=(--sync)
            [ "$VERBOSE" = true ] && INIT_DNS_ARGS+=(-v)
            
            if [ -n "$REGISTRAR" ]; then
                vecho "Setting initial DNS records for $CERT_DOMAIN via $REGISTRAR..."
            else
                vecho "Setting initial DNS records for $CERT_DOMAIN (registrar will be auto-detected)..."
            fi
            
            if [ "$VERBOSE" = true ]; then
                fqdnmgr "${INIT_DNS_ARGS[@]}"
            else
                fqdnmgr "${INIT_DNS_ARGS[@]}" >/dev/null 2>&1
            fi
            INIT_DNS_EXIT=$?
            
            if [ $INIT_DNS_EXIT -ne 0 ]; then
                echo "Error: Failed to set initial DNS records for $CERT_DOMAIN" >&2
                exit 1
            fi
            vecho "Initial DNS records set for $CERT_DOMAIN."
        fi

        vecho "No existing certificates found for $CERT_DOMAIN. Requesting wildcard certificate..."
        if [ -z "$REGISTRAR" ]; then
            echo "Error: Registrar is required to request certificates. Please specify with -r or --registrar." >&2
            exit 1
        fi

        # Now request certificates
        CERTBOT_AUTH_HOOK="fqdnmgr certify $REGISTRAR"
        CERTBOT_CLEANUP_HOOK="fqdnmgr cleanup $REGISTRAR"
        if [ "$VERBOSE" = true ]; then
            CERTBOT_AUTH_HOOK="fqdnmgr certify $REGISTRAR -v"
            CERTBOT_CLEANUP_HOOK="fqdnmgr cleanup $REGISTRAR -v"
            # In verbose mode, let output flow through in real-time
            certbot -d "*.$CERT_DOMAIN" -d "$CERT_DOMAIN" \
                --manual \
                --preferred-challenges dns \
                --manual-auth-hook "$CERTBOT_AUTH_HOOK" \
                --manual-cleanup-hook "$CERTBOT_CLEANUP_HOOK" \
                --issuance-timeout 3600 \
                certonly
            CERTBOT_EXIT=$?
            CERTBOT_OUTPUT=""  # No captured output in verbose mode
        else
            # In non-verbose mode, capture output for error reporting
            CERTBOT_OUTPUT=$(certbot -d "*.$CERT_DOMAIN" -d "$CERT_DOMAIN" \
                --manual \
                --preferred-challenges dns \
                --manual-auth-hook "$CERTBOT_AUTH_HOOK" \
                --manual-cleanup-hook "$CERTBOT_CLEANUP_HOOK" \
                --issuance-timeout 600 \
                certonly 2>&1)
            CERTBOT_EXIT=$?
        fi
        if [ $CERTBOT_EXIT -ne 0 ]; then
            # In verbose mode, errors were already displayed; provide generic message
            if [ "$VERBOSE" = true ]; then
                echo "Error: certbot failed to obtain certificates for $CERT_DOMAIN (exit code: $CERTBOT_EXIT)" >&2
            else
                # Check if certbot failure was due to credential errors from fqdnmgr hooks
                if echo "$CERTBOT_OUTPUT" | grep -q "CREDS_ERROR:"; then
                    CREDS_ERR_LINE=$(echo "$CERTBOT_OUTPUT" | grep "CREDS_ERROR:" | head -1)
                    case "$CREDS_ERR_LINE" in
                        *no_credentials*)
                            provider=$(echo "$CREDS_ERR_LINE" | cut -d: -f3)
                            echo "Error: No credentials found for provider '$provider'." >&2
                            echo "Please add credentials: sudo fqdncredmgr add $provider <username> -p <api_key>" >&2
                            ;;
                        *socket_not_found*)
                            echo "Error: Credentials daemon not running (socket not found)." >&2
                            echo "Please ensure fqdncredmgrd service is running: sudo systemctl start fqdncredmgrd" >&2
                            ;;
                        *database_not_found*)
                            echo "Error: Credentials database not found." >&2
                            echo "Please run the installer to initialize the database." >&2
                            ;;
                        *)
                            echo "Error: Credential error during certificate request: $CREDS_ERR_LINE" >&2
                            ;;
                    esac
                else
                    echo "Error: certbot failed to obtain certificates for $CERT_DOMAIN" >&2
                    echo "$CERTBOT_OUTPUT" >&2
                fi
            fi
            exit 1
        fi
    fi
}

# STEP 4: Finalize Apache configuration
{
    if [ "$MODE" = "domain" ]; then
        # Remove DocumentRoot and ServerAlias lines from apache config (combine sed operations)
        sed -i -e '/DocumentRoot/d' -e '/ServerAlias/d' /etc/apache2/sites-available/"$FQDN_BASE".conf
    fi
    
    # For all remaining modes: Add HTTPS redirect to the existing <VirtualHost *:80> block
    sed -i '/<VirtualHost \*:80>/a\
    RewriteEngine On\
    RewriteCond %{HTTPS} !=on\
    RewriteRule ^(.*)$ https://%{HTTP_HOST}%{REQUEST_URI} [L,R=301]' /etc/apache2/sites-available/"$FQDN_BASE".conf
    
    # Add SSL VirtualHost directives
    if [ "$MODE" = "domain" ]; then
        # Use certificates for the specific domain
        sed \
            -e "s|{{FQDN}}|$FQDN|g" \
            -e "s|{{FQDN_BASE}}|$FQDN_BASE|g" \
            "$SCRIPT_DIR/ssl_standard.conf.tpl" >> /etc/apache2/sites-available/"$FQDN_BASE".conf
    elif [ "$MODE" = "proxypass" ]; then
        # Use wildcard certificates from base domain - no DocumentRoot for proxypass
        sed \
            -e "s|{{ACTUAL_SERVER_NAME}}|$ACTUAL_SERVER_NAME|g" \
            -e "s|{{SUBDOMAIN}}|$SUBDOMAIN|g" \
            -e "s|{{FQDN_BASE}}|$FQDN_BASE|g" \
            -e "s|{{CERT_DOMAIN}}|$CERT_DOMAIN|g" \
            -e "s|{{PROXY_PROTOCOL}}|$PROXY_PROTOCOL|g" \
            -e "s|{{PROXY_PORT}}|$PROXY_PORT|g" \
            "$SCRIPT_DIR/ssl_proxypass.conf.tpl" >> /etc/apache2/sites-available/"$FQDN_BASE".conf
    fi

    # Test Apache configuration before enabling
    if ! apache2ctl configtest 2>/dev/null; then
        echo "Error: Apache configuration test failed. Check your config with: apache2ctl configtest" >&2
        exit 1
    fi

    # Enable site and reload Apache with error handling
    if a2ensite "$FQDN_BASE".conf >/dev/null 2>&1; then
        vecho "Successfully enabled site: $FQDN_BASE"
    else
        echo "Error: Failed to enable site $FQDN_BASE" >&2
        exit 1
    fi

    if systemctl reload apache2; then
        vecho "Successfully reloaded Apache"
    else
        echo "Error: Failed to reload Apache. Check configuration with: apache2ctl configtest" >&2
        exit 1
    fi
}

vecho "Apache configuration complete for $FQDN"
