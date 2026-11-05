#!/usr/bin/env bash
set -euo pipefail

# Create a WordPress user by talking to MariaDB directly. No filesystem /
# webroot lookups — everything we need (database list, table prefix,
# duplicate-user checks) comes from the DB. PHP is used only to compute a
# WordPress-compatible password hash (portable phpass, the $P$… format
# every WP release accepts).

SYSTEM_DBS_REGEX='^(information_schema|mysql|performance_schema|sys|test)$'

DATABASE=""
WP_USERNAME=""
WP_EMAIL=""
WP_PASSWORD=""
WP_ROLE="administrator"
ASSUME_YES=0

die() { echo "error: $*" >&2; exit 1; }

usage() {
  cat >&2 <<EOF
Usage: sudo $0 [options]

  --database DB       Target database. Interactive picker if omitted.
  --user USERNAME     WordPress login (prompted if omitted).
  --email EMAIL       WordPress email (prompted if omitted).
  --password PASS     Password (prompted hidden if omitted;
                      leave prompt blank to auto-generate 24 chars).
  --role ROLE         administrator | editor | author | contributor | subscriber
                      (default: administrator)
  --yes / -y          Skip the final confirmation prompt.
  -h, --help          Show this help.

Examples:
  # Fully interactive (picks DB from a list, prompts for user/email/password)
  sudo $0

  # All flags, auto-generated password, no confirmation
  sudo $0 --database wp_the_chase_project --user grega \\
    --email grega@example.com --yes
EOF
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --database)    DATABASE="${2:-}";     shift 2 ;;
    --database=*)  DATABASE="${1#*=}";    shift ;;
    --user)        WP_USERNAME="${2:-}";  shift 2 ;;
    --user=*)      WP_USERNAME="${1#*=}"; shift ;;
    --email)       WP_EMAIL="${2:-}";     shift 2 ;;
    --email=*)     WP_EMAIL="${1#*=}";    shift ;;
    --password)    WP_PASSWORD="${2:-}";  shift 2 ;;
    --password=*)  WP_PASSWORD="${1#*=}"; shift ;;
    --role)        WP_ROLE="${2:-}";      shift 2 ;;
    --role=*)      WP_ROLE="${1#*=}";     shift ;;
    --yes|-y)      ASSUME_YES=1;          shift ;;
    -h|--help)     usage ;;
    *)             die "unknown argument: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "must be run as root (use sudo); mariadb uses unix_socket auth"
command -v mysql >/dev/null 2>&1 || die "mysql client not found"
command -v php   >/dev/null 2>&1 || die "php not found (needed for password hashing)"
mysql -e 'SELECT 1' >/dev/null 2>&1 || die "cannot connect to mariadb as root"

# Map role to user_level (legacy numeric level)
case "$WP_ROLE" in
  administrator) USER_LEVEL=10 ;;
  editor)        USER_LEVEL=7  ;;
  author)        USER_LEVEL=2  ;;
  contributor)   USER_LEVEL=1  ;;
  subscriber)    USER_LEVEL=0  ;;
  *)             die "unknown role: $WP_ROLE (must be administrator|editor|author|contributor|subscriber)" ;;
esac

# ---------- Pick database ----------
list_databases() {
  mysql -N -B -e 'SHOW DATABASES' | grep -Ev "$SYSTEM_DBS_REGEX" || true
}

