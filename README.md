# t4a-wordpress-hosting

Operational scripts for the WordPress hosting stack running on the
`t4a-instance` server (AlmaLinux + nginx + certbot + Cloudflare DNS).

This repository is intentionally small and script-first. Each script is
self-contained, safe to re-run, and documents its own usage via `--help`.

---

## Contents

| Script | Purpose |
| --- | --- |
| [`scripts/ssl/issue-cert.sh`](scripts/ssl/issue-cert.sh) | Issue a Let's Encrypt certificate via certbot + Cloudflare DNS-01 and write a matching nginx SSL snippet. |
| [`scripts/nginx/create-site.sh`](scripts/nginx/create-site.sh) | Generate an nginx server-block config for a WordPress site, with optional apex-to-www redirect. |
| [`scripts/wordpress/add-user.sh`](scripts/wordpress/add-user.sh) | Create a WordPress user for one of the sites on this server. Picks a database (interactively or via flag) and invokes wp-cli against the matching install. |

More scripts will land here as they're extracted from runbooks.

A typical new-site bring-up uses both, in order:

```bash
# 1. issue the cert
sudo ./scripts/ssl/issue-cert.sh --account t4a -d example.com -d www.example.com

# 2. generate the site config
sudo ./scripts/nginx/create-site.sh --domain example.com --redirect-to-www

# 3. reload nginx
sudo systemctl reload nginx
```

---

## `issue-cert.sh`

Wraps `certbot certonly --dns-cloudflare` with the project's conventions, then
renders an nginx SSL snippet pointing at the new cert so a new domain can be
wired up end-to-end in one command.

### What it does

1. Picks the right Cloudflare API credentials (`etiam.si` account vs. `t4a`
   account) based on `--account` (or prompts interactively).
2. Runs `certbot certonly --dns-cloudflare` against the project-standard
   certbot paths under `/data/certbot/`.
3. Renders an nginx SSL snippet from
   [`scripts/ssl/templates/ssl-snippet.conf.tmpl`](scripts/ssl/templates/ssl-snippet.conf.tmpl)
   into `/etc/nginx/snippets/ssl-<cert-name>.conf`.
4. Validates the nginx config (`nginx -t`).
5. Tells you how to include the snippet in your server block and reload nginx
   (it won't reload for you — that's a human call).

### Usage

```bash
sudo ./scripts/ssl/issue-cert.sh \
  --account t4a|etiam \
  [--cert-name NAME] \
  [--force] \
  -d <domain> [-d <domain> ...]
```

| Flag | Description |
| --- | --- |
| `--account` | Which Cloudflare account's credentials to use. Prompted if omitted. |
| `--cert-name` | Cert name / live directory name under `/data/certbot/config/live/`. Defaults to the first `-d` value with any leading `*.` stripped. |
| `--force` | Overwrite an existing `/etc/nginx/snippets/ssl-<cert-name>.conf`. Default is to refuse. |
| `-d <domain>` | Domain for the cert. Repeat the flag for SANs. Wildcards like `*.etiam.si` are fine. |

### Examples

Issue a cert for a t4a subdomain:

```bash
sudo ./scripts/ssl/issue-cert.sh --account t4a -d app.t4a.etiam.si
```

Issue a wildcard for `etiam.si` (with explicit cert name):

```bash
sudo ./scripts/ssl/issue-cert.sh \
  --account etiam \
  --cert-name etiam.si \
  -d '*.etiam.si' -d etiam.si
```

Interactive (no `--account` flag, script prompts):

```bash
sudo ./scripts/ssl/issue-cert.sh -d new.t4a.etiam.si
```

### Account → credentials mapping

| `--account` | Credentials file | Zones |
| --- | --- | --- |
| `etiam` | `/data/certbot/credentials/cloudflare.ini` | `etiam.si` and subdomains |
| `t4a` | `/data/certbot/credentials/cloudflare-t4a.ini` | t4a domains |

Both files must be `chmod 600`. The script refuses to continue otherwise.

### After it runs

Add the snippet to your server block and reload nginx:

```nginx
server {
    listen 443 ssl http2;
    server_name app.t4a.etiam.si;

    include snippets/ssl-app.t4a.etiam.si.conf;

    # ...
}
```

```bash
sudo nginx -t && sudo systemctl reload nginx
```

---

## `create-site.sh`

Generates an nginx server block for a WordPress site from
[`scripts/nginx/templates/site.conf.tmpl`](scripts/nginx/templates/site.conf.tmpl)
and drops it into `/etc/nginx/conf.d/<domain>.conf`. The template bundles the
project's standard WordPress hardening: upload-size limits, FastCGI buffer
tuning (fixes *"upstream sent too big header"*), security headers, blocks on
`wp-config.php` / `wp-content/uploads/*.php` / dotfiles, static-asset caching,
and a `php-fpm` handler via Unix socket.

### What it does

1. Renders the template with your domain, slug, cert name, and log-name values.
2. Optionally adds apex-to-www redirects (`--redirect-to-www`).
3. Writes `/etc/nginx/conf.d/<domain>.conf`.
4. Warns if the matching SSL snippet or the webroot directory are missing.
5. Validates the full nginx config with `nginx -t`.

### Usage

```bash
sudo ./scripts/nginx/create-site.sh --domain DOMAIN [options]
```

