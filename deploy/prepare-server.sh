#!/usr/bin/env bash
# Prepares the shared server for the landing and the app:
#   - Docker: published container ports bind to 127.0.0.1 only (Docker skips ufw),
#     container logs are size-limited
#   - nginx: linkbook.site and app.linkbook.site, a placeholder page on both
#   - one Let's Encrypt certificate for both names, renewed by the certbot timer
#   - http -> https redirect; requests for unknown hosts or the bare IP are dropped
#
# Safe to run again. A site file is rewritten only while it still serves the
# placeholder: once the landing or the app takes its file over, it is left alone.
#
# Run (root login is off; sudo asks for the crmapp password):
#   scp deploy/prepare-server.sh crm:
#   ssh -t crm "sudo bash ~/prepare-server.sh <email>"
# The email is registered with Let's Encrypt, the certificate service.
set -euo pipefail

EMAIL="${1:?pass an email for the certificate as the first argument}"
LANDING_DOMAIN="linkbook.site"
APP_DOMAIN="app.linkbook.site"
CERT_NAME="$LANDING_DOMAIN"
CERT_DIR="/etc/letsencrypt/live/$CERT_NAME"
PLACEHOLDER_DIR="/var/www/placeholder"
ACME_DIR="/var/www/letsencrypt"
SITES="/etc/nginx/sites-available"
ENABLED="/etc/nginx/sites-enabled"
MARKER="# placeholder site, managed by prepare-server.sh"
LOG="/var/log/prepare-server.log"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run it with sudo" >&2
  exit 1
fi

# Keep a copy of the output so it can be checked later without root
touch "$LOG" && chmod 644 "$LOG"
exec > >(tee -a "$LOG") 2>&1
echo "===== $(date -Is) prepare-server.sh"

echo "==> Packages: nginx, certbot, Docker"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq nginx certbot docker.io docker-compose-v2 >/dev/null

echo "==> Docker settings"
DAEMON_JSON="/etc/docker/daemon.json"
if [ ! -f "$DAEMON_JSON" ]; then
  install -d -m 755 /etc/docker
  # "ip" covers the default network, "default-network-opts" covers networks
  # that docker compose creates. live-restore keeps containers running while
  # Docker itself is updated.
  cat > "$DAEMON_JSON" <<'EOF'
{
  "ip": "127.0.0.1",
  "default-network-opts": {
    "bridge": {
      "com.docker.network.bridge.host_binding_ipv4": "127.0.0.1"
    }
  },
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true
}
EOF
  dockerd --validate --config-file "$DAEMON_JSON"
  systemctl restart docker
elif grep -q '"host_binding_ipv4": "127.0.0.1"' "$DAEMON_JSON" && grep -q '"ip": "127.0.0.1"' "$DAEMON_JSON"; then
  echo "    $DAEMON_JSON already binds container ports to 127.0.0.1"
else
  echo "    $DAEMON_JSON exists with other settings; not changing it. Check it by hand." >&2
  exit 1
fi
systemctl enable --quiet docker

echo "==> Docker check: published ports must listen on 127.0.0.1 only"
cleanup_docker_check() {
  docker rm -f bindcheck-default bindcheck-compose >/dev/null 2>&1 || true
  docker network rm bindcheck >/dev/null 2>&1 || true
  docker image rm busybox >/dev/null 2>&1 || true
}
trap cleanup_docker_check EXIT
docker network create bindcheck >/dev/null
docker run -d --name bindcheck-default -p 18081:8080 busybox httpd -f -p 8080 >/dev/null
docker run -d --name bindcheck-compose --network bindcheck -p 18082:8080 busybox httpd -f -p 8080 >/dev/null
sleep 2
bound="$(ss -tln | awk '$4 ~ /:1808[12]$/ {print $4}')"
sed 's/^/    listening: /' <<<"$bound"
published="$(grep -c . <<<"$bound" || true)"
exposed="$(grep -c -v '^127\.0\.0\.1:' <<<"$bound" || true)"
if [ "$published" -lt 2 ]; then
  echo "    FAIL: test containers did not publish their ports" >&2
  exit 1
fi
if [ "$exposed" -ne 0 ]; then
  echo "    FAIL: a container port is reachable from outside" >&2
  exit 1
fi
echo "    ok: both test ports listen on 127.0.0.1 only"
cleanup_docker_check
trap - EXIT