if [[ -z "$DATABASE" ]]; then
  mapfile -t dbs < <(list_databases)
  (( ${#dbs[@]} > 0 )) || die "no user databases found"
  echo "Available databases:" >&2
  i=1
  for db in "${dbs[@]}"; do printf "  %2d) %s\n" "$i" "$db" >&2; ((i++)); done
  read -r -p "Choose [1-${#dbs[@]}]: " choice
  [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#dbs[@]} )) \
    || die "invalid choice: $choice"
  DATABASE="${dbs[$((choice-1))]}"
fi

mysql -N -B -e "SHOW DATABASES LIKE '$(printf '%s' "$DATABASE" | sed "s/'/''/g")'" \
  | grep -qx "$DATABASE" || die "database not found: $DATABASE"

# ---------- Detect table prefix ----------
# Find a table that ends in '_users' and also has a sibling '_usermeta'.
# Works for standard single-site installs; for multisite the main-site prefix
# is picked. Escape the '_' wildcard in SHOW TABLES LIKE.
mapfile -t user_tables < <(mysql -N -B -e "SHOW TABLES FROM \`$DATABASE\` LIKE '%\\_users'")
(( ${#user_tables[@]} > 0 )) || die "no '*_users' table found in $DATABASE — is this a WordPress DB?"

PREFIX=""
for t in "${user_tables[@]}"; do
  p="${t%users}"    # strip trailing 'users' → 'tgnh_'
  # confirm there's a matching *_usermeta
  if mysql -N -B -e "SHOW TABLES FROM \`$DATABASE\` LIKE '${p}usermeta'" | grep -qx "${p}usermeta"; then
    PREFIX="$p"; break
  fi
done
[[ -n "$PREFIX" ]] || die "no prefix pair *_users + *_usermeta found in $DATABASE"
[[ "$PREFIX" =~ ^[A-Za-z0-9_]+_$ ]] || die "suspicious prefix detected: '$PREFIX' (bailing for safety)"

echo ">> database: $DATABASE"
echo ">> prefix:   $PREFIX"
echo ">> role:     $WP_ROLE (user_level=$USER_LEVEL)"

# ---------- Collect user / email / password ----------
if [[ -z "$WP_USERNAME" ]]; then read -r -p "WordPress username: " WP_USERNAME; fi
[[ -n "$WP_USERNAME" ]] || die "username is required"
[[ "$WP_USERNAME" =~ ^[A-Za-z0-9._@-]{1,60}$ ]] || die "invalid username (allowed: letters, digits, . _ @ -; max 60)"

if [[ -z "$WP_EMAIL" ]]; then read -r -p "Email: " WP_EMAIL; fi
[[ "$WP_EMAIL" == *@*.* ]] || die "invalid email: $WP_EMAIL"

if [[ -z "$WP_PASSWORD" ]]; then
  read -r -s -p "Password (blank = auto-generate): " WP_PASSWORD
  echo
fi
if [[ -z "$WP_PASSWORD" ]]; then
  WP_PASSWORD="$(openssl rand -base64 24 | tr -d '+/=\n' | head -c 24)"
  echo ">> generated password: $WP_PASSWORD"
fi

# ---------- Duplicate check ----------
sql_quote() { printf '%s' "$1" | sed "s/'/''/g"; }

existing=$(mysql -N -B -e "SELECT COUNT(*) FROM \`$DATABASE\`.\`${PREFIX}users\` WHERE user_login='$(sql_quote "$WP_USERNAME")' OR user_email='$(sql_quote "$WP_EMAIL")'")
(( existing == 0 )) || die "a user with this login or email already exists in ${PREFIX}users"

# ---------- Hash password via PHP (portable phpass, $P$...) ----------
export WP_PASS_TO_HASH="$WP_PASSWORD"
WP_HASH=$(php <<'PHP'
<?php
// Portable phpass (WordPress-compatible). Produces a $P$… hash that every
// modern WP release accepts, including 6.8+ which transparently re-hashes
// on next successful login.
class Phpass {
    public $itoa64 = './0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
    public $iteration_count_log2 = 8;

    public function encode64($input, $count) {
        $output = '';
        $i = 0;
        do {
            $value = ord($input[$i++]);
            $output .= $this->itoa64[$value & 0x3f];
            if ($i < $count) $value |= ord($input[$i]) << 8;
            $output .= $this->itoa64[($value >> 6) & 0x3f];
            if ($i++ >= $count) break;
            if ($i < $count) $value |= ord($input[$i]) << 16;
            $output .= $this->itoa64[($value >> 12) & 0x3f];
            if ($i++ >= $count) break;
            $output .= $this->itoa64[($value >> 18) & 0x3f];
        } while ($i < $count);
        return $output;
    }

    public function gensalt($input) {
        $out  = '$P$';
        $out .= $this->itoa64[min($this->iteration_count_log2 + 5, 30)];
        $out .= $this->encode64($input, 6);
        return $out;
    }

    public function hash($password) {
        $salt = $this->gensalt(random_bytes(6));
        $count_log2 = strpos($this->itoa64, $salt[3]);
        $count = 1 << $count_log2;
        $s = substr($salt, 4, 8);
        $h = md5($s . $password, true);
        do { $h = md5($h . $password, true); } while (--$count);
        return substr($salt, 0, 12) . $this->encode64($h, 16);
    }
}
$pw = getenv('WP_PASS_TO_HASH');
if ($pw === false || $pw === '') { fwrite(STDERR, "empty password\n"); exit(1); }
echo (new Phpass)->hash($pw);
PHP
)
unset WP_PASS_TO_HASH
[[ "$WP_HASH" =~ ^\$P\$ ]] || die "password hashing failed"

# ---------- Serialize the capabilities value ----------
# PHP serialization of array($role => true):
#   a:1:{s:<bytelen>:"<role>";b:1;}
role_bytes=$(printf '%s' "$WP_ROLE" | wc -c)
CAPS=$(printf 'a:1:{s:%d:"%s";b:1;}' "$role_bytes" "$WP_ROLE")

# user_nicename: lowercase, non-alphanum → '-'
WP_NICENAME=$(printf '%s' "$WP_USERNAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')

# ---------- Confirm ----------
if [[ $ASSUME_YES -ne 1 ]]; then
  cat <<EOF

About to create WordPress user:
    database:  $DATABASE
    prefix:    $PREFIX
    username:  $WP_USERNAME
    nicename:  $WP_NICENAME
    email:     $WP_EMAIL
    role:      $WP_ROLE  (user_level=$USER_LEVEL)
EOF
  read -r -p "Proceed? [y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || die "aborted"
fi

# ---------- Insert ----------
Q_USER=$(sql_quote "$WP_USERNAME")
Q_HASH=$(sql_quote "$WP_HASH")
Q_NICE=$(sql_quote "$WP_NICENAME")
Q_MAIL=$(sql_quote "$WP_EMAIL")
Q_CAPS=$(sql_quote "$CAPS")

mysql "$DATABASE" <<SQL
START TRANSACTION;

INSERT INTO \`${PREFIX}users\`
  (user_login, user_pass, user_nicename, user_email, user_url, user_registered, user_activation_key, user_status, display_name)
VALUES
  ('$Q_USER', '$Q_HASH', '$Q_NICE', '$Q_MAIL', '', NOW(), '', 0, '$Q_USER');

SET @uid := LAST_INSERT_ID();

INSERT INTO \`${PREFIX}usermeta\` (user_id, meta_key, meta_value) VALUES
  (@uid, '${PREFIX}capabilities', '$Q_CAPS'),
  (@uid, '${PREFIX}user_level',   '$USER_LEVEL'),
  (@uid, 'nickname',              '$Q_USER'),
  (@uid, 'rich_editing',          'true'),
  (@uid, 'syntax_highlighting',   'true'),
  (@uid, 'admin_color',           'fresh'),
  (@uid, 'show_admin_bar_front',  'true');

COMMIT;
SQL

NEW_UID=$(mysql -N -B -e "SELECT ID FROM \`$DATABASE\`.\`${PREFIX}users\` WHERE user_login='$Q_USER'")

cat <<EOF

Done. Created user ID $NEW_UID.

    Username: $WP_USERNAME
    Password: $WP_PASSWORD
    Role:     $WP_ROLE

Login at /wp-login.php on the matching site. WordPress will silently
re-hash the password to its current preferred algorithm the first time
you sign in.
EOF
