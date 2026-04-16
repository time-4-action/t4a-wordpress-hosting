#!/usr/bin/env bash
set -euo pipefail

# Issue a Let's Encrypt cert via certbot + Cloudflare DNS and write a matching
# nginx SSL snippet. See ../../README or the repo plan for context.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/templates/ssl-snippet.conf.tmpl"

CERTBOT_CONFIG_DIR="/data/certbot/config"
CERTBOT_WORK_DIR="/data/certbot/work"
CERTBOT_LOGS_DIR="/data/certbot/logs"
CREDS_DIR="/data/certbot/credentials"
CREDS_ETIAM="${CREDS_DIR}/cloudflare.ini"
CREDS_T4A="${CREDS_DIR}/cloudflare-t4a.ini"
SNIPPETS_DIR="/etc/nginx/snippets"
DHPARAM_PATH="/etc/ssl/certs/dhparam.pem"

ACCOUNT=""
CERT_NAME=""
FORCE=0
DOMAINS=()

die() { echo "error: $*" >&2; exit 1; }

usage() {
  cat >&2 <<EOF
Usage: sudo $0 --account t4a|etiam [--cert-name NAME] [--force] -d <domain> [-d <domain> ...]

  --account      Cloudflare account to use: 't4a' or 'etiam' (prompted if omitted)
  --cert-name    Cert name / live dir name (defaults to first -d, with leading '*.' stripped)
  --force        Overwrite an existing /etc/nginx/snippets/ssl-<cert-name>.conf
  -d <domain>    Domain(s) for the cert; may be repeated. Wildcards allowed.
EOF
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --account)    ACCOUNT="${2:-}";    shift 2 ;;
    --account=*)  ACCOUNT="${1#*=}";   shift ;;
    --cert-name)  CERT_NAME="${2:-}";  shift 2 ;;
    --cert-name=*) CERT_NAME="${1#*=}"; shift ;;
    --force)      FORCE=1;             shift ;;
    -d)           DOMAINS+=("${2:-}"); shift 2 ;;
    -d=*)         DOMAINS+=("${1#*=}"); shift ;;
    -h|--help)    usage ;;
    *)            die "unknown argument: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "must be run as root (use sudo); need to read credentials and write $SNIPPETS_DIR"
(( ${#DOMAINS[@]} > 0 )) || { echo "error: at least one -d <domain> is required" >&2; usage; }
[[ -f "$TEMPLATE" ]] || die "template not found: $TEMPLATE"

if [[ -z "$ACCOUNT" ]]; then
  echo "Select Cloudflare account:"
  echo "  [1] etiam.si        (${CREDS_ETIAM})"
  echo "  [2] t4a             (${CREDS_T4A})"
  read -r -p "Choice [1-2]: " choice
  case "$choice" in
    1) ACCOUNT="etiam" ;;
    2) ACCOUNT="t4a" ;;
    *) die "invalid choice: $choice" ;;
  esac
fi

case "$ACCOUNT" in
  etiam) CREDS="$CREDS_ETIAM" ;;
  t4a)   CREDS="$CREDS_T4A" ;;
  *)     die "--account must be 't4a' or 'etiam' (got: $ACCOUNT)" ;;
esac

[[ -f "$CREDS" ]] || die "credentials file not found: $CREDS"
perms=$(stat -c '%a' "$CREDS")
[[ "$perms" == "600" ]] || die "credentials file $CREDS has permissions $perms, expected 600 (chmod 600 $CREDS)"

if [[ -z "$CERT_NAME" ]]; then
  CERT_NAME="${DOMAINS[0]#\*.}"
fi

SNIPPET_PATH="${SNIPPETS_DIR}/ssl-${CERT_NAME}.conf"
if [[ -e "$SNIPPET_PATH" && $FORCE -ne 1 ]]; then
  die "snippet already exists: $SNIPPET_PATH (use --force to overwrite)"
fi

[[ -d "$SNIPPETS_DIR" ]] || die "nginx snippets dir not found: $SNIPPETS_DIR"

if [[ ! -f "$DHPARAM_PATH" ]]; then
  die "dhparam file not found: $DHPARAM_PATH
generate it once with: openssl dhparam -out $DHPARAM_PATH 2048
(then re-run this script)"
fi

echo ">> issuing cert '$CERT_NAME' via account '$ACCOUNT'"
echo "   domains: ${DOMAINS[*]}"

cmd=(
  certbot certonly --dns-cloudflare
  --dns-cloudflare-credentials "$CREDS"
  --config-dir "$CERTBOT_CONFIG_DIR"
  --work-dir   "$CERTBOT_WORK_DIR"
  --logs-dir   "$CERTBOT_LOGS_DIR"
  --cert-name  "$CERT_NAME"
  --non-interactive --agree-tos
)
for d in "${DOMAINS[@]}"; do
  cmd+=(-d "$d")
done
"${cmd[@]}"

echo ">> writing snippet: $SNIPPET_PATH"
# Escape '&' and '|' and '/' in CERT_NAME for sed replacement safety. Cert names
# are DNS-label-like so this is belt-and-braces.
escaped=$(printf '%s' "$CERT_NAME" | sed -e 's/[\/&|]/\\&/g')
sed "s|{{CERT_NAME}}|${escaped}|g" "$TEMPLATE" > "$SNIPPET_PATH"
chmod 644 "$SNIPPET_PATH"

echo ">> running nginx -t"
if ! nginx -t; then
  echo "nginx -t failed; snippet left at $SNIPPET_PATH for inspection" >&2
  exit 1
fi

cat <<EOF

Done.

Include the snippet in your server block:
    include snippets/ssl-${CERT_NAME}.conf;

Then reload nginx:
    systemctl reload nginx
EOF