echo "==> Placeholder page"
install -d -m 755 "$PLACEHOLDER_DIR" "$ACME_DIR"
cat > "$PLACEHOLDER_DIR/index.html" <<'EOF'
<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="robots" content="noindex">
  <title>Скоро здесь будет сайт</title>
  <style>
    html, body { height: 100%; margin: 0; }
    body {
      display: flex; align-items: center; justify-content: center;
      padding: 16px; box-sizing: border-box; text-align: center;
      background: #f6f2ea; color: #1e1d1a;
      font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
    }
    h1 { margin: 0 0 8px; font-size: 28px; font-weight: 600; }
    p { margin: 0; color: #4c473f; }
  </style>
</head>
<body>
  <main>
    <h1>Скоро здесь будет сайт</h1>
    <p>Мы уже готовим его к запуску</p>
  </main>
</body>
</html>
EOF
chmod 644 "$PLACEHOLDER_DIR/index.html"

echo "==> nginx"
cat > /etc/nginx/snippets/acme-challenge.conf <<EOF
# Let's Encrypt checks domain ownership here
location ^~ /.well-known/acme-challenge/ {
    root $ACME_DIR;
    default_type text/plain;
}
EOF
cat > /etc/nginx/snippets/linkbook-tls.conf <<EOF
# One certificate for $LANDING_DOMAIN and $APP_DOMAIN
ssl_certificate     $CERT_DIR/fullchain.pem;
ssl_certificate_key $CERT_DIR/privkey.pem;
ssl_protocols TLSv1.2 TLSv1.3;
ssl_session_cache shared:linkbook_tls:10m;
ssl_session_timeout 1d;
EOF

have_cert() { [ -f "$CERT_DIR/fullchain.pem" ]; }

write_site() {
  local domain="$1" file="$SITES/$1" first_line=""
  [ -f "$file" ] && IFS= read -r first_line < "$file" || true
  if [ -f "$file" ] && [ "$first_line" != "$MARKER" ]; then
    echo "    $file is managed by its project now, left as is"
    return
  fi
  {
    echo "$MARKER"
    cat <<EOF
# The landing or app deploy replaces this file. Until then: placeholder page.
server {
    listen 80;
    listen [::]:80;
    server_name $domain;
    include snippets/acme-challenge.conf;

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
    if have_cert; then
      cat <<EOF

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $domain;
    include snippets/linkbook-tls.conf;
    server_tokens off;

    root $PLACEHOLDER_DIR;
    location / {
        add_header Cache-Control "no-store" always;
        add_header X-Robots-Tag "noindex" always;
        try_files /index.html =404;
    }
}
EOF
    fi
  } > "$file"
  ln -sf "$file" "$ENABLED/$domain"
  echo "    $file: placeholder$(have_cert && echo ', https' || echo ', http only for now')"
}

write_default() {
  {
    echo "# Managed by prepare-server.sh: requests for unknown hosts or the bare IP are dropped"
    cat <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    server_tokens off;
    return 444;
}
EOF
    if have_cert; then
      cat <<'EOF'

server {
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;
    server_name _;
    ssl_reject_handshake on;
    ssl_protocols TLSv1.2 TLSv1.3;
    return 444;
}
EOF
    fi
  } > "$SITES/00-default-deny"
  ln -sf "$SITES/00-default-deny" "$ENABLED/00-default-deny"
}

reload_nginx() {
  nginx -t
  systemctl reload nginx
}

# The stock "Welcome to nginx" site would clash with our default server
if [ -L "$ENABLED/default" ] && [ "$(readlink -f "$ENABLED/default")" = "$SITES/default" ]; then
  rm "$ENABLED/default"
fi

write_default
write_site "$LANDING_DOMAIN"
write_site "$APP_DOMAIN"
systemctl enable --quiet nginx
reload_nginx

echo "==> Certificate for $LANDING_DOMAIN and $APP_DOMAIN"
certbot certonly --webroot -w "$ACME_DIR" --cert-name "$CERT_NAME" \
  -d "$LANDING_DOMAIN" -d "$APP_DOMAIN" \
  --non-interactive --agree-tos -m "$EMAIL" --keep-until-expiring \
  --deploy-hook "systemctl reload nginx"

echo "==> nginx with https"
write_default
write_site "$LANDING_DOMAIN"
write_site "$APP_DOMAIN"
reload_nginx

echo "==> Renewal"
systemctl enable --now --quiet certbot.timer
systemctl list-timers certbot.timer --no-legend | sed 's/^/    /'
certbot renew --dry-run --cert-name "$CERT_NAME" --quiet && echo "    renewal dry run: ok"

echo "==> Local checks"
for d in "$LANDING_DOMAIN" "$APP_DOMAIN"; do
  http_code=$(curl -s -o /dev/null -w '%{http_code} -> %{redirect_url}' --resolve "$d:80:127.0.0.1" "http://$d/")
  https_code=$(curl -s -o /dev/null -w '%{http_code}' --resolve "$d:443:127.0.0.1" "https://$d/")
  echo "    $d: http $http_code; https $https_code"
done

echo "==> Done"
