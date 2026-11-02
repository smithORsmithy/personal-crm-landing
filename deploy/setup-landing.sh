#!/usr/bin/env bash
# Server side of the landing deploy. Run once after prepare-server.sh; safe to run again.
# Touches only its own things: the user deploy-landing, the folder /var/www/linkbook.site
# and the nginx file for linkbook.site (takes it over from the placeholder).
#
# Run (root login is off; sudo asks for the crmapp password):
#   scp deploy/setup-landing.sh crm:
#   ssh -t crm "sudo bash ~/setup-landing.sh '<deploy public key>'"
set -euo pipefail

DEPLOY_PUBKEY="${1:?pass the deploy public key as the first argument}"
DOMAIN="linkbook.site"
DEPLOY_USER="deploy-landing"
SITE_DIR="/var/www/$DOMAIN"
NGINX_SITE="/etc/nginx/sites-available/$DOMAIN"
PLACEHOLDER="/var/www/placeholder/index.html"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run it with sudo" >&2
  exit 1
fi
for f in /etc/nginx/snippets/linkbook-tls.conf /etc/nginx/snippets/acme-challenge.conf; do
  if [ ! -f "$f" ]; then
    echo "$f is missing: run prepare-server.sh first" >&2
    exit 1
  fi
done

echo "==> rsync"
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq rsync >/dev/null
RRSYNC="$(command -v rrsync || true)"
if [ -z "$RRSYNC" ]; then
  echo "rrsync not found (it ships with the rsync package)" >&2
  exit 1
fi

echo "==> Deploy user $DEPLOY_USER"
if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/sh "$DEPLOY_USER"
fi
install -d -m 755 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$SITE_DIR"
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"
# The key can only upload files into $SITE_DIR: no shell, no other folders.
printf 'command="%s -wo %s",restrict %s\n' "$RRSYNC" "$SITE_DIR" "$DEPLOY_PUBKEY" \
  > "/home/$DEPLOY_USER/.ssh/authorized_keys"
chown "$DEPLOY_USER:$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh/authorized_keys"
chmod 600 "/home/$DEPLOY_USER/.ssh/authorized_keys"

# Until the first deploy, keep showing the placeholder instead of an error
if [ ! -f "$SITE_DIR/index.html" ] && [ -f "$PLACEHOLDER" ]; then
  install -m 644 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$PLACEHOLDER" "$SITE_DIR/index.html"
fi

echo "==> nginx: $DOMAIN serves $SITE_DIR"
cat > "$NGINX_SITE" <<EOF
# Landing page. Managed by deploy/setup-landing.sh in the personal-crm-landing repo.
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    include snippets/acme-challenge.conf;

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;
    include snippets/linkbook-tls.conf;
    server_tokens off;

    root $SITE_DIR;
    index index.html;
    gzip_types text/css application/javascript image/svg+xml;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # Astro puts files with a content hash in their names here
    location /_astro/ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    location /fonts/ {
        expires 30d;
    }
}
EOF
ln -sf "$NGINX_SITE" "/etc/nginx/sites-enabled/$DOMAIN"
nginx -t
systemctl reload nginx

echo "==> Check"
code=$(curl -s -o /dev/null -w '%{http_code}' --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/")
echo "    https://$DOMAIN/ -> $code"
echo "==> Done. Site folder: $SITE_DIR, deploy user: $DEPLOY_USER"
