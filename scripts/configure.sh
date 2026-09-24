#!/bin/bash
# Media Stack Auto-Configurator
# Run this ONCE after "docker compose up -d" to configure all services.
# Replaces manual Steps 8-10 from SETUP.md.
# Usage: bash scripts/configure.sh [--non-interactive] [--help]

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NON_INTERACTIVE=false

usage() {
    cat <<EOF
Usage: bash scripts/configure.sh [OPTIONS]

Options:
  --non-interactive   Skip interactive Seerr Plex login wiring
  --help              Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --non-interactive)
            NON_INTERACTIVE=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Load .env
if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
    echo -e "${RED}Error:${NC} .env file not found. Run setup.sh first."
    exit 1
fi
source "$SCRIPT_DIR/.env"

MEDIA_SERVER="${MEDIA_SERVER:-plex}"

# Permanent qBittorrent password (generated randomly)
QB_PASSWORD="media$(openssl rand -hex 12)"
CREDS_FILE="$MEDIA_DIR/state/first-run-credentials.txt"

# ============================================================
# Helper functions
# ============================================================

log() { echo -e "  ${GREEN}OK${NC}  $1"; }
warn() { echo -e "  ${YELLOW}..${NC}  $1"; }
fail() { echo -e "  ${RED}FAIL${NC}  $1"; }

save_credentials() {
    mkdir -p "$(dirname "$CREDS_FILE")"
    cat > "$CREDS_FILE" <<EOF
# Media Stack first-run credentials
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
qBittorrent Username: admin
qBittorrent Password: $QB_PASSWORD
Radarr API Key: $RADARR_KEY
Sonarr API Key: $SONARR_KEY
Prowlarr API Key: $PROWLARR_KEY
EOF
    chmod 600 "$CREDS_FILE"
}

api_post_json() {
    local label="$1"
    local url="$2"
    local api_key="$3"
    local payload="$4"
    local method="${5:-POST}"
    local body_file http_code

    body_file="$(mktemp)"
    http_code=$(curl -sS -o "$body_file" -w "%{http_code}" \
        -X "$method" \
        -H "Content-Type: application/json" \
        -H "X-Api-Key: $api_key" \
        -d "$payload" "$url" || echo "000")

    if [[ "$http_code" =~ ^2 ]]; then
        log "$label"
        rm -f "$body_file"
        return 0
    fi

    if grep -qiE "already exists|already configured|unique|duplicate" "$body_file"; then
        warn "$label (already configured)"
        rm -f "$body_file"
        return 0
    fi

    fail "$label (HTTP $http_code)"
    sed -n '1,2p' "$body_file" >&2 || true
    rm -f "$body_file"
    return 1
}

api_post_form() {
    local label="$1"
    local url="$2"
    local cookie="$3"
    shift 3

    local body_file http_code
    body_file="$(mktemp)"
    http_code=$(curl -sS -o "$body_file" -w "%{http_code}" -b "$cookie" "$url" "$@" || echo "000")

    if [[ "$http_code" =~ ^2 ]]; then
        log "$label"
        rm -f "$body_file"
        return 0
    fi

    if grep -qiE "already exists|already configured|unique|duplicate|unable to create category|unable to edit category" "$body_file"; then
        warn "$label (already configured)"
        rm -f "$body_file"
        return 0
    fi

    fail "$label (HTTP $http_code)"
    sed -n '1,2p' "$body_file" >&2 || true
    rm -f "$body_file"
    return 1
}

wait_for_service() {
    local name="$1"
    local url="$2"
    local max_attempts="${3:-30}"
    local attempt=0

    warn "Waiting for $name..."
    while [[ $attempt -lt $max_attempts ]]; do
        status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "$url" 2>/dev/null || true)
        if [[ "$status" =~ ^(200|301|302|307|401|403)$ ]]; then
            log "$name is ready"
            return 0
        fi
        sleep 2
        ((attempt++))
    done
    fail "$name didn't start after $((max_attempts * 2)) seconds"
    return 1
}

get_api_key() {
    local service="$1"
    local config_path="$MEDIA_DIR/config/$service/config.xml"
    local max_attempts=30
    local attempt=0

    while [[ $attempt -lt $max_attempts ]]; do
        if [[ -f "$config_path" ]]; then
            local key=$(grep -o '<ApiKey>[^<]*</ApiKey>' "$config_path" 2>/dev/null | sed 's/<[^>]*>//g')
            if [[ -n "$key" ]]; then
                echo "$key"
                return 0
            fi
        fi
        sleep 2
        ((attempt++))
    done
    fail "Could not read API key for $service"
    return 1
}

