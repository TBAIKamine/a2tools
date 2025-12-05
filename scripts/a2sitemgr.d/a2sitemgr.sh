#!/bin/bash

# source prerequisites
. /usr/local/bin/getinput.d/getinput.sh

# Initialize variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/a2sitemgr.d"
MODE="domain"
PROXY_PORT=""
SECURED=false
FQDN=""
REGISTRAR=""
NON_INTERACTIVE=false
STRICT_MODE=false

# helper functions
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
        echo "Warning: $target already exists."
        if [ "$NON_INTERACTIVE" = true ]; then
            echo "Non-interactive mode: auto-accepting default (overwrite)."
            overwrite="Y"
        else
            overwrite=$(getInput "Overwrite $target? [Y/n] (auto-accept in ${timeout}s)" "Y" "$timeout" visible false true true)
            overwrite=${overwrite:-Y}
        fi
        case "$overwrite" in
            [Nn]* )
                echo "Keeping existing $target. Exiting."
                exit 0
                ;;
            * )
                echo "Overwriting $target"
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

        echo "Created subdomain wildcard config: $CONF"

        if command -v a2wcrecalc >/dev/null 2>&1; then
            echo "Calling a2wcrecalc $SUBDOMAIN..."
            a2wcrecalc "$SUBDOMAIN"
        else
            echo "Warning: a2wcrecalc not found. Please run it manually: a2wcrecalc $SUBDOMAIN"
        fi

        if command -v a2wcrecalc-dms >/dev/null 2>&1; then
            echo "Calling a2wcrecalc-dms..."
            a2wcrecalc-dms
        fi

        echo "Subdomain wildcard configuration complete for $FQDN"
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
        # Legacy single-switches replaced by -m/--mode; they are no longer accepted.
        -pp|--proxypass)
            echo "Error: -pp/--proxypass is removed; use -m pp or -m proxypass" >&2
            exit 1
            ;;
        --swc)
            echo "Error: --swc is removed; use -m swc or -m subdomainWildCard" >&2
            exit 1
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
        # servername option removed; proxypass uses FQDN as ServerName
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

