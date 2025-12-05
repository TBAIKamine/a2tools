## Commands
in short: this script makes these commands available  
- `a2sitemgr` — Apache2 site manager
- `fqdnmgr` — FQDN manager
- `fqdncredmgr` — FQDN credentials manager

# overview

- Apache2 is very flexible and supports many kinds of virtual hosts, but many configurations are repetitive. `a2sitemgr` provides a quick, opinionated way to deploy the most common virtual-host patterns and is designed to make automation easy.
- `a2sitemgr` integrates with ACME (via `certbot`) to obtain TLS certificates automatically.
- `fqdnmgr` complements `a2sitemgr` by interacting with domain registrars' APIs (for example, Namecheap) to check domain status, purchase domains, and set DNS records when needed.
- `fqdncredmgr` standardizes how provider credentials are collected and stored so other tools (like `fqdnmgr`) can use them safely.

## Notes

- `a2sitemgr` integrates with the other tools and will call them when appropriate (for example, checking domain ownership or creating DNS records).
- This project uses `certbot` instead of `lego` for certificate management because `lego` commonly relies on permanent environment variables for provider credentials; that increases the attack surface since those environment variables are harder to protect. Switching to temporary credentials would require pre- and post-cert hooks; `lego` does not provide a built-in mechanism for that in every provider integration.
- The codebase is modular: currently Namecheap is the only provider implemented, but adding new providers is straightforward and PRs are welcome.
- Two helper commands are used internally by `a2sitemgr`:
  - `a2wcrecalc` — Recalculates Apache site configuration files to update wildcard-subdomain configurations. This is useful to enable/disable wildcard subdomains across existing vhosts.
  - `a2wcrecalc-dms` — Similar to `a2wcrecalc`, but additionally generates mapping files used by ([`docker-mailserver`](https://github.com/docker-mailserver/docker-mailserver)).

  Note: set the environment variable `DMS_DIR` to point to your docker-mailserver mount directory; it defaults to `/opt/compose/docker-mailserver` if not set.

## Prerequisites

- Tested on Ubuntu Server `24.04 LTS` (amd64). It may work on other distros but have not been tested.  
- needs `certbot`, `sqlite3`, `whois` and `libxml2-utils` packages installed
```
sudo apt install -y whois certbot sqlite3 libxml2-utils
```

## Install

Clone the repository, then run the installer script:

```bash
mkdir a2tools && cd a2tools
git clone https://github.com/TBAIKamine/a2tools.git .
bash ./setup.sh
```

## Basic usage

Run `a2sitemgr` (it will prompt you interactively):

```bash
sudo a2sitemgr -d example.com
```

Use `--help` for more details about options.

## Advanced usage examples

SWC (subdomain wildcard):

- A subdomain wildcard lets a subdomain work for multiple base domains (for example, `mail.*`). If your base domains are `example1.com` and `example2.com`, you can create a wildcard subdomain with:

```bash
sudo a2sitemgr -d 'mail.*' --mode swc
```

This will create the necessary configuration to serve `mail.example1.com` and `mail.example2.com` and use existing certificates for the relevant domains.

ProxyPass (reverse proxy to a container):

- To expose a container on a single subdomain and use ProxyPass, run:

```bash
sudo a2sitemgr -d sub.example.com --mode proxypass -p 1234
```

- Use `--secured` (or `-s`) when the proxied service uses HTTPS:

```bash
sudo a2sitemgr -d sub.example.com --mode proxypass -p 1234 --secured
```

The command will create the ProxyPass site configuration and request certificates as needed.

for the full list of parameters or if you need help or want to examine usage details for any component, use `--help`.

## License
I vibe coded this entire deal so feel free to use it as you wish