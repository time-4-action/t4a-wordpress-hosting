#!/usr/bin/env bash
set -euo pipefail

# Generate an nginx server-block config for a WordPress site on t4a-instance
# from scripts/nginx/templates/site.conf.tmpl. Writes to
# /etc/nginx/conf.d/<domain>.conf and runs nginx -t.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/templates/site.conf.tmpl"

NGINX_CONFD="/etc/nginx/conf.d"
NGINX_SNIPPETS="/etc/nginx/snippets"
DEFAULT_WEBROOT_BASE="/mnt/vdc/www/t4a"

DOMAIN=""
SLUG=""
CERT_NAME=""
LOG_NAME=""
WEBROOT_BASE="$DEFAULT_WEBROOT_BASE"
REDIRECT_TO_WWW=0
FORCE=0

die() { echo "error: $*" >&2; exit 1; }

usage() {
  cat >&2 <<EOF
Usage: sudo $0 --domain DOMAIN [options]

  --domain DOMAIN         Primary domain, e.g. example.com (required)
  --slug SLUG             Document-root folder name under --webroot-base
                          (default: DOMAIN with dots collapsed; e.g. example.com -> example)
  --cert-name NAME        SSL snippet basename (default: DOMAIN). Resolves to
                          /etc/nginx/snippets/ssl-<cert-name>.conf
  --log-name NAME         Log file basename (default: DOMAIN). Resolves to
                          /var/log/nginx/<log-name>.{access,error}.log
  --webroot-base PATH     Base directory for document roots
                          (default: $DEFAULT_WEBROOT_BASE)
  --redirect-to-www       Redirect apex (DOMAIN) to www.DOMAIN, both HTTP and HTTPS.
                          Requires a cert that covers both apex and www.
  --force                 Overwrite existing /etc/nginx/conf.d/<DOMAIN>.conf
  -h, --help              Show this help

Examples:
  sudo $0 --domain example.com
  sudo $0 --domain example.com --redirect-to-www
  sudo $0 --domain example.com --slug mysite --cert-name example.com
EOF
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)         DOMAIN="${2:-}";       shift 2 ;;
    --domain=*)       DOMAIN="${1#*=}";      shift ;;
    --slug)           SLUG="${2:-}";         shift 2 ;;
    --slug=*)         SLUG="${1#*=}";        shift ;;
    --cert-name)      CERT_NAME="${2:-}";    shift 2 ;;
    --cert-name=*)    CERT_NAME="${1#*=}";   shift ;;
    --log-name)       LOG_NAME="${2:-}";     shift 2 ;;
    --log-name=*)     LOG_NAME="${1#*=}";    shift ;;
    --webroot-base)   WEBROOT_BASE="${2:-}"; shift 2 ;;
    --webroot-base=*) WEBROOT_BASE="${1#*=}"; shift ;;
    --redirect-to-www) REDIRECT_TO_WWW=1;    shift ;;
    --force)          FORCE=1;               shift ;;
    -h|--help)        usage ;;
    *)                die "unknown argument: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "must be run as root (use sudo); need to write to $NGINX_CONFD"
[[ -n "$DOMAIN" ]] || { echo "error: --domain is required" >&2; usage; }
[[ -f "$TEMPLATE" ]] || die "template not found: $TEMPLATE"
[[ -d "$NGINX_CONFD" ]] || die "nginx conf.d dir not found: $NGINX_CONFD"

# Defaults derived from --domain
[[ -n "$SLUG" ]]      || SLUG="${DOMAIN%%.*}"
[[ -n "$CERT_NAME" ]] || CERT_NAME="$DOMAIN"
[[ -n "$LOG_NAME" ]]  || LOG_NAME="$DOMAIN"

CONF_PATH="${NGINX_CONFD}/${DOMAIN}.conf"
SNIPPET_PATH="${NGINX_SNIPPETS}/ssl-${CERT_NAME}.conf"
WEBROOT_PATH="${WEBROOT_BASE}/${SLUG}"

if [[ -e "$CONF_PATH" && $FORCE -ne 1 ]]; then
  die "config already exists: $CONF_PATH (use --force to overwrite)"
fi

if [[ ! -f "$SNIPPET_PATH" ]]; then
  echo "warning: SSL snippet not found: $SNIPPET_PATH" >&2
  echo "         issue the cert first with scripts/ssl/issue-cert.sh — nginx -t will fail until it exists." >&2
fi

if [[ ! -d "$WEBROOT_PATH" ]]; then
  echo "warning: webroot does not exist: $WEBROOT_PATH" >&2
  echo "         create it and drop WordPress in place before enabling this site." >&2
fi

# Compute template vars for redirect mode
if [[ $REDIRECT_TO_WWW -eq 1 ]]; then
  HTTP_NAMES="${DOMAIN} www.${DOMAIN}"
  CANONICAL="www.${DOMAIN}"
  echo "note: --redirect-to-www enabled; the cert at $SNIPPET_PATH must cover both '$DOMAIN' and 'www.$DOMAIN'." >&2
else
  HTTP_NAMES="${DOMAIN}"
  CANONICAL="${DOMAIN}"
fi

echo ">> generating $CONF_PATH"
echo "   domain=$DOMAIN canonical=$CANONICAL slug=$SLUG cert-name=$CERT_NAME redirect-to-www=$REDIRECT_TO_WWW"

# Escape sed replacement metacharacters in values.
esc() { printf '%s' "$1" | sed -e 's/[\/&|]/\\&/g'; }

render() {
  local content
  content=$(cat "$TEMPLATE")

  if [[ $REDIRECT_TO_WWW -eq 1 ]]; then
    # keep the wrapped block; just strip the marker lines
    content=$(printf '%s\n' "$content" | sed -e '/{{WWW_REDIRECT_START}}/d' -e '/{{WWW_REDIRECT_END}}/d')
  else
    # drop everything between markers, inclusive
    content=$(printf '%s\n' "$content" | sed -e '/{{WWW_REDIRECT_START}}/,/{{WWW_REDIRECT_END}}/d')
  fi

  printf '%s\n' "$content" | sed \
    -e "s|{{HTTP_NAMES}}|$(esc "$HTTP_NAMES")|g" \
    -e "s|{{CANONICAL}}|$(esc "$CANONICAL")|g" \
    -e "s|{{DOMAIN}}|$(esc "$DOMAIN")|g" \
    -e "s|{{CERT_NAME}}|$(esc "$CERT_NAME")|g" \
    -e "s|{{SLUG}}|$(esc "$SLUG")|g" \
    -e "s|{{WEBROOT_BASE}}|$(esc "$WEBROOT_BASE")|g" \
    -e "s|{{LOG_NAME}}|$(esc "$LOG_NAME")|g"
}

render > "$CONF_PATH"
chmod 644 "$CONF_PATH"

echo ">> running nginx -t"
if ! nginx -t; then
  echo "nginx -t failed; config left at $CONF_PATH for inspection" >&2
  exit 1
fi

cat <<EOF

Done.

Created:
    $CONF_PATH  -> serves ${CANONICAL} from ${WEBROOT_PATH}

Next steps:
    sudo systemctl reload nginx

If you haven't yet, also:
  - ensure webroot exists:   mkdir -p ${WEBROOT_PATH}
  - place WordPress files in ${WEBROOT_PATH}
  - make sure DNS for ${HTTP_NAMES} points at this server
EOF
