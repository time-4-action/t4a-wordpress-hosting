#!/usr/bin/env bash
set -euo pipefail

# Create a WordPress user for one of the sites on this server.
#
# Picks a database (interactive by default), locates the matching WordPress
# install by grepping DB_NAME across wp-config.php files under --webroot-base,
# then creates the user via wp-cli. wp-cli handles password hashing + all
# usermeta rows correctly; running against the DB directly would mean
# re-implementing WP's phpass/bcrypt migration, which is fragile.

DEFAULT_WEBROOT_BASE="/mnt/vdc/www/t4a"
SYSTEM_DBS_REGEX='^(information_schema|mysql|performance_schema|sys|test)$'

DATABASE=""
WP_USERNAME=""
WP_EMAIL=""
WP_PASSWORD=""
WP_ROLE="administrator"
WEBROOT_BASE="$DEFAULT_WEBROOT_BASE"
ASSUME_YES=0

die() { echo "error: $*" >&2; exit 1; }

usage() {
  cat >&2 <<EOF
Usage: sudo $0 [options]

  --database DB          Target database. If omitted, script lists available
                         databases and prompts.
  --user USERNAME        WordPress login (prompted if omitted).
  --email EMAIL          WordPress email (prompted if omitted).
  --password PASS        Password (prompted if omitted; leave blank at prompt
                         to generate a random 24-char password).
  --role ROLE            WordPress role (default: administrator).
  --webroot-base PATH    Base dir for site webroots (default: $DEFAULT_WEBROOT_BASE).
  --yes                  Skip the final confirmation prompt.
  -h, --help             Show this help.

Examples:
  # fully interactive (lists databases, prompts for everything)
  sudo $0

  # CLI args, auto-generated password, no confirmation
  sudo $0 --database wp_the_chase_project --user grega \\
    --email grega@example.com --yes
EOF
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --database)       DATABASE="${2:-}";     shift 2 ;;
    --database=*)     DATABASE="${1#*=}";    shift ;;
    --user)           WP_USERNAME="${2:-}";  shift 2 ;;
    --user=*)         WP_USERNAME="${1#*=}"; shift ;;
    --email)          WP_EMAIL="${2:-}";     shift 2 ;;
    --email=*)        WP_EMAIL="${1#*=}";    shift ;;
    --password)       WP_PASSWORD="${2:-}";  shift 2 ;;
    --password=*)     WP_PASSWORD="${1#*=}"; shift ;;
    --role)           WP_ROLE="${2:-}";      shift 2 ;;
    --role=*)         WP_ROLE="${1#*=}";     shift ;;
    --webroot-base)   WEBROOT_BASE="${2:-}"; shift 2 ;;
    --webroot-base=*) WEBROOT_BASE="${1#*=}"; shift ;;
    --yes|-y)         ASSUME_YES=1;          shift ;;
    -h|--help)        usage ;;
    *)                die "unknown argument: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "must be run as root (use sudo); needs mysql access and to sudo to the webroot owner"
command -v wp >/dev/null 2>&1 || die "wp-cli not found. Install it: https://wp-cli.org/#installing"
command -v mysql >/dev/null 2>&1 || die "mysql client not found"
[[ -d "$WEBROOT_BASE" ]] || die "webroot base does not exist: $WEBROOT_BASE"

mysql -e 'SELECT 1' >/dev/null 2>&1 || die "cannot connect to mysql as root (expected unix_socket auth). Try: sudo mysql"

list_databases() {
  mysql -N -B -e 'SHOW DATABASES' | grep -Ev "$SYSTEM_DBS_REGEX" || true
}

pick_database() {
  local -a dbs
  mapfile -t dbs < <(list_databases)
  (( ${#dbs[@]} > 0 )) || die "no user databases found"

  echo "Available databases:" >&2
  local i=1
  for db in "${dbs[@]}"; do
    printf "  %2d) %s\n" "$i" "$db" >&2
    ((i++))
  done
  local choice
  read -r -p "Choose [1-${#dbs[@]}]: " choice
  [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#dbs[@]} )) \
    || die "invalid choice: $choice"
  DATABASE="${dbs[$((choice-1))]}"
}

if [[ -z "$DATABASE" ]]; then
  pick_database
fi

# Verify the DB exists
mysql -N -B -e "SHOW DATABASES LIKE '$DATABASE'" | grep -qx "$DATABASE" \
  || die "database not found: $DATABASE"

# Find webroot by grepping wp-config.php for DB_NAME
find_webroot() {
  local match
  # Use python-safe-ish grep; wp-config.php uses define('DB_NAME', '...')
  # with various quote styles. Match the DB name as a word between quotes.
  match=$(grep -lE "define\([[:space:]]*['\"]DB_NAME['\"][[:space:]]*,[[:space:]]*['\"]${DATABASE}['\"]" \
    "$WEBROOT_BASE"/*/wp-config.php 2>/dev/null || true)
  if [[ -z "$match" ]]; then
    die "no wp-config.php under $WEBROOT_BASE references DB_NAME='$DATABASE'"
  fi
  local count
  count=$(printf '%s\n' "$match" | wc -l)
  if (( count > 1 )); then
    echo "error: multiple wp-config.php files reference DB_NAME='$DATABASE':" >&2
    printf '%s\n' "$match" >&2
    exit 1
  fi
  WEBROOT="$(dirname "$match")"
}

find_webroot
echo ">> database: $DATABASE"
echo ">> webroot:  $WEBROOT"

# Determine file owner to run wp-cli as (wp-cli refuses to run as root by default)
WP_OWNER="$(stat -c '%U' "$WEBROOT/wp-config.php")"
[[ "$WP_OWNER" == "UNKNOWN" || -z "$WP_OWNER" ]] && die "could not determine owner of $WEBROOT/wp-config.php"
echo ">> run-as:   $WP_OWNER"

# Collect user / email / password interactively if not provided
if [[ -z "$WP_USERNAME" ]]; then
  read -r -p "WordPress username: " WP_USERNAME
fi
[[ -n "$WP_USERNAME" ]] || die "username is required"

if [[ -z "$WP_EMAIL" ]]; then
  read -r -p "Email: " WP_EMAIL
fi
[[ "$WP_EMAIL" == *@*.* ]] || die "invalid email: $WP_EMAIL"

if [[ -z "$WP_PASSWORD" ]]; then
  read -r -s -p "Password (blank = auto-generate): " WP_PASSWORD
  echo
fi
if [[ -z "$WP_PASSWORD" ]]; then
  WP_PASSWORD="$(openssl rand -base64 24 | tr -d '+/=\n' | head -c 24)"
  echo ">> generated password: $WP_PASSWORD"
fi

# Confirm
if [[ $ASSUME_YES -ne 1 ]]; then
  cat <<EOF

About to create WordPress user:
    username: $WP_USERNAME
    email:    $WP_EMAIL
    role:     $WP_ROLE
    database: $DATABASE
    webroot:  $WEBROOT
    run-as:   $WP_OWNER
EOF
  read -r -p "Proceed? [y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || die "aborted"
fi

# Create the user via wp-cli
sudo -u "$WP_OWNER" -- wp user create \
  "$WP_USERNAME" "$WP_EMAIL" \
  --role="$WP_ROLE" \
  --user_pass="$WP_PASSWORD" \
  --path="$WEBROOT"

cat <<EOF

Done.

Login URL:  (one of the site's hostnames)/wp-login.php
Username:   $WP_USERNAME
Password:   $WP_PASSWORD

Verify with:
    sudo -u $WP_OWNER wp user list --path=$WEBROOT
EOF
