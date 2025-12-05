#!/bin/bash

# Check for optional domain argument
WILDCARD_DOMAIN="$1"

# Directory containing Apache site config files
CONFIG_DIR="/etc/apache2/sites-available"

# Arrays to hold unique server names
declare -a wildcard_servers
declare -a domain_servers

# Function to check if an element is in an array
contains() {
    local e match="$1"
    shift
    for e; do [[ "$e" == "$match" ]] && return 0; done
    return 1
}

# If a wildcard domain is specified, use only that domain
if [[ -n "$WILDCARD_DOMAIN" ]]; then
    wildcard_servers=("$WILDCARD_DOMAIN")
else
    # Loop through all config files to find wildcard domains
    for config_file in "$CONFIG_DIR"/*.conf; do
        if [[ -f "$config_file" ]]; then
            # Extract ServerName values
            server_names=$(grep -i '^ServerName' "$config_file" | awk '{print $2}')
            for server_name in $server_names; do
                # Check for wildcard format: text.*
                if [[ "$server_name" =~ ^text\..* ]]; then
                    if ! contains "$server_name" "${wildcard_servers[@]}"; then
                        wildcard_servers+=("$server_name")
                    fi
                fi
            done
        fi
    done
fi

# Loop through all config files to find domain servers
for config_file in "$CONFIG_DIR"/*.conf; do
    if [[ -f "$config_file" ]]; then
        # Extract ServerName values
        server_names=$(grep -i '^ServerName' "$config_file" | awk '{print $2}')
        for server_name in $server_names; do
            # Check for domain.extension format
            if [[ "$server_name" =~ ^[a-zA-Z0-9-]+\.[a-zA-Z]+$ ]]; then
                if ! contains "$server_name" "${domain_servers[@]}"; then
                    domain_servers+=("$server_name")
                fi
            fi
        done
    fi
done

# Output directory for new config files
OUTPUT_DIR="/etc/apache2/sites-available"

# Loop through each wildcard server
for wildcard in "${wildcard_servers[@]}"; do
    # Extract subdomain label from wildcard (e.g., "mail" from "mail.*")
    subdomain_label="${wildcard%%.*}"

    # If there are no non-wildcard domain servers delete the file if it exists and continue
    if [ "${#domain_servers[@]}" -gt 0 ]; then
        # First, always create :80 VirtualHost entries to preserve HTTP behavior
        config_content=""
        for domain in "${domain_servers[@]}"; do
            config_content="${config_content}<VirtualHost *:80>\n"
            config_content="${config_content}ServerName ${subdomain_label}.${domain}\n"
            config_content="${config_content}</VirtualHost>\n"
        done

        # Then append SSL :443 VirtualHosts for domains that have certificates
        ssl_blocks=""
        for domain in "${domain_servers[@]}"; do
            if [ -d "/etc/letsencrypt/live/${domain}" ]; then
                ssl_blocks="${ssl_blocks}<VirtualHost *:443>\n"
                ssl_blocks="${ssl_blocks}ServerName ${subdomain_label}.${domain}\n"
                ssl_blocks="${ssl_blocks}SSLEngine on\n"
                ssl_blocks="${ssl_blocks}SSLCertificateFile /etc/letsencrypt/live/${domain}/fullchain.pem\n"
                ssl_blocks="${ssl_blocks}SSLCertificateKeyFile /etc/letsencrypt/live/${domain}/privkey.pem\n"
                ssl_blocks="${ssl_blocks}</VirtualHost>\n"
            fi
        done

        if [ -n "$ssl_blocks" ]; then
            config_content="${config_content}<IfModule mod_ssl.c>\n${ssl_blocks}</IfModule>\n"
        fi
        # Save the file as ${subdomain_label}.conf
        echo -e "$config_content" > "${OUTPUT_DIR}/${subdomain_label}.conf"
    else
        # No domain servers found, remove existing config file if it exists
        config_file_path="${OUTPUT_DIR}/${subdomain_label}.conf"
        if [ -f "$config_file_path" ]; then
            rm -f "$config_file_path"
        fi
    fi
done
