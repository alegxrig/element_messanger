#!/usr/bin/env bash
set -Eeuo pipefail

# Local Matrix + Element Web + MatrixRTC/LiveKit test stack for Ubuntu.
# No public DNS, VPS or Internet-facing ports are required.
#
# Local URLs:
#   https://element.m.localhost
#   https://matrix.m.localhost
#   https://matrix-rtc.m.localhost
#
# The script uses:
#   Synapse + PostgreSQL + Element Web + LiveKit + lk-jwt-service + Caddy
#
# It also fixes the Synapse Docker bind-mount ownership problem by running
# the Synapse container with the current host user's UID/GID.

set -o errtrace

PROJECT_DIR="${PROJECT_DIR:-$HOME/element-matrix-lab}"
SYNAPSE_VERSION="1.161.0"
ELEMENT_VERSION="1.12.30"
LIVEKIT_VERSION="1.13.7"
LKJWT_VERSION="0.7.0"
CADDY_VERSION="2.11.4"

MATRIX_HOST="matrix.m.localhost"
ELEMENT_HOST="element.m.localhost"
RTC_HOST="matrix-rtc.m.localhost"

HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }
trap 'echo "ERROR: script failed at line $LINENO" >&2' ERR

if [[ $EUID -eq 0 ]]; then
  fail "Run this script as your normal Ubuntu user, not as root."
fi

if ! command -v sudo >/dev/null 2>&1; then
  fail "sudo is required."
fi

for cmd in curl openssl ip; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log "Installing $cmd"
    sudo apt-get update
    sudo apt-get install -y "$cmd"
  fi
done

if ! command -v docker >/dev/null 2>&1; then
  log "Docker is not installed; installing Docker Engine"
  curl -fsSL https://get.docker.com | sudo sh
fi

if ! docker compose version >/dev/null 2>&1; then
  fail "Docker Compose v2 is not available. Install the Docker Compose plugin and rerun."
fi

if docker info >/dev/null 2>&1; then
  DOCKER=(docker)
else
  DOCKER=(sudo docker)
fi

if [[ -e "$PROJECT_DIR/compose.yaml" ]]; then
  fail "$PROJECT_DIR already contains compose.yaml. Remove it manually only if you want a clean reinstall."
fi

# Determine the laptop's LAN address. This is used by LiveKit for local WebRTC
# ICE candidates; 127.0.0.1 would point at the container itself.
HOST_LAN_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
if [[ -z "$HOST_LAN_IP" ]]; then
  HOST_LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi
[[ -n "$HOST_LAN_IP" ]] || fail "Could not determine the laptop LAN IP."

log "Using host LAN IP: $HOST_LAN_IP"

mkdir -p \
  "$PROJECT_DIR/synapse" \
  "$PROJECT_DIR/element" \
  "$PROJECT_DIR/livekit"
chmod 700 "$PROJECT_DIR"

POSTGRES_PASSWORD="$(openssl rand -hex 32)"
LIVEKIT_SECRET="$(openssl rand -hex 32)"
MACAROON_SECRET="$(openssl rand -hex 32)"
FORM_SECRET="$(openssl rand -hex 32)"
REGISTRATION_SHARED_SECRET="$(openssl rand -hex 32)"

cat > "$PROJECT_DIR/.env" <<EOF_ENV
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
LIVEKIT_KEY=devkey
LIVEKIT_SECRET=$LIVEKIT_SECRET
HOST_UID=$HOST_UID
HOST_GID=$HOST_GID
HOST_LAN_IP=$HOST_LAN_IP
EOF_ENV
chmod 600 "$PROJECT_DIR/.env"

log "Generating Synapse configuration"
"${DOCKER[@]}" run --rm \
  -v "$PROJECT_DIR/synapse:/data" \
  -e SYNAPSE_SERVER_NAME="$MATRIX_HOST" \
  -e SYNAPSE_REPORT_STATS=no \
  -e UID="$HOST_UID" \
  -e GID="$HOST_GID" \
  "matrixdotorg/synapse:v$SYNAPSE_VERSION" generate

