#!/usr/bin/env bash
#
# wp-site.sh - manage the WordPress sites on this VPS (part of the prawner project)
#
#   wp-site.sh list
#   wp-site.sh create <domain> [--owner user] [--no-www] [--admin-email mail]
#   wp-site.sh cert   <domain> [--no-www]
#   wp-site.sh remove <domain>
#
# Conventions honoured (the same ones used by the existing sites):
#   docroot         /var/www/<domain>/wordpress/
#   vhost           /etc/nginx/sites-available/<slug>   (no extension)
#   enable          symlink in /etc/nginx/sites-enabled/
#   php             unix:/run/php/php8.1-fpm.sock  (pool www-data)
#   tls             certbot --nginx, which rewrites the vhost adding the :443
#
set -uo pipefail

NGINX_AVAIL="${NGINX_AVAIL:-/etc/nginx/sites-available}"
NGINX_ENABLED="${NGINX_ENABLED:-/etc/nginx/sites-enabled}"
WWW_ROOT="${WWW_ROOT:-/var/www}"
PHP_SOCK="${PHP_SOCK:-/run/php/php8.1-fpm.sock}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/wp-site}"
WP_CLI_CACHE_ROOT="${WP_CLI_CACHE_ROOT:-/var/cache/wp-cli}"
DEFAULT_OWNER="${DEFAULT_OWNER:-www-data}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
WP_LOCALE="${WP_LOCALE:-it_IT}"

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'