# ============================================================
# Start
# ============================================================

echo ""
echo "=============================="
echo "  Media Stack Configurator"
echo "=============================="
echo ""
echo "This will auto-configure all services. Takes about 2 minutes."
echo ""

# ============================================================
# 1. Wait for all services to be ready
# ============================================================

echo -e "${CYAN}[1/6] Waiting for services to start...${NC}"
echo ""

wait_for_service "qBittorrent" "http://localhost:8080"
wait_for_service "Prowlarr" "http://localhost:9696"
wait_for_service "Radarr" "http://localhost:7878"
wait_for_service "Sonarr" "http://localhost:8989"
wait_for_service "Bazarr" "http://localhost:6767"
wait_for_service "FlareSolverr" "http://localhost:8191"
wait_for_service "Seerr" "http://localhost:5055"

echo ""

# ============================================================
# 2. Extract API keys
# ============================================================

echo -e "${CYAN}[2/6] Reading API keys...${NC}"
echo ""

RADARR_KEY=$(get_api_key "radarr")
log "Radarr API key: ${RADARR_KEY:0:8}..."

SONARR_KEY=$(get_api_key "sonarr")
log "Sonarr API key: ${SONARR_KEY:0:8}..."

PROWLARR_KEY=$(get_api_key "prowlarr")
log "Prowlarr API key: ${PROWLARR_KEY:0:8}..."

echo ""

# ============================================================
# 3. Configure qBittorrent
# ============================================================

echo -e "${CYAN}[3/6] Configuring qBittorrent...${NC}"
echo ""

# Get temporary password from logs
QB_TEMP_PASS=$(docker logs qbittorrent 2>&1 | grep -o 'temporary password is provided for this session: [^ ]*' | tail -1 | awk '{print $NF}' || true)

if [[ -z "$QB_TEMP_PASS" ]]; then
    # Try the older log format
    QB_TEMP_PASS=$(docker logs qbittorrent 2>&1 | sed -n 's/.*password: \([^[:space:]]*\).*/\1/p' | tail -1 || true)
fi

if [[ -z "$QB_TEMP_PASS" ]]; then
    warn "Could not find temp password. qBit may already be configured."
    # Try default admin/adminadmin
    QB_TEMP_PASS="adminadmin"
fi

# Authenticate with qBittorrent
QB_COOKIE=$(curl -s -c - "http://localhost:8080/api/v2/auth/login" \
    --data-urlencode "username=admin" \
    --data-urlencode "password=$QB_TEMP_PASS" 2>/dev/null | grep SID | awk '{print $NF}' || true)

# If that failed, the WebUI password may already be permanently set from a
# previous run (the log-scraped temp password only exists before that happens).
# Fall back to the last saved password so re-runs stay idempotent.
if [[ -z "$QB_COOKIE" && -f "$CREDS_FILE" ]]; then
    SAVED_QB_PASS=$(grep '^qBittorrent Password:' "$CREDS_FILE" | awk '{print $NF}')
    if [[ -n "$SAVED_QB_PASS" ]]; then
        QB_COOKIE=$(curl -s -c - "http://localhost:8080/api/v2/auth/login" \
            --data-urlencode "username=admin" \
            --data-urlencode "password=$SAVED_QB_PASS" 2>/dev/null | grep SID | awk '{print $NF}' || true)
        if [[ -n "$QB_COOKIE" ]]; then
            QB_PASSWORD="$SAVED_QB_PASS"
        fi
    fi
fi

if [[ -z "$QB_COOKIE" ]]; then
    fail "Could not authenticate with qBittorrent"
    echo "  You may need to configure it manually at http://localhost:8080"