# Synapse's Docker image defaults to UID/GID 991. Force ownership to the same
# user that will run the container below. This prevents host-side Permission
# denied errors and keeps the bind mount writable by Synapse at runtime.
sudo chown -R "$HOST_UID:$HOST_GID" "$PROJECT_DIR/synapse"

SIGNING_KEY_FILE="$(find "$PROJECT_DIR/synapse" -maxdepth 1 -type f -name '*.signing.key' -print -quit)"
LOG_CONFIG_FILE="$(find "$PROJECT_DIR/synapse" -maxdepth 1 -type f -name '*.log.config' -print -quit)"
[[ -n "$SIGNING_KEY_FILE" ]] || fail "Synapse signing key was not generated"
[[ -n "$LOG_CONFIG_FILE" ]] || fail "Synapse log configuration was not generated"

SIGNING_KEY_NAME="$(basename "$SIGNING_KEY_FILE")"
LOG_CONFIG_NAME="$(basename "$LOG_CONFIG_FILE")"

cat > "$PROJECT_DIR/synapse/homeserver.yaml" <<EOF_HS
server_name: "$MATRIX_HOST"
public_baseurl: "https://$MATRIX_HOST/"

pid_file: /data/homeserver.pid

log_config: /data/$LOG_CONFIG_NAME
signing_key_path: /data/$SIGNING_KEY_NAME
media_store_path: /data/media_store

macaroon_secret_key: "$MACAROON_SECRET"
form_secret: "$FORM_SECRET"
registration_shared_secret: "$REGISTRATION_SHARED_SECRET"

report_stats: false

enable_registration: false

listeners:
  - port: 8008
    bind_addresses:
      - 0.0.0.0
    type: http
    tls: false
    x_forwarded: true
    resources:
      - names:
          - client
          - federation

# MatrixRTC Authorization Service needs either a federation or openid listener.

# PostgreSQL instead of SQLite.
database:
  name: psycopg2
  txn_limit: 10000
  args:
    user: synapse
    password: "$POSTGRES_PASSWORD"
    database: synapse
    host: postgres
    port: 5432
    cp_min: 5
    cp_max: 10

serve_server_wellknown: true

# MatrixRTC / Element Call prerequisites.
experimental_features:
  msc3266_enabled: true
  msc4143_enabled: true
  msc4222_enabled: true

max_event_delay_duration: 24h

rc_message:
  per_second: 0.5
  burst_count: 30

rc_delayed_event_mgmt:
  per_second: 1
  burst_count: 20

matrix_rtc:
  transports:
    - type: livekit
      livekit_service_url: "https://$RTC_HOST/livekit/jwt"

# Needed because Synapse does not currently derive the RTC focus from
# matrix_rtc.transports in .well-known automatically.
extra_well_known_client_content:
  org.matrix.msc4143.rtc_foci:
    - type: livekit
      livekit_service_url: "https://$RTC_HOST/livekit/jwt"
EOF_HS

chmod 600 "$PROJECT_DIR/synapse/homeserver.yaml" 

cat > "$PROJECT_DIR/element/config.json" <<EOF_ELEMENT
{
  "default_server_name": "$MATRIX_HOST",
  "default_server_config": {
    "m.homeserver": {
      "base_url": "https://$MATRIX_HOST"
    }
  },
  "disable_custom_urls": true,
  "disable_guests": true,
  "brand": "Element"
}
EOF_ELEMENT
chmod 644 "$PROJECT_DIR/element/config.json"

cat > "$PROJECT_DIR/livekit/livekit.yaml" <<EOF_LK
port: 7880
log_level: info

rtc:
  tcp_port: 7881
  udp_port: 7882
  use_external_ip: false
  node_ip: $HOST_LAN_IP
  allow_tcp_fallback: true

room:
  auto_create: false

keys:
  devkey: "$LIVEKIT_SECRET"

turn:
  enabled: true
  udp_port: 3478

webhook:
  api_key: devkey
  urls:
    - "http://lk-jwt:8080/sfu_webhook"
