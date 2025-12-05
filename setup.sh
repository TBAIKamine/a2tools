#!/bin/bash
cp -R ./scripts/* /usr/local/bin/

# List of commands to install
COMMANDS=(
    "getinput"
    "a2sitemgr"
    "fqdnmgr"
    "fqdncredmgr"
    "a2wcrecalc"
    "a2wcrecalc-dms"
)

# Create symlinks and set permissions for each command
for cmd in "${COMMANDS[@]}"; do
    ln /usr/local/bin/${cmd}.d/${cmd}.sh /usr/local/bin/${cmd}
    chmod  0550 /usr/local/bin/${cmd}.d
    chmod  0550 /usr/local/bin/${cmd}.d/*
    chmod +x /usr/local/bin/${cmd}
    chmod 0100 /usr/local/bin/${cmd}
    chown root:root /usr/local/bin/${cmd}
done

# fqdnmgr-specific: copy providers
mkdir -p /etc/fqdnmgr
cp -R ./scripts/fqdnmgr.d/providers /etc/fqdnmgr/
chmod 0750 /etc/fqdnmgr/providers
chown -R root:root /etc/fqdnmgr/providers

# fqdnmgr-specific: install domain registration config template
cp ./scripts/fqdnmgr.d/domain.conf.tpl /etc/fqdnmgr/domain.conf.tpl
chmod 0640 /etc/fqdnmgr/domain.conf.tpl
chown root:root /etc/fqdnmgr/domain.conf.tpl
# Create default config if it doesn't exist
if [ ! -f /etc/fqdnmgr/domain.conf ]; then
    cp /etc/fqdnmgr/domain.conf.tpl /etc/fqdnmgr/domain.conf
    chmod 0640 /etc/fqdnmgr/domain.conf
    chown root:root /etc/fqdnmgr/domain.conf
fi

# Setup fqdntools databases
mkdir -p /etc/fqdntools
sqlite3 /etc/fqdntools/domains.db < /usr/local/bin/fqdnmgr.d/schema.sql
chown root:root /etc/fqdntools/domains.db
chmod 0640 /etc/fqdntools/domains.db
sqlite3 /etc/fqdntools/creds.db < /usr/local/bin/fqdncredmgr.d/schema.sql
chown root:root /etc/fqdntools/creds.db
chmod 0640 /etc/fqdntools/creds.db
chown -R root:root /etc/fqdntools
chmod 0750 /etc/fqdntools