else
    # Set permanent password + all preferences in one call.
    # bypass_local_auth is required for gluetun's VPN_PORT_FORWARDING_UP_COMMAND
    # to work -- it posts the forwarded port to qBittorrent's setPreferences
    # endpoint from 127.0.0.1 without logging in first, which qBittorrent
    # otherwise rejects with 403.
    api_post_form "Password set and preferences configured" "http://localhost:8080/api/v2/app/setPreferences" "SID=$QB_COOKIE" \
        --data-urlencode "json={
            \"web_ui_password\": \"$QB_PASSWORD\",
            \"max_ratio\": 0,
            \"max_seeding_time\": 0,
            \"max_ratio_act\": 0,
            \"up_limit\": 1024,
            \"save_path\": \"/data/Downloads/complete\",
            \"temp_path_enabled\": true,
            \"temp_path\": \"/data/Downloads/incomplete\",
            \"preallocate_all\": false,
            \"add_trackers_enabled\": false,
            \"bypass_local_auth\": true
        }"

    # Create download categories
    api_post_form "Download category created: radarr" "http://localhost:8080/api/v2/torrents/createCategory" "SID=$QB_COOKIE" \
        --data-urlencode "category=radarr" \
        --data-urlencode "savePath=/data/Downloads/complete/radarr" || true
    api_post_form "Download category created: tv-sonarr" "http://localhost:8080/api/v2/torrents/createCategory" "SID=$QB_COOKIE" \
        --data-urlencode "category=tv-sonarr" \
        --data-urlencode "savePath=/data/Downloads/complete/tv-sonarr" || true

    # createCategory only creates; if the category already existed with a
    # stale savePath (e.g. from before a data-directory move), force it
    # back in sync with editCategory.
    api_post_form "Download category path synced: radarr" "http://localhost:8080/api/v2/torrents/editCategory" "SID=$QB_COOKIE" \
        --data-urlencode "category=radarr" \
        --data-urlencode "savePath=/data/Downloads/complete/radarr" || true
    api_post_form "Download category path synced: tv-sonarr" "http://localhost:8080/api/v2/torrents/editCategory" "SID=$QB_COOKIE" \
        --data-urlencode "category=tv-sonarr" \
        --data-urlencode "savePath=/data/Downloads/complete/tv-sonarr" || true
fi

save_credentials

echo ""

# ============================================================
# 4. Configure Radarr & Sonarr
# ============================================================

echo -e "${CYAN}[4/6] Configuring Radarr & Sonarr...${NC}"
echo ""