die()  { printf '%s[ERROR]%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }
warn() { printf '%s[!]%s %s\n' "$c_yel" "$c_off" "$*" >&2; }
ok()   { printf '%s[ok]%s %s\n' "$c_grn" "$c_off" "$*"; }
info() { printf '  %s\n' "$*"; }

[[ $EUID -eq 0 ]] || die "root required"

# --------------------------------------------------------------- helpers

slugify()  { echo "$1" | sed 's/^www\.//; s/\.[a-z]*$//; s/[^a-zA-Z0-9]/_/g'; }
dbnameify() {
  # DB/user name: max 32 characters, only [a-z0-9_], hash suffix if truncated
  local base h
  base=$(echo "$1" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9]/_/g')
  if [[ ${#base} -le 28 ]]; then
    echo "wp_$base"
  else
    h=$(echo -n "$1" | md5sum | cut -c1-6)
    echo "wp_${base:0:21}_$h"
  fi
}

wp_as() {
  local owner="$1" path="$2"; shift 2
  local cache="$WP_CLI_CACHE_ROOT/$owner"
  install -d -o "$owner" -m 0755 "$cache" 2>/dev/null || true
  if [[ "$owner" == "root" ]]; then
    env WP_CLI_CACHE_DIR="$cache" wp --path="$path" --allow-root "$@"
  else
    sudo -u "$owner" env WP_CLI_CACHE_DIR="$cache" HOME=/tmp wp --path="$path" "$@"
  fi
}

find_vhost() {
  # returns the vhost file that contains this server_name
  local domain="$1" f
  for f in "$NGINX_AVAIL"/*; do
    [[ -f "$f" ]] || continue
    if grep -qE "^\s*server_name\s+.*\b${domain//./\\.}\b" "$f"; then
      echo "$f"; return 0
    fi
  done
  return 1
}

server_ip() { curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}'; }

# --------------------------------------------------------------- list

cmd_list() {
  printf '%-28s %-42s %-13s %-8s %s\n' DOMAIN DOCROOT OWNER ENABLED TLS
  printf '%s\n' "$(printf '%.0s-' {1..110})"

  local f names root domain slug enabled owner tls
  for f in "$NGINX_AVAIL"/*; do
    [[ -f "$f" ]] || continue
    slug=$(basename "$f")

    names=$(grep -hoP '^\s*server_name\s+\K[^;]+' "$f" | head -1 | xargs)
    root=$(grep -hoP '^\s*root\s+\K[^;]+' "$f" | grep -v /usr/share/nginx | head -1 | sed 's:/*$::')
    [[ -z "$names" ]] && continue

    # main domain = the first non-www one
    domain=$(echo "$names" | tr ' ' '\n' | grep -v '^www\.' | head -1)
    [[ -z "$domain" ]] && domain=$(echo "$names" | awk '{print $1}')

    if [[ -L "$NGINX_ENABLED/$slug" ]]; then enabled="${c_grn}yes${c_off}"; else enabled="${c_red}no${c_off}"; fi

    if [[ -n "$root" && -d "$root" ]]; then owner=$(stat -c %U "$root"); else owner="${c_dim}-${c_off}"; fi

    if [[ -f "/etc/letsencrypt/live/$domain/cert.pem" ]]; then
      local end days
      end=$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/$domain/cert.pem" | cut -d= -f2)
      days=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
      if   [[ $days -lt 0  ]]; then tls="${c_red}EXPIRED${c_off}"
      elif [[ $days -lt 15 ]]; then tls="${c_yel}${days}d${c_off}"
      else                          tls="${c_grn}${days}d${c_off}"; fi
    else
      tls="${c_dim}none${c_off}"
    fi

    printf '%-28s %-42s %-13b %-17b %b\n' "$domain" "${root:--}" "$owner" "$enabled" "$tls"
  done

  echo
  # orphaned vhosts and docroots without a vhost
  local d
  for d in "$WWW_ROOT"/*/; do
    d=$(basename "$d")
    [[ "$d" == "html" ]] && continue
    if ! find_vhost "$d" >/dev/null 2>&1; then
      warn "docroot without a vhost: $WWW_ROOT/$d"
    fi
  done
}

# --------------------------------------------------------------- create

write_vhost() {
  local domain="$1" slug="$2" docroot="$3" with_www="$4"
  local names="$domain"
  [[ "$with_www" == "1" ]] && names="$domain www.$domain"

  cat > "$NGINX_AVAIL/$slug" <<NGINX
server {
    listen 80;
    listen [::]:80;

    root $docroot;
    index index.php index.html;
    server_name $names;

    error_log  /var/log/nginx/wordpress_${domain}.error;
    access_log /var/log/nginx/wordpress_${domain}.access;

    client_max_body_size 20M;

    location / {
        try_files \$uri \$uri/ /index.php;
    }

    location ~ ^/wp-json/ {
        rewrite ^/wp-json/(.*?)\$ /?rest_route=/\$1 last;
    }

    location ~* /wp-sitemap.*\.xml {
        try_files \$uri \$uri/ /index.php\$is_args\$args;
    }

    location ~ \.php\$ {
        fastcgi_pass unix:$PHP_SOCK;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        include snippets/fastcgi-php.conf;
    }

    error_page 404 /404.html;
    error_page 500 502 503 504 /50x.html;
    location = /50x.html { root /usr/share/nginx/html; }

    gzip on;
    gzip_vary on;
    gzip_min_length 1000;
    gzip_comp_level 5;
    gzip_proxied any;
    gzip_types application/json text/css application/x-javascript application/javascript image/svg+xml;

    location ~* \.(jpg|jpeg|gif|png|webp|svg|woff|woff2|ttf|css|js|ico|xml)\$ {
        access_log off;
        log_not_found off;
        expires 360d;
    }

    # --- hardening ---------------------------------------------------
    # no executable PHP inside uploads: it is the most common way in
    # after a malicious file has been uploaded
    location ~* ^/wp-content/uploads/.*\.php\$ { deny all; }

    location = /wp-config.php { deny all; }
    location = /xmlrpc.php    { deny all; access_log off; log_not_found off; }
    location ~ /\.            { deny all; access_log off; log_not_found off; }
    location ~* ^/(readme|license)\.(html|txt)\$ { deny all; }
}
NGINX
}

cmd_create() {
  local domain="" owner="$DEFAULT_OWNER" with_www=1 admin_email="$ADMIN_EMAIL"

  domain="$1"; shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --owner)       owner="$2"; shift 2 ;;
      --no-www)      with_www=0; shift ;;
      --admin-email) admin_email="$2"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done

  [[ "$domain" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
    || die "invalid domain: $domain"
  [[ -z "$admin_email" ]] && die "--admin-email is required (or the ADMIN_EMAIL variable)"

  local slug docroot dbname dbuser dbpass adminpass
  slug=$(slugify "$domain")
  docroot="$WWW_ROOT/$domain/wordpress"
  dbname=$(dbnameify "$domain")
  dbuser="$dbname"

  [[ -e "$NGINX_AVAIL/$slug" ]] && die "vhost already exists: $NGINX_AVAIL/$slug"
  [[ -e "$docroot" ]] && die "docroot already exists: $docroot"

  # --- DNS preflight: certbot will fail without it, better to know now
  local ip resolved
  ip=$(server_ip)
  resolved=$(getent ahostsv4 "$domain" | awk '{print $1}' | head -1)
  if [[ "$resolved" != "$ip" ]]; then
    warn "DNS: $domain resolves to '${resolved:-nothing}' but the server is $ip"
    warn "the site will be created anyway, but 'wp-site.sh cert $domain' will fail"
    read -rp "  continue? [y/N] " a; [[ "$a" =~ ^[yY]$ ]] || exit 1
  fi

  # --- owner user
  if ! id -u "$owner" >/dev/null 2>&1; then
    info "creating the system user $owner"
    useradd -M -d "$WWW_ROOT/$domain" -s /usr/sbin/nologin -g www-data "$owner" \
      || die "useradd failed"
  fi

  dbpass=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)
  adminpass=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-20)

  # --- database
  info "creating the database $dbname"
  mysql <<SQL || die "DB creation failed"
CREATE DATABASE \`$dbname\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '$dbuser'@'localhost' IDENTIFIED BY '$dbpass';
GRANT ALL PRIVILEGES ON \`$dbname\`.* TO '$dbuser'@'localhost';
FLUSH PRIVILEGES;
SQL

  # --- filesystem + wordpress
  install -d -o "$owner" -g www-data -m 0755 "$WWW_ROOT/$domain" "$docroot"

  info "downloading WordPress"
  wp_as "$owner" "$docroot" core download --locale="$WP_LOCALE" || die "download failed"

  info "generating wp-config.php"
  wp_as "$owner" "$docroot" config create \
      --dbname="$dbname" --dbuser="$dbuser" --dbpass="$dbpass" \
      --dbcharset=utf8mb4 --dbcollate=utf8mb4_unicode_ci \
      --extra-php <<'PHP' || die "config create failed"
define('WP_AUTO_UPDATE_CORE', 'minor');
define('DISALLOW_FILE_EDIT', true);
PHP

  info "installing WordPress"
  wp_as "$owner" "$docroot" core install \
      --url="https://$domain" --title="$domain" \
      --admin_user=admin --admin_password="$adminpass" \
      --admin_email="$admin_email" --skip-email || die "core install failed"

  # human-readable permalink structure, and away with the useless defaults
  wp_as "$owner" "$docroot" rewrite structure '/%postname%/' --hard >/dev/null
  wp_as "$owner" "$docroot" plugin delete hello akismet >/dev/null 2>&1
  wp_as "$owner" "$docroot" post delete 1 --force >/dev/null 2>&1

  # --- permissions: the user owns the files, www-data as group, setgid where writes happen
  chown -R "$owner":www-data "$docroot"
  find "$docroot" -type d -exec chmod 755 {} \;
  find "$docroot" -type f -exec chmod 644 {} \;
  chmod 640 "$docroot/wp-config.php"
  install -d -o "$owner" -g www-data -m 2775 "$docroot/wp-content/uploads"
  install -d -o "$owner" -g www-data -m 2775 "$docroot/wp-content/upgrade"

  # --- nginx
  info "writing the vhost"
  write_vhost "$domain" "$slug" "$docroot" "$with_www"
  ln -sfn "$NGINX_AVAIL/$slug" "$NGINX_ENABLED/$slug"

  nginx -t || { rm -f "$NGINX_ENABLED/$slug"; die "nginx -t failed, symlink removed"; }
  systemctl reload nginx

  # --- credentials outside the docroot
  install -d -m 0700 /root/wp-sites
  cat > "/root/wp-sites/$domain.txt" <<CRED
domain:    $domain
docroot:   $docroot
owner:     $owner
db name:   $dbname
db user:   $dbuser
db pass:   $dbpass
wp admin:  admin
wp pass:   $adminpass
created:   $(date '+%F %T')
CRED
  chmod 600 "/root/wp-sites/$domain.txt"

  ok "site created: http://$domain"
  info "credentials in /root/wp-sites/$domain.txt"
  info "now run: $0 cert $domain"
}

# --------------------------------------------------------------- cert

cmd_cert() {
  local domain="$1"; shift
  local with_www=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-www) with_www=0; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done

  command -v certbot >/dev/null || die "certbot not installed (apt install certbot python3-certbot-nginx)"
  find_vhost "$domain" >/dev/null || die "no vhost for $domain"

  # certbot fails if DNS does not point here: check first, and for both names
  local ip r
  ip=$(server_ip)
  for n in "$domain" $( [[ $with_www == 1 ]] && echo "www.$domain" ); do
    r=$(getent ahostsv4 "$n" | awk '{print $1}' | head -1)
    [[ "$r" == "$ip" ]] || die "DNS: $n resolves to '${r:-nothing}', expected $ip"
    info "DNS ok: $n -> $ip"
  done

  # the http-01 challenge must be able to read /.well-known/ over plain http
  curl -fsS --max-time 10 -o /dev/null "http://$domain/" \
    || warn "http://$domain is not responding: the challenge may fail"

  local args=(--nginx --agree-tos --redirect --non-interactive -d "$domain")
  [[ $with_www == 1 ]] && args+=(-d "www.$domain")
  [[ -n "$ADMIN_EMAIL" ]] && args+=(-m "$ADMIN_EMAIL") || args+=(--register-unsafely-without-email)

  certbot "${args[@]}" || die "certbot failed"

  nginx -t && systemctl reload nginx

  # from here on the site is on https: align the URLs in the DB
  local vh root owner
  vh=$(find_vhost "$domain")
  root=$(grep -hoP '^\s*root\s+\K[^;]+' "$vh" | grep -v /usr/share/nginx | head -1 | sed 's:/*$::')
  if [[ -n "$root" && -f "$root/wp-config.php" ]]; then
    owner=$(stat -c %U "$root")
    wp_as "$owner" "$root" option update home    "https://$domain" >/dev/null
    wp_as "$owner" "$root" option update siteurl "https://$domain" >/dev/null
    info "home/siteurl updated to https://$domain"
  fi

  ok "certificate active: https://$domain"
  info "automatic renewal: $(systemctl is-enabled certbot.timer 2>/dev/null || echo 'CHECK certbot.timer')"
}

# --------------------------------------------------------------- remove

cmd_remove() {
  local domain="$1"
  local vh slug root owner dbname stamp bdir

  vh=$(find_vhost "$domain") || die "no vhost for $domain"
  slug=$(basename "$vh")
  root=$(grep -hoP '^\s*root\s+\K[^;]+' "$vh" | grep -v /usr/share/nginx | head -1 | sed 's:/*$::')

  echo
  echo "The following will be REMOVED:"
  echo "  vhost        $vh"
  echo "  symlink      $NGINX_ENABLED/$slug"
  [[ -n "$root" ]] && echo "  files        ${root%/wordpress} ($(du -sh "${root%/wordpress}" 2>/dev/null | cut -f1))"
  if [[ -n "$root" && -f "$root/wp-config.php" ]]; then
    owner=$(stat -c %U "$root")
    dbname=$(wp_as "$owner" "$root" config get DB_NAME 2>/dev/null)
    echo "  database     ${dbname:-?}"
  fi
  [[ -d "/etc/letsencrypt/live/$domain" ]] && echo "  letsencrypt certificate for $domain"
  echo
  echo "A full backup will be saved in $BACKUP_ROOT before proceeding."
  echo
  read -rp "To confirm, type the full domain: " confirm
  [[ "$confirm" == "$domain" ]] || die "got '$confirm', expected '$domain' - aborted"

  stamp=$(date +%Y%m%d-%H%M%S)
  bdir="$BACKUP_ROOT/$domain-$stamp"
  install -d -m 0700 "$bdir"

  if [[ -n "$dbname" ]]; then
    info "dumping the database"
    wp_as "$owner" "$root" db export - --single-transaction --quick | gzip -c > "$bdir/db.sql.gz" \
      || warn "dump failed, carrying on"
  fi
  if [[ -n "$root" && -d "${root%/wordpress}" ]]; then
    info "archiving the files"
    tar -czf "$bdir/files.tar.gz" -C "$WWW_ROOT" "$domain" 2>/dev/null || warn "incomplete tar"
  fi
  cp "$vh" "$bdir/nginx.vhost" 2>/dev/null
  cp "/root/wp-sites/$domain.txt" "$bdir/" 2>/dev/null
  ok "backup in $bdir"

  # --- now tear it down
  rm -f "$NGINX_ENABLED/$slug"
  rm -f "$vh"
  nginx -t && systemctl reload nginx || warn "nginx -t failed, check by hand"

  if [[ -n "$dbname" ]]; then
    local dbuser
    dbuser=$(wp_as "$owner" "$root" config get DB_USER 2>/dev/null)
    info "dropping database and user"
    mysql <<SQL
DROP DATABASE IF EXISTS \`$dbname\`;
DROP USER IF EXISTS '$dbuser'@'localhost';
FLUSH PRIVILEGES;
SQL
  fi

  if [[ -d "/etc/letsencrypt/live/$domain" ]]; then
    info "revoking the certificate"
    certbot delete --cert-name "$domain" --non-interactive || warn "certbot delete failed"
  fi

  [[ -n "$root" ]] && rm -rf "${root%/wordpress}"
  rm -f "/root/wp-sites/$domain.txt"

  # the dedicated user is removed only if it owns nothing else
  if [[ -n "${owner:-}" && "$owner" != "www-data" && "$owner" != "root" ]]; then
    if [[ -z "$(find "$WWW_ROOT" -maxdepth 3 -user "$owner" -print -quit 2>/dev/null)" ]]; then
      info "removing the user $owner (it owns nothing any more)"
      userdel "$owner" 2>/dev/null || warn "userdel failed"
    else
      warn "the user $owner owns other files, leaving it in place"
    fi
  fi

  ok "$domain removed. Restore from: $bdir"
}

# --------------------------------------------------------------- main

usage() {
  sed -n '3,12p' "$0" | sed 's/^# \?//'
  exit 1
}

cmd="${1:-}"; shift || true
case "$cmd" in
  list)   cmd_list ;;
  create) [[ $# -ge 1 ]] || usage; cmd_create "$@" ;;
  cert)   [[ $# -ge 1 ]] || usage; cmd_cert "$@" ;;
  remove) [[ $# -ge 1 ]] || usage; cmd_remove "$@" ;;
  *)      usage ;;
esac