| Flag | Description |
| --- | --- |
| `--domain` | **Required.** Primary domain, e.g. `example.com`. |
| `--slug` | Document-root folder name under `--webroot-base`. Defaults to the first label of the domain (e.g. `example.com` → `example`). |
| `--cert-name` | SSL snippet basename. Resolves to `/etc/nginx/snippets/ssl-<cert-name>.conf`. Defaults to `--domain`. |
| `--log-name` | Log filename basename under `/var/log/nginx/`. Defaults to `--domain`. |
| `--webroot-base` | Base directory for document roots. Defaults to `/mnt/vdc/www/t4a`. |
| `--redirect-to-www` | Redirect apex to `www.DOMAIN` over both HTTP and HTTPS. Requires a cert that covers both names. |
| `--force` | Overwrite an existing `/etc/nginx/conf.d/<domain>.conf`. |

### Examples

Simple apex-only site:

```bash
sudo ./scripts/nginx/create-site.sh --domain the-chase-project.com
```

Apex redirects to www (canonical = `www.example.com`):

```bash
sudo ./scripts/nginx/create-site.sh --domain example.com --redirect-to-www
```

Custom slug and cert name (site lives at `/mnt/vdc/www/t4a/mysite`):

```bash
sudo ./scripts/nginx/create-site.sh \
  --domain example.com \
  --slug mysite \
  --cert-name example.com
```

### What gets generated

Without `--redirect-to-www` — HTTP → HTTPS on the apex, HTTPS site on the apex.

With `--redirect-to-www` — three server blocks:

1. **`:80` apex + www** → `301` to `https://www.DOMAIN`
2. **`:443` apex** → `301` to `https://www.DOMAIN`
3. **`:443 www.DOMAIN`** → serves the WordPress site

---

## `add-user.sh`

Creates a WordPress user in one of the sites hosted on this server. The tricky
part of "just add a row to `wp_users`" is that WordPress password hashing
changed in 6.8 (phpass → bcrypt with phpass fallback), so rolling the hash in
shell is fragile. This script delegates to `wp-cli`, which always does the
right thing for the installed WP version.

### What it does

1. Lists non-system MariaDB databases (or takes `--database`).
2. Finds the matching WordPress install by grepping `DB_NAME` in every
   `wp-config.php` under `--webroot-base` (default `/mnt/vdc/www/t4a`).
3. Detects the webroot owner (`stat` on `wp-config.php`) and runs `wp-cli` as
   that user — `wp-cli` refuses to run as root by default.
4. Prompts for any missing username / email / password, or generates a
   random 24-char password if left blank.
5. Runs `wp user create` with the chosen role (default `administrator`).

### Usage

```bash
# Fully interactive — lists databases, prompts for everything
sudo ./scripts/wordpress/add-user.sh

# CLI args, password auto-generated, skip confirmation
sudo ./scripts/wordpress/add-user.sh \
  --database wp_the_chase_project \
  --user grega \
  --email grega@example.com \
  --yes
```

| Flag | Description |
| --- | --- |
| `--database` | Target database. Interactive picker if omitted. |
| `--user` | WordPress login name. Prompted if omitted. |
| `--email` | WordPress email. Prompted if omitted. |
| `--password` | Password. Prompted (hidden) if omitted; leave prompt blank to auto-generate. |
| `--role` | WordPress role (default `administrator`). |
| `--webroot-base` | Base dir for site webroots (default `/mnt/vdc/www/t4a`). |
| `--yes` / `-y` | Skip the final confirmation prompt. |

The script requires `wp-cli` (`wp` on `$PATH`) and `sudo mysql` access via
unix-socket auth (AlmaLinux/MariaDB default).

---

## Prerequisites (on the server)

- `certbot` with the `certbot-dns-cloudflare` plugin installed.
- Cloudflare API token(s) written to
  `/data/certbot/credentials/cloudflare.ini` and/or `cloudflare-t4a.ini`,
  both `chmod 600`.
- Certbot project directories pre-created:
  `/data/certbot/{config,work,logs}`.
- `nginx` installed with `snippets/` and `conf.d/` directories (standard
  layout), and `php-fpm` listening on `/run/php-fpm/www.sock`.
- A Diffie-Hellman parameter file at `/etc/ssl/certs/dhparam.pem`. Generate
  once with:
  ```bash
  sudo openssl dhparam -out /etc/ssl/certs/dhparam.pem 2048
  ```

The script checks each of these and prints a clear error if something's
missing — no silent failures.

---

## Layout

```
t4a-wordpress-hosting/
├── scripts/
│   ├── nginx/
│   │   ├── create-site.sh
│   │   └── templates/
│   │       └── site.conf.tmpl
│   ├── ssl/
│   │   ├── issue-cert.sh
│   │   └── templates/
│   │       └── ssl-snippet.conf.tmpl
│   └── wordpress/
│       └── add-user.sh
├── .gitattributes
├── .gitignore
└── README.md
```

---

## Development notes

- Shell scripts target `bash` on AlmaLinux; they use `set -euo pipefail` and
  are syntax-checkable with `bash -n`.
- `.gitattributes` forces `LF` line endings for `*.sh`, `*.tmpl`, and
  `*.conf`, so scripts edited on Windows still run correctly on the server.
- The nginx snippet template uses `{{CERT_NAME}}` as its only placeholder —
  substitution happens in-script via `sed`; no templating dependencies.
