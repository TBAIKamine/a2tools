# a2tools

Opinionated Apache2 virtual host management, registrar (Namecheap, Wedos) automation, and ACME DNS-01 certificate issuance.

Current release: **1.0.0**

# overview

- Apache2 is very flexible and supports many kinds of virtual hosts, but many configurations are repetitive. `a2sitemgr` provides a quick, opinionated way to deploy the most common virtual-host patterns and is designed to make automation easy.
- `a2sitemgr` integrates with ACME (via `certbot`) to obtain TLS certificates automatically.
- `fqdnmgr` complements `a2sitemgr` by interacting with domain registrars' APIs (for example, Namecheap) to check domain status, purchase domains, and set DNS records when needed.
- `fqdncredmgr` standardizes how provider credentials are collected and stored so other tools (like `fqdnmgr`) can use them safely. Credentials live in a root-only SQLite database (`/var/lib/a2tools/creds.db`, mode 0600) and are read directly by `fqdnmgr` — no daemon, no socket.

## Commands
in short: this script makes these commands available  
- `a2sitemgr` — Apache2 site manager
- `fqdnmgr` — FQDN manager to interact with the registrar (purchase a domain, set DNS records etc.)
- `fqdncredmgr` — FQDN credentials manager

All commands use **named flags only** (short `-d` or long `--fqdn`, etc., with a space separating the flag from its value). Positional arguments are not accepted anywhere; the FQDN is always supplied via `-d` / `--fqdn`, the registrar via `-r` / `--registrar`, and so on. See `man <command>` or `<command> --help` for the full flag list of each command.

## Configuration

All a2tools commands read a two-tier, upgrade-safe config:

| File | Owner | Survives `apt upgrade`? | Purpose |
| --- | --- | --- | --- |
| `/etc/a2tools/a2tools.conf` | user (dpkg conffile) | yes | Local overrides — loaded first, so values here win. |
| `/etc/a2tools/a2tools.conf.d/*.conf` | mixed | each file: yes if local, no if shipped | Modular drop-ins, loaded in lexicographic order. The shipped default lives in `00-defaults.conf`; create e.g. `99-local.conf` to override without editing any package-owned file. |

When run from the repo (no install), the loader falls back to `scripts/share/etc/a2tools/` so dev workflows still pick up the defaults.

### Setting the docker-mailserver mount directory

Edit `/etc/a2tools/a2tools.conf` and set, for example:

```sh
DMS_DIR="/srv/docker/docker-mailserver"
```

Or create `/etc/a2tools/a2tools.conf.d/99-local.conf` with the same `DMS_DIR="…"` line.

## Notes

