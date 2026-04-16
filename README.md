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

More scripts will land here as they're extracted from runbooks.

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

## Prerequisites (on the server)

- `certbot` with the `certbot-dns-cloudflare` plugin installed.
- Cloudflare API token(s) written to
  `/data/certbot/credentials/cloudflare.ini` and/or `cloudflare-t4a.ini`,
  both `chmod 600`.
- Certbot project directories pre-created:
  `/data/certbot/{config,work,logs}`.
- `nginx` installed with a `snippets/` directory (standard layout).
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
│   └── ssl/
│       ├── issue-cert.sh
│       └── templates/
│           └── ssl-snippet.conf.tmpl
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