# Normalize registrar short names to canonical hostnames
if [ -n "$REGISTRAR" ]; then
    case "$REGISTRAR" in
        "namecheap")
            REGISTRAR="namecheap.com"
            ;;
        *)
            echo "Error: Unsupported registrar: $REGISTRAR" >&2
            exit 1
            ;;
    esac
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
        echo "Base domain configuration not found at $BASE_DOMAIN_CONF"
        echo "Creating base domain configuration for $CERT_DOMAIN first..."
        # Call this script recursively for domain mode
        RECURSIVE_ARGS=(-d "$CERT_DOMAIN" -m domain)
        [ -n "$REGISTRAR" ] && RECURSIVE_ARGS+=(-r "$REGISTRAR")
        [ "$NON_INTERACTIVE" = true ] && RECURSIVE_ARGS+=(-ni)
        [ "$STRICT_MODE" = true ] && RECURSIVE_ARGS+=(-c)
        
        if ! "$0" "${RECURSIVE_ARGS[@]}"; then
            echo "Error: Failed to create base domain configuration for $CERT_DOMAIN" >&2
            exit 1
        fi
        echo "Base domain configuration created. Continuing with proxypass setup..."
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

            # Run fqdnmgr and capture its output. If an interactive terminal is
            # available, attach fqdnmgr's stdin to the terminal (/dev/tty) so
            # any prompts from fqdnmgr (e.g. entering missing registrar
            # credentials) are shown to the user. If no terminal is available
            # fall back to non-interactive invocation and redirect stdin from
            # /dev/null to avoid hangs.
            if [ -c /dev/tty ]; then
                # Preserve capturing stdout/stderr while letting fqdnmgr read
                # from the controlling terminal for prompts.
                FQDNMGR_OUTPUT=$(fqdnmgr "${FQDNMGR_ARGS[@]}" < /dev/tty 2>&1)
            elif [ -t 0 ]; then
                # stdin is a terminal (fd 0); allow interactive reads from it.
                FQDNMGR_OUTPUT=$(fqdnmgr "${FQDNMGR_ARGS[@]}" 2>&1)
            else
                # Non-interactive environment: prevent fqdnmgr from reading
                # from stdin (avoid hanging) by connecting it to /dev/null.
                FQDNMGR_OUTPUT=$(fqdnmgr "${FQDNMGR_ARGS[@]}" < /dev/null 2>&1)
            fi
            FQDNMGR_EXIT=$?

            if [ $FQDNMGR_EXIT -ne 0 ]; then
                echo "Warning: fqdnmgr status check failed: $FQDNMGR_OUTPUT" >&2
            else
                # Parse key=value pairs from fqdnmgr output
                # Example output: "status=owned registrar=namecheap.com"
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
                    echo "Domain $TARGET_DOMAIN appears to be free. Non-interactive mode: defaulting to not purchasing and exiting."
                    exit 0
                fi
                purchase_ans=$(getInput "Domain $TARGET_DOMAIN appears to be free. Purchase it now? [y/N] (timeout in 10s)" "N" 10 visible false true true)
                purchase_ans=${purchase_ans:-N}
                case "$purchase_ans" in
                    [Yy]*)
                        echo "Attempting to purchase $TARGET_DOMAIN via $REGISTRAR..."
                        fqdnmgr purchase "$REGISTRAR" "$TARGET_DOMAIN"
                        purchase_result=$?
                        case $purchase_result in
                            0)
                                echo "Successfully purchased $TARGET_DOMAIN"
                                ;;
                            1)
                                echo "Error: Insufficient balance to purchase $TARGET_DOMAIN" >&2
                                exit 1
                                ;;
                            2)
                                echo "Error: Failed to purchase $TARGET_DOMAIN (see /usr/local/bin/fqdnmgr.d/log for details)" >&2
                                exit 1
                                ;;
                            *)
                                echo "Error: Unknown error purchasing $TARGET_DOMAIN (exit code: $purchase_result)" >&2
                                exit 1
                                ;;
                        esac
                        ;;
                    *)
                        echo "User declined to purchase $TARGET_DOMAIN. Exiting gracefully."
                        exit 0
                        ;;
                esac
                ;;
            owned)
                # Nothing special here yet; certificate existence will be checked later
                ;;
            taken)
                echo "Domain $TARGET_DOMAIN is already taken by another owner. Exiting." >&2
                exit 1
                ;;
            unavailable)
                echo "Domain ownership for $TARGET_DOMAIN could not be determined (status=unavailable)." >&2
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
        echo "Existing certificates found for $CERT_DOMAIN at $CERT_PATH_BASE. Reusing them."
    else
        # Check if initial DNS records are already propagated
        WAN_IP=$(curl -s ifconfig.me)
        if fqdnmgr checkInitDns "$CERT_DOMAIN" "$WAN_IP"; then
            echo "Initial DNS records already propagated for $CERT_DOMAIN. Skipping setInitRecords."
        else
            # Set initial DNS records and wait for propagation before requesting certificates
            echo "Setting initial DNS records for $CERT_DOMAIN..."
            if ! fqdnmgr setInitRecords "$CERT_DOMAIN" "$REGISTRAR" -sync; then
                echo "Error: Failed to set initial DNS records for $CERT_DOMAIN" >&2
                exit 1
            fi
        fi

        echo "No existing certificates found for $CERT_DOMAIN. Requesting wildcard certificate..."
        if [ -z "$REGISTRAR" ]; then
            echo "Error: Registrar is required to request certificates. Please specify with -r or --registrar." >&2
            exit 1
        fi

        # Now request certificates
        if ! certbot -d "*.$CERT_DOMAIN" -d "$CERT_DOMAIN" \
                --manual \
                --preferred-challenges dns \
                --manual-auth-hook "fqdnmgr certify $REGISTRAR" \
                --manual-cleanup-hook "fqdnmgr cleanup $REGISTRAR" \
                --issuance-timeout 600 \
                certonly; then
                echo "Error: certbot failed to obtain certificates for $CERT_DOMAIN" >&2
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
    if a2ensite "$FQDN_BASE".conf; then
        echo "Successfully enabled site: $FQDN_BASE"
    else
        echo "Error: Failed to enable site $FQDN_BASE" >&2
        exit 1
    fi

    if systemctl reload apache2; then
        echo "Successfully reloaded Apache"
    else
        echo "Error: Failed to reload Apache. Check configuration with: apache2ctl configtest" >&2
        exit 1
    fi
}

echo "Apache configuration complete for $FQDN"