EOF_LK
chmod 644 "$PROJECT_DIR/livekit/livekit.yaml"

cat > "$PROJECT_DIR/Caddyfile" <<EOF_CADDY
# Local-only HTTPS. Caddy uses a private CA here.

element.m.localhost {
    tls internal
    encode gzip zstd
    reverse_proxy element:80
}

matrix.m.localhost {
    tls internal
    reverse_proxy synapse:8008
}

matrix-rtc.m.localhost {
    tls internal

    # lk-jwt-service exposes /sfu/get and /healthz.
    # Strip /livekit/jwt before proxying, as required by its API path.
    @jwt_service path /livekit/jwt/sfu/get /livekit/jwt/healthz
    handle @jwt_service {
        uri strip_prefix /livekit/jwt
        reverse_proxy lk-jwt:8080 {
            header_up Host {host}
            header_up X-Forwarded-Server {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
        }
    }

    # LiveKit SFU signalling is exposed at /livekit/sfu.
    handle {
        reverse_proxy livekit:7880 {
            header_up Host {host}
            header_up X-Forwarded-Server {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
        }
    }
}
EOF_CADDY
chmod 644 "$PROJECT_DIR/Caddyfile"

cat > "$PROJECT_DIR/compose.yaml" <<'EOF_COMPOSE'
services:
  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: synapse
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: synapse
      POSTGRES_INITDB_ARGS: "--encoding=UTF8 --locale=C"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U synapse -d synapse"]
      interval: 5s
      timeout: 5s
      retries: 20
    networks: [matrixnet]

  synapse:
    image: matrixdotorg/synapse:v1.161.0
    restart: unless-stopped
    environment:
      SYNAPSE_CONFIG_PATH: /data/homeserver.yaml
      UID: ${HOST_UID}
      GID: ${HOST_GID}
    volumes:
      - ./synapse:/data
    depends_on:
      postgres:
        condition: service_healthy
    expose:
      - "8008"
    networks: [matrixnet]

  element:
    image: ghcr.io/element-hq/element-web:v1.12.30
    restart: unless-stopped
    volumes:
      - ./element/config.json:/app/config.json:ro
    expose:
      - "80"
    networks: [matrixnet]

  livekit:
    image: livekit/livekit-server:v1.13.7
    restart: unless-stopped
    command: ["--config", "/etc/livekit.yaml"]
    volumes:
      - ./livekit/livekit.yaml:/etc/livekit.yaml:ro
    expose:
      - "7880"
    ports:
      - "${HOST_LAN_IP}:7881:7881/tcp"
      - "${HOST_LAN_IP}:7882:7882/udp"
      - "${HOST_LAN_IP}:3478:3478/udp"
    networks: [matrixnet]

  lk-jwt:
    image: ghcr.io/element-hq/lk-jwt-service:0.7.0
    restart: unless-stopped
    environment:
      LIVEKIT_URL: "wss://matrix-rtc.m.localhost/livekit/sfu"
      LIVEKIT_KEY: "devkey"
      LIVEKIT_SECRET: "${LIVEKIT_SECRET}"
      LIVEKIT_JWT_BIND: ":8080"
      LIVEKIT_FULL_ACCESS_HOMESERVERS: "matrix.m.localhost"
      LIVEKIT_CS_API_URL_OVERRIDES: "matrix.m.localhost=http://synapse:8008"
      LIVEKIT_SANITY_CHECK_INTERVAL_SECONDS: "30"
      LIVEKIT_LOG_LEVEL: "info"
      # Local development only: Caddy uses a private CA.
      LIVEKIT_INSECURE_SKIP_VERIFY_TLS: "YES_I_KNOW_WHAT_I_AM_DOING"
    expose:
      - "8080"
    depends_on:
      - synapse
      - livekit
    networks: [matrixnet]

  caddy:
    image: caddy:2.11.4-alpine
    restart: unless-stopped
    ports:
      - "127.0.0.1:80:80"
      - "127.0.0.1:443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - synapse
      - element
      - livekit
      - lk-jwt
    networks: [matrixnet]

networks:
  matrixnet:

volumes:
  postgres_data:
  caddy_data:
  caddy_config:
EOF_COMPOSE

# Keep the Compose file image versions in sync with the constants used above.
sed -i "s/matrixdotorg\/synapse:v1\.161\.0/matrixdotorg\/synapse:v$SYNAPSE_VERSION/" "$PROJECT_DIR/compose.yaml"
sed -i "s#ghcr.io/element-hq/element-web:v1\.12\.30#ghcr.io/element-hq/element-web:v$ELEMENT_VERSION#" "$PROJECT_DIR/compose.yaml"
sed -i "s#livekit/livekit-server:v1\.13\.7#livekit/livekit-server:v$LIVEKIT_VERSION#" "$PROJECT_DIR/compose.yaml"
sed -i "s#ghcr.io/element-hq/lk-jwt-service:0\.7\.0#ghcr.io/element-hq/lk-jwt-service:$LKJWT_VERSION#" "$PROJECT_DIR/compose.yaml"
sed -i "s#caddy:2\.11\.4-alpine#caddy:$CADDY_VERSION-alpine#" "$PROJECT_DIR/compose.yaml"

# Make the local hostnames deterministic. This avoids depending on how the
# installed resolver handles arbitrary *.localhost names.
HOSTS_LINE="127.0.0.1 $ELEMENT_HOST $MATRIX_HOST $RTC_HOST"
if ! grep -Fq "$ELEMENT_HOST" /etc/hosts; then
  echo "$HOSTS_LINE" | sudo tee -a /etc/hosts >/dev/null
else
  log "Local hostnames already exist in /etc/hosts"
fi

log "Validating Docker Compose"
(cd "$PROJECT_DIR" && "${DOCKER[@]}" compose config >/dev/null)

log "Pulling container images"
(cd "$PROJECT_DIR" && "${DOCKER[@]}" compose pull)

log "Starting stack"
(cd "$PROJECT_DIR" && "${DOCKER[@]}" compose up -d)

log "Waiting for services"
for _ in {1..30}; do
  if curl -ksSf "https://$MATRIX_HOST/_matrix/client/versions" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

curl -ksSf "https://$MATRIX_HOST/_matrix/client/versions" >/dev/null \
  || fail "Synapse did not become reachable through Caddy"
curl -ksSf "https://$ELEMENT_HOST/" >/dev/null \
  || fail "Element Web did not become reachable through Caddy"
curl -ksSf "https://$RTC_HOST/livekit/jwt/healthz" >/dev/null \
  || fail "lk-jwt-service health endpoint is not reachable through Caddy"

ROOT_CA="$PROJECT_DIR/caddy-root.crt"
(cd "$PROJECT_DIR" && "${DOCKER[@]}" compose cp caddy:/data/caddy/pki/authorities/local/root.crt "$ROOT_CA")
chmod 644 "$ROOT_CA"

log "Installing Caddy local CA into Ubuntu trust store"
sudo cp "$ROOT_CA" /usr/local/share/ca-certificates/element-matrix-lab.crt
sudo update-ca-certificates >/dev/null

log "Testing HTTPS without -k"
curl -fsS "https://$MATRIX_HOST/_matrix/client/versions" >/dev/null
curl -fsS "https://$ELEMENT_HOST/" >/dev/null
curl -fsS "https://$MATRIX_HOST/.well-known/matrix/client" \
  | grep -q 'org.matrix.msc4143.rtc_foci' \
  || fail "MatrixRTC focus is missing from .well-known/matrix/client"

log "Validating Synapse configuration"
(cd "$PROJECT_DIR" && "${DOCKER[@]}" compose exec -T synapse \
  python -m synapse.config -c /data/homeserver.yaml >/dev/null)

cat > "$PROJECT_DIR/create-user.sh" <<'EOF_USER'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"
if docker info >/dev/null 2>&1; then
  DOCKER=(docker)
else
  DOCKER=(sudo docker)
fi
"${DOCKER[@]}" compose exec synapse register_new_matrix_user \
  -c /data/homeserver.yaml \
  http://localhost:8008
EOF_USER
chmod 700 "$PROJECT_DIR/create-user.sh"

cat > "$PROJECT_DIR/status.sh" <<'EOF_STATUS'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"
if docker info >/dev/null 2>&1; then
  DOCKER=(docker)
else
  DOCKER=(sudo docker)
fi
"${DOCKER[@]}" compose ps
printf '\nSynapse versions:\n'
curl -fsS https://matrix.m.localhost/_matrix/client/versions | python3 -m json.tool || true
printf '\nMatrixRTC transports:\n'
curl -fsS https://matrix.m.localhost/_matrix/client/unstable/org.matrix.msc4143/rtc/transports || true
printf '\nClient well-known:\n'
curl -fsS https://matrix.m.localhost/.well-known/matrix/client | python3 -m json.tool || true
printf '\nJWT health:\n'
curl -fsS https://matrix-rtc.m.localhost/livekit/jwt/healthz || true
printf '\n'
EOF_STATUS
chmod 700 "$PROJECT_DIR/status.sh"

cat > "$PROJECT_DIR/logs.sh" <<'EOF_LOGS'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"
if docker info >/dev/null 2>&1; then
  DOCKER=(docker)
else
  DOCKER=(sudo docker)
fi
SERVICE="${1:-}"
if [[ -n "$SERVICE" ]]; then
  "${DOCKER[@]}" compose logs -f "$SERVICE"
else
  "${DOCKER[@]}" compose logs -f --tail=100
fi
EOF_LOGS
chmod 700 "$PROJECT_DIR/logs.sh"

cat > "$PROJECT_DIR/stop.sh" <<'EOF_STOP'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"
if docker info >/dev/null 2>&1; then
  DOCKER=(docker)
else
  DOCKER=(sudo docker)
fi
"${DOCKER[@]}" compose down
EOF_STOP
chmod 700 "$PROJECT_DIR/stop.sh"

cat > "$PROJECT_DIR/start.sh" <<'EOF_START'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"
if docker info >/dev/null 2>&1; then
  DOCKER=(docker)
else
  DOCKER=(sudo docker)
fi
"${DOCKER[@]}" compose up -d
EOF_START
chmod 700 "$PROJECT_DIR/start.sh"

cat > "$PROJECT_DIR/README-TEST.txt" <<EOF_README
LOCAL MATRIX TEST STACK
=======================

Element Web:
  https://$ELEMENT_HOST

Synapse:
  https://$MATRIX_HOST

MatrixRTC / LiveKit:
  https://$RTC_HOST

Matrix IDs:
  @username:$MATRIX_HOST

Local host LAN IP used for LiveKit ICE:
  $HOST_LAN_IP

Create users:
  ./create-user.sh

Status:
  ./status.sh

Logs:
  ./logs.sh
  ./logs.sh synapse
  ./logs.sh livekit
  ./logs.sh lk-jwt
  ./logs.sh caddy

Stop:
  ./stop.sh

Start:
  ./start.sh

Testing calls:
  1. Open Element Web in two separate browser profiles on this Ubuntu laptop.
  2. Create two local accounts with ./create-user.sh.
  3. Log in to both profiles.
  4. Create a direct chat between the two accounts.
  5. Start an audio/video call.

This phase uses Caddy's private local CA and is intended for development/testing.
It does not test Internet NAT traversal. For that, move the same stack to a VPS
with public DNS and a trusted certificate, then expose the LiveKit media ports.
EOF_README

log "Installation completed"
cat <<EOF_SUMMARY

Element Web:
  https://$ELEMENT_HOST

Create two test accounts:
  cd "$PROJECT_DIR"
  ./create-user.sh
  ./create-user.sh

Check stack:
  ./status.sh

Check call components:
  ./logs.sh livekit
  ./logs.sh lk-jwt

Test audio/video calls using two separate browser profiles on this laptop.

Project:
  $PROJECT_DIR
EOF_SUMMARY