- `a2sitemgr` integrates with the other tools and will call them when appropriate (for example, checking domain ownership or creating DNS records).
- This project uses `certbot` instead of `lego` for certificate management because `lego` commonly relies on permanent environment variables for provider credentials; that increases the attack surface since those environment variables are harder to protect. Switching to temporary credentials would require pre- and post-cert hooks; `lego` does not provide a built-in mechanism for that in every provider integration.
- The codebase is modular: currently Namecheap is the only provider implemented, but adding new providers is straightforward and PRs are welcome.
- Two helper commands are used internally by `a2sitemgr`:
  - `a2wcrecalc` — Recalculates Apache site configuration files to update wildcard-subdomain configurations. This is useful to enable/disable wildcard subdomains across existing vhosts.
  - `a2wcrecalc-dms` — Similar to `a2wcrecalc`, but additionally generates mapping files used by ([`docker-mailserver`](https://github.com/docker-mailserver/docker-mailserver)).

  Note: the docker-mailserver mount directory is resolved in this order: the `-d` / `--dir` flag, then the `DMS_DIR` environment variable, then the value of `DMS_DIR` from `/etc/a2tools/a2tools.conf` (or any file in `/etc/a2tools/a2tools.conf.d/`), and finally the built-in default `/opt/compose/docker-mailserver`. See the **Configuration** section below.

## Prerequisites

- Tested on Ubuntu Server `24.04 LTS` (amd64). The `debian/` packaging is Debian-policy compliant and should work on any current Debian or Ubuntu release with `debhelper-compat (= 13)`.
- For the local build path, you also need `build-essential`, `debhelper`, `devscripts`, and `fakeroot`. Runtime dependencies (declared in `debian/control`) are pulled in automatically by `apt`.

## Install

The maintainer publishes prebuilt packages for supported Ubuntu releases at the Launchpad PPA `ppa:amen8/a2tools`. Install from there — that is the supported path:

```bash
sudo add-apt-repository ppa:amen8/a2tools
sudo apt update
sudo apt install a2tools
```

If you need a build for a series the PPA does not publish (e.g. Debian, or an Ubuntu release that is not yet packaged), build the package locally from this repository:

```bash
sudo apt install build-essential debhelper devscripts fakeroot
# From the repository root (where the top-level debian/ directory lives)
dpkg-buildpackage -us -uc -b
sudo apt install ../a2tools_<version>_<arch>.deb
```

Both paths install every command, manpage, systemd unit, logrotate snippet, and SQL schema under the standard FHS paths. To uninstall:

```bash
sudo apt purge a2tools
```

## Supported registrars
- [namecheap.com](https://www.namecheap.com)
- [wedos.com](https://www.wedos.com)

additional providers may be added, PR are also welcome

## Basic usage
All commands use named flags only. Positional arguments are not accepted
anywhere; the FQDN is always supplied via `-d` / `--fqdn`, the registrar
via `-r` / `--registrar`, and so on.
#### 1. Add credentials:
```
sudo fqdncredmgr add -p namecheap.com -u username
```
you will be prompted for the API key with masked input. For scripting, pipe the key over stdin with `-k -` (keeps it out of the process list and shell history):
```
printf '%s\n' "$API_KEY" | sudo fqdncredmgr add -p namecheap.com -u username -k -
```
for full command usage options use `-h` or `--help`
#### 2. Purchase a domain
```
sudo fqdnmgr purchase -d example.com -r namecheap.com
```
for full command usage options use `-h` or `--help`
#### 3. Set necessary DNS records.
```
sudo fqdnmgr setInitDNSRecords -d example1.com -d example2.com
#set for all of your domains associated with the registrar:
sudo fqdnmgr setInitDNSRecords -r namecheap.com
```
you can use `-v` for verbosity to see the progress, `-o` to override existing DNS records, `--sync` to wait until the propagation is confirmed.  
for full command usage options use `-h` or `--help`

#### 4. Configure the website:

```bash
sudo a2sitemgr -d example.com
```
this would create the necessary directories and config file then request LE certificates using certbot (must be already installed and registered) using ACME challenge for wildcard subdomain certificates and will implicitly check the propagation.
Use `--help` for more details about options.

## Advanced usage examples
SWC (subdomain wildcard):  
- A subdomain wildcard lets a subdomain work for multiple base domains (for example, `mail.*`). If your base domains are `example1.com` and `example2.com`, you can create a wildcard subdomain with:  
```bash
sudo a2sitemgr -d 'mail.*' --mode swc
```
This will create the necessary configuration to serve `mail.example1.com` and `mail.example2.com` and use existing certificates for the relevant base domains automatically.  
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

technically both `swc` and `proxypass` modes can be combined but as an opinionated tool, this case doesn't seem to be populare (at least for now).  

## Important notes:
- the auth hook for the ACME challenge by certbot uses a smart propagation check that uses exponontially decaying checkpoints until reaching the propagation average time for that specific provider.  
the check is verified against the NameServer and Google DNS `8.8.8.8` then offers a minimum of 10s buffer time (actual buffer time depends on the registrar)  
since certbot will crash if the propagation didn't happen yet, `a2sitemgr` will lower that risk to bare minimum, it almost always guarenteed to have a successful validation.  
- certificate renewals are handled by certbot's own systemd timer: the fqdnmgr auth/cleanup hooks are stored in each certificate's renewal profile, and the a2tools deploy hook (`/etc/letsencrypt/renewal-hooks/deploy/a2tools`) reloads Apache and updates the domains database after every successful renewal. Use `a2certrenew` for a manual renewal run (extra flags such as `--dry-run` or `--cert-name` are passed through to `certbot renew`).


## Manpages
After install, every command has a manpage:
- `man a2sitemgr`
- `man a2certrenew`
- `man a2wcrecalc`
- `man a2wcrecalc-dms`
- `man fqdnmgr`
- `man fqdncredmgr`

## License
This project is licensed under the [MIT License](LICENSE) (c) 2026 Amine Tbaik. See [LICENSE](LICENSE) for the full text.