# --- Radarr: Add root folder ---
# Clean up a stale root folder left over from before a data-directory move
# (e.g. the old /movies path from a single-mount layout) so Radarr doesn't
# keep pointing at a path that no longer exists inside the container.
OLD_RADARR_ROOT_ID=$(curl -fsS "http://localhost:7878/api/v3/rootfolder" -H "X-Api-Key: $RADARR_KEY" 2>/dev/null | awk '
    /"path": *"\/movies"/ { want=1 }
    want && /"id":/ { gsub(/[^0-9]/, ""); print; exit }
' || true)
if [[ -n "$OLD_RADARR_ROOT_ID" ]]; then
    curl -fsS -X DELETE "http://localhost:7878/api/v3/rootfolder/$OLD_RADARR_ROOT_ID" -H "X-Api-Key: $RADARR_KEY" >/dev/null 2>&1 || true
    warn "Removed stale Radarr root folder: /movies"
fi

api_post_json "Radarr root folder set to /data/Movies" \
    "http://localhost:7878/api/v3/rootfolder" \
    "$RADARR_KEY" \
    '{"path": "/data/Movies", "accessible": true}'

# --- Radarr: Add qBittorrent download client ---
api_post_json "Radarr download client configured" \
    "http://localhost:7878/api/v3/downloadclient" \
    "$RADARR_KEY" \
    "{
        \"enable\": true,
        \"protocol\": \"torrent\",
        \"priority\": 1,
        \"name\": \"qBittorrent\",
        \"implementation\": \"QBittorrent\",
        \"configContract\": \"QBittorrentSettings\",
        \"fields\": [
            {\"name\": \"host\", \"value\": \"gluetun\"},
            {\"name\": \"port\", \"value\": 8080},
            {\"name\": \"username\", \"value\": \"admin\"},
            {\"name\": \"password\", \"value\": \"$QB_PASSWORD\"},
            {\"name\": \"movieCategory\", \"value\": \"radarr\"},
            {\"name\": \"recentMoviePriority\", \"value\": 0},
            {\"name\": \"olderMoviePriority\", \"value\": 0},
            {\"name\": \"initialState\", \"value\": 0},
            {\"name\": \"sequentialOrder\", \"value\": false},
            {\"name\": \"firstAndLast\", \"value\": false}
        ],
        \"removeCompletedDownloads\": true,
        \"removeFailedDownloads\": true
    }"

# --- Sonarr: Add root folder ---
OLD_SONARR_ROOT_ID=$(curl -fsS "http://localhost:8989/api/v3/rootfolder" -H "X-Api-Key: $SONARR_KEY" 2>/dev/null | awk '
    /"path": *"\/tv"/ { want=1 }
    want && /"id":/ { gsub(/[^0-9]/, ""); print; exit }
' || true)
if [[ -n "$OLD_SONARR_ROOT_ID" ]]; then
    curl -fsS -X DELETE "http://localhost:8989/api/v3/rootfolder/$OLD_SONARR_ROOT_ID" -H "X-Api-Key: $SONARR_KEY" >/dev/null 2>&1 || true
    warn "Removed stale Sonarr root folder: /tv"
fi

api_post_json "Sonarr root folder set to /data/TV Shows" \
    "http://localhost:8989/api/v3/rootfolder" \
    "$SONARR_KEY" \
    '{"path": "/data/TV Shows", "accessible": true}'

# --- Sonarr: Add qBittorrent download client ---
api_post_json "Sonarr download client configured" \
    "http://localhost:8989/api/v3/downloadclient" \
    "$SONARR_KEY" \
    "{
        \"enable\": true,
        \"protocol\": \"torrent\",
        \"priority\": 1,
        \"name\": \"qBittorrent\",
        \"implementation\": \"QBittorrent\",
        \"configContract\": \"QBittorrentSettings\",
        \"fields\": [
            {\"name\": \"host\", \"value\": \"gluetun\"},
            {\"name\": \"port\", \"value\": 8080},
            {\"name\": \"username\", \"value\": \"admin\"},
            {\"name\": \"password\", \"value\": \"$QB_PASSWORD\"},
            {\"name\": \"tvCategory\", \"value\": \"tv-sonarr\"},
            {\"name\": \"recentTvPriority\", \"value\": 0},
            {\"name\": \"olderTvPriority\", \"value\": 0},
            {\"name\": \"initialState\", \"value\": 0},
            {\"name\": \"sequentialOrder\", \"value\": false},
            {\"name\": \"firstAndLast\", \"value\": false}
        ],
        \"removeCompletedDownloads\": true,
        \"removeFailedDownloads\": true
    }"

echo ""

# ============================================================
# 5. Configure Prowlarr
# ============================================================

echo -e "${CYAN}[5/6] Configuring Prowlarr...${NC}"
echo ""

# --- Create FlareSolverr tag (ID will be 1) ---
FLARE_TAG_ID=$(curl -fsS "http://localhost:9696/api/v1/tag" \
    -H "X-Api-Key: $PROWLARR_KEY" \
    -H "Content-Type: application/json" \
    -d '{"label": "flaresolverr"}' 2>/dev/null | grep -m1 '^  "id":' | grep -o '[0-9]*$' || true)
FLARE_TAG_ID="${FLARE_TAG_ID:-1}"
log "FlareSolverr tag created (ID: $FLARE_TAG_ID)"

# --- Add FlareSolverr indexer proxy ---
api_post_json "FlareSolverr proxy added" \
    "http://localhost:9696/api/v1/indexerProxy" \
    "$PROWLARR_KEY" \
    "{
        \"name\": \"FlareSolverr\",
        \"implementation\": \"FlareSolverr\",
        \"configContract\": \"FlareSolverrSettings\",
        \"fields\": [
            {\"name\": \"host\", \"value\": \"http://flaresolverr:8191\"},
            {\"name\": \"requestTimeout\", \"value\": 60}
        ],
        \"tags\": [$FLARE_TAG_ID]
    }"

# --- Add indexers ---

# Helper to add a Prowlarr indexer
add_indexer() {
    local name="$1"
    local implementation="$2"
    local base_url="$3"
    local tags="$4"

    api_post_json "Indexer added: $name" \
        "http://localhost:9696/api/v1/indexer" \
        "$PROWLARR_KEY" \
        "{
            \"name\": \"$name\",
            \"implementation\": \"$implementation\",
            \"configContract\": \"${implementation}Settings\",
            \"protocol\": \"torrent\",
            \"enable\": true,
            \"priority\": 25,
            \"appProfileId\": 1,
            \"fields\": [
                {\"name\": \"baseUrl\", \"value\": \"$base_url\"},
                {\"name\": \"sortRequestLimit\", \"value\": 100},
                {\"name\": \"multiLanguages\", \"value\": []}
            ],
            \"tags\": [$tags]
        }"
}

# Cardigann-based indexers use a different format
add_cardigann_indexer() {
    local name="$1"
    local definition_name="$2"
    local base_url="$3"
    local tags="$4"

    api_post_json "Indexer added: $name" \
        "http://localhost:9696/api/v1/indexer" \
        "$PROWLARR_KEY" \
        "{
            \"name\": \"$name\",
            \"definitionName\": \"$definition_name\",
            \"implementation\": \"Cardigann\",
            \"configContract\": \"CardigannSettings\",
            \"protocol\": \"torrent\",
            \"enable\": true,
            \"priority\": 25,
            \"appProfileId\": 1,
            \"fields\": [
                {\"name\": \"definitionFile\", \"value\": \"$definition_name\"},
                {\"name\": \"baseUrl\", \"value\": \"$base_url\"}
            ],
            \"tags\": [$tags]
        }"
}

add_cardigann_indexer "YTS" "yts" "https://yts.mx" "" || true
add_cardigann_indexer "1337x" "1337x" "https://1337x.to" "$FLARE_TAG_ID" || true
add_cardigann_indexer "EZTV" "eztv" "https://eztvx.to" "" || true

# --- Connect Radarr as app ---
api_post_json "Prowlarr connected to Radarr" \
    "http://localhost:9696/api/v1/applications" \
    "$PROWLARR_KEY" \
    "{
        \"name\": \"Radarr\",
        \"implementation\": \"Radarr\",
        \"configContract\": \"RadarrSettings\",
        \"syncLevel\": \"fullSync\",
        \"fields\": [
            {\"name\": \"prowlarrUrl\", \"value\": \"http://prowlarr:9696\"},
            {\"name\": \"baseUrl\", \"value\": \"http://radarr:7878\"},
            {\"name\": \"apiKey\", \"value\": \"$RADARR_KEY\"},
            {\"name\": \"syncCategories\", \"value\": [2000, 2010, 2020, 2030, 2040, 2045, 2050, 2060, 2070, 2080]}
        ],
        \"tags\": []
    }"

# --- Connect Sonarr as app ---
api_post_json "Prowlarr connected to Sonarr" \
    "http://localhost:9696/api/v1/applications" \
    "$PROWLARR_KEY" \
    "{
        \"name\": \"Sonarr\",
        \"implementation\": \"Sonarr\",
        \"configContract\": \"SonarrSettings\",
        \"syncLevel\": \"fullSync\",
        \"fields\": [
            {\"name\": \"prowlarrUrl\", \"value\": \"http://prowlarr:9696\"},
            {\"name\": \"baseUrl\", \"value\": \"http://sonarr:8989\"},
            {\"name\": \"apiKey\", \"value\": \"$SONARR_KEY\"},
            {\"name\": \"syncCategories\", \"value\": [5000, 5010, 5020, 5030, 5040, 5045, 5050, 5060, 5070, 5080]}
        ],
        \"tags\": []
    }"

# --- Trigger Prowlarr to sync indexers to apps ---
api_post_json "Indexer sync triggered" \
    "http://localhost:9696/api/v1/command" \
    "$PROWLARR_KEY" \
    '{"name": "ApplicationIndexerSync"}'

echo ""

# ============================================================
# 6. Configure Seerr
# ============================================================

echo -e "${CYAN}[6/6] Configuring Seerr...${NC}"
echo ""
if [[ "$NON_INTERACTIVE" == true ]]; then
    if [[ "$MEDIA_SERVER" == "jellyfin" ]]; then
        warn "Non-interactive mode: skipping Seerr Jellyfin sign-in prompt."
        warn "Manually open http://localhost:5055, select \"Use your Jellyfin account\","
        warn "and enter http://jellyfin:8096 as the Jellyfin URL."
    else
        warn "Non-interactive mode: skipping Seerr Plex sign-in prompt."
        warn "Manually open http://localhost:5055 and sign in with Plex, then configure services in Seerr."
    fi
elif [[ "$MEDIA_SERVER" == "jellyfin" ]]; then
    echo -e "  ${YELLOW}ACTION NEEDED:${NC} Open ${CYAN}http://localhost:5055${NC} in your browser"
    echo "  1. Click \"Use your Jellyfin account\""
    echo "  2. Enter Jellyfin URL: ${CYAN}http://jellyfin:8096${NC}"
    echo "  3. Enter your Jellyfin username and password"
    echo ""
    read -p "  Press Enter after you've signed in to Seerr..."
    echo ""
    sleep 3
else
    echo -e "  ${YELLOW}ACTION NEEDED:${NC} Open ${CYAN}http://localhost:5055${NC} in your browser"
    echo "  and click \"Sign In With Plex\". Log in with your Plex account."
    echo ""
    read -p "  Press Enter after you've signed in to Seerr..."
    echo ""

    # Wait a moment for Seerr to process the login
    sleep 3
fi

# Get Seerr API key. The settings API requires a browser session cookie
# (connect.sid) that curl never has, even after the user signs in manually,
# so read it straight from Seerr's own settings file instead.
SEERR_KEY=$(grep -o '"apiKey": *"[^"]*"' "$MEDIA_DIR/config/seerr/settings.json" 2>/dev/null | head -1 | cut -d'"' -f4 || true)

if [[ -z "$SEERR_KEY" ]]; then
    warn "Could not get Seerr API key. You may need to configure Radarr/Sonarr in Seerr manually."
    warn "Go to Seerr Settings > Services and add Radarr (localhost:7878) and Sonarr (localhost:8989)."
else
    # Get default quality profile and root folder IDs/names from Radarr.
    # Radarr/Sonarr pretty-print with 2-space indent, so a top-level "id"
    # (2 levels deep: array + object) is anchored at exactly 4 spaces --
    # without that anchor, grep matches nested ids (e.g. quality.id) instead.
    RADARR_PROFILE_ID=$(curl -fsS "http://localhost:7878/api/v3/qualityprofile" -H "X-Api-Key: $RADARR_KEY" 2>/dev/null | grep -m1 '^    "id":' | grep -o '[0-9]*$' || true)
    RADARR_PROFILE_ID="${RADARR_PROFILE_ID:-1}"
    RADARR_PROFILE_NAME=$(curl -fsS "http://localhost:7878/api/v3/qualityprofile" -H "X-Api-Key: $RADARR_KEY" 2>/dev/null | grep -m1 '^    "name":' | sed 's/.*"name": *"\(.*\)",/\1/' || true)
    RADARR_PROFILE_NAME="${RADARR_PROFILE_NAME:-Any}"

    RADARR_ROOT_ID=$(curl -fsS "http://localhost:7878/api/v3/rootfolder" -H "X-Api-Key: $RADARR_KEY" 2>/dev/null | grep -m1 '^    "id":' | grep -o '[0-9]*$' || true)
    RADARR_ROOT_ID="${RADARR_ROOT_ID:-1}"

    # Get default quality profile and root folder IDs/names from Sonarr
    SONARR_PROFILE_ID=$(curl -fsS "http://localhost:8989/api/v3/qualityprofile" -H "X-Api-Key: $SONARR_KEY" 2>/dev/null | grep -m1 '^    "id":' | grep -o '[0-9]*$' || true)
    SONARR_PROFILE_ID="${SONARR_PROFILE_ID:-1}"
    SONARR_PROFILE_NAME=$(curl -fsS "http://localhost:8989/api/v3/qualityprofile" -H "X-Api-Key: $SONARR_KEY" 2>/dev/null | grep -m1 '^    "name":' | sed 's/.*"name": *"\(.*\)",/\1/' || true)
    SONARR_PROFILE_NAME="${SONARR_PROFILE_NAME:-Any}"

    SONARR_ROOT_ID=$(curl -fsS "http://localhost:8989/api/v3/rootfolder" -H "X-Api-Key: $SONARR_KEY" 2>/dev/null | grep -m1 '^    "id":' | grep -o '[0-9]*$' || true)
    SONARR_ROOT_ID="${SONARR_ROOT_ID:-1}"

    # Seerr's settings endpoints always append rather than dedupe, so look
    # for an existing entry (by hostname) and PUT to update it in place
    # instead of POST-ing a new one on every re-run.
    RADARR_SEERR_ID=$(curl -fsS "http://localhost:5055/api/v1/settings/radarr" -H "X-Api-Key: $SEERR_KEY" 2>/dev/null | grep -o '"hostname": *"radarr"[^}]*"id": *[0-9]*' | grep -o '[0-9]*$' | head -1 || true)
    if [[ -n "$RADARR_SEERR_ID" ]]; then
        RADARR_SEERR_URL="http://localhost:5055/api/v1/settings/radarr/$RADARR_SEERR_ID"
        RADARR_SEERR_METHOD="PUT"
    else
        RADARR_SEERR_URL="http://localhost:5055/api/v1/settings/radarr"
        RADARR_SEERR_METHOD="POST"
    fi

    api_post_json "Seerr connected to Radarr" \
        "$RADARR_SEERR_URL" \
        "$SEERR_KEY" \
        "{
            \"name\": \"Radarr\",
            \"hostname\": \"radarr\",
            \"port\": 7878,
            \"apiKey\": \"$RADARR_KEY\",
            \"useSsl\": false,
            \"activeProfileId\": $RADARR_PROFILE_ID,
            \"activeProfileName\": \"$RADARR_PROFILE_NAME\",
            \"activeDirectory\": \"/data/Movies\",
            \"minimumAvailability\": \"released\",
            \"is4k\": false,
            \"isDefault\": true,
            \"externalUrl\": \"http://localhost:7878\"
        }" \
        "$RADARR_SEERR_METHOD"

    SONARR_SEERR_ID=$(curl -fsS "http://localhost:5055/api/v1/settings/sonarr" -H "X-Api-Key: $SEERR_KEY" 2>/dev/null | grep -o '"hostname": *"sonarr"[^}]*"id": *[0-9]*' | grep -o '[0-9]*$' | head -1 || true)
    if [[ -n "$SONARR_SEERR_ID" ]]; then
        SONARR_SEERR_URL="http://localhost:5055/api/v1/settings/sonarr/$SONARR_SEERR_ID"
        SONARR_SEERR_METHOD="PUT"
    else
        SONARR_SEERR_URL="http://localhost:5055/api/v1/settings/sonarr"
        SONARR_SEERR_METHOD="POST"
    fi

    api_post_json "Seerr connected to Sonarr" \
        "$SONARR_SEERR_URL" \
        "$SEERR_KEY" \
        "{
            \"name\": \"Sonarr\",
            \"hostname\": \"sonarr\",
            \"port\": 8989,
            \"apiKey\": \"$SONARR_KEY\",
            \"useSsl\": false,
            \"activeProfileId\": $SONARR_PROFILE_ID,
            \"activeProfileName\": \"$SONARR_PROFILE_NAME\",
            \"activeDirectory\": \"/data/TV Shows\",
            \"activeAnimeProfileId\": $SONARR_PROFILE_ID,
            \"activeAnimeProfileName\": \"$SONARR_PROFILE_NAME\",
            \"activeAnimeDirectory\": \"/data/TV Shows\",
            \"is4k\": false,
            \"isDefault\": true,
            \"enableSeasonFolders\": true,
            \"externalUrl\": \"http://localhost:8989\"
        }" \
        "$SONARR_SEERR_METHOD"
fi

echo ""

# ============================================================
# Done!
# ============================================================

echo "=============================="
echo -e "  ${GREEN}Configuration complete!${NC}"
echo "=============================="
echo ""
echo "Your services are ready:"
echo ""
echo "  Seerr (browse & request):  http://localhost:5055"
if [[ "$MEDIA_SERVER" == "jellyfin" ]]; then
    echo "  Jellyfin (watch):          http://localhost:8096"
else
    echo "  Plex (watch):              http://localhost:32400/web"
fi
echo "  qBittorrent (downloads):   http://localhost:8080"
echo "    Username: admin"
echo "    Password: $QB_PASSWORD"
echo ""
echo "  Radarr (movie admin):      http://localhost:7878"
echo "  Sonarr (TV admin):         http://localhost:8989"
echo "  Prowlarr (indexer admin):  http://localhost:9696"
echo "  Bazarr (subtitles):        http://localhost:6767"
echo ""
echo -e "  ${YELLOW}Save your qBittorrent password:${NC} $QB_PASSWORD"
echo "  Saved credentials:         $CREDS_FILE"
echo ""
echo "To request a movie or show, open Seerr and search for it."
echo "Everything else is automatic."
echo ""
