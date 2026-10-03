#!/bin/bash
# Media Stack Auto-Healer
# Runs hourly via launchd. Checks VPN and container health, restarts what's broken.

# launchd starts jobs with a bare PATH (/usr/bin:/bin:/usr/sbin:/sbin), which
# misses docker for both Docker Desktop and OrbStack.
export PATH="$HOME/.orbstack/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/media-path.sh
source "$SCRIPT_DIR/lib/media-path.sh"

MEDIA_DIR="$(resolve_media_dir "$PROJECT_DIR")"
LOG_DIR="$MEDIA_DIR/logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/auto-heal.log"

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }

log() { echo "$(timestamp) $1" >> "$LOG"; }

# Trim log to last 500 lines
if [[ -f "$LOG" ]] && [[ $(wc -l < "$LOG") -gt 500 ]]; then
    tail -500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

log "--- Health check started ---"

# Check Docker is running
if ! docker info &>/dev/null; then
    log "ERROR: Container runtime not running. Cannot heal."
    exit 1
fi

HEALED=0

# Check VPN tunnel
vpn_ip=$(docker exec gluetun sh -lc 'cat /tmp/gluetun/ip 2>/dev/null || true' 2>/dev/null)
vpn_iface=$(docker exec gluetun sh -lc 'ls /sys/class/net 2>/dev/null | grep -E "^(tun|wg)[0-9]+$" | head -1' 2>/dev/null)
vpn_health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}' gluetun 2>/dev/null || true)

if [[ -z "$vpn_ip" || -z "$vpn_iface" || "$vpn_health" == "unhealthy" ]]; then
    log "WARN: VPN status unhealthy (health=${vpn_health:-unknown}, ip=${vpn_ip:-none}, iface=${vpn_iface:-none}). Restarting gluetun..."
    docker restart gluetun >> "$LOG" 2>&1
    sleep 15
    vpn_ip=$(docker exec gluetun sh -lc 'cat /tmp/gluetun/ip 2>/dev/null || true' 2>/dev/null)
    vpn_iface=$(docker exec gluetun sh -lc 'ls /sys/class/net 2>/dev/null | grep -E "^(tun|wg)[0-9]+$" | head -1' 2>/dev/null)
    vpn_health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}' gluetun 2>/dev/null || true)
    if [[ -n "$vpn_ip" && -n "$vpn_iface" && "$vpn_health" != "unhealthy" ]]; then
        log "OK: VPN recovered (IP: $vpn_ip, iface=$vpn_iface, health=${vpn_health:-unknown})"
        ((HEALED++))
    else
        log "ERROR: VPN still down after restart (health=${vpn_health:-unknown}, ip=${vpn_ip:-none}, iface=${vpn_iface:-none})"
    fi
else
    log "OK: VPN active (IP: $vpn_ip, iface=$vpn_iface, health=${vpn_health:-unknown})"
fi

# Check core containers are running
for name in gluetun qbittorrent prowlarr sonarr radarr bazarr flaresolverr seerr; do
    state=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null)
    if [[ "$state" != "running" ]]; then
        log "WARN: $name is $state. Starting..."
        docker start "$name" >> "$LOG" 2>&1
        ((HEALED++))
    fi
done

# Clear out dead torrents. A download with no seeds that hasn't progressed in
# STALLED_TORRENT_HOURS is removed through Sonarr/Radarr with blocklisting, so
# the arr searches again for a different release instead of waiting forever.
# Progress is tracked across runs in a state file, since qBittorrent's own
# last_activity also ticks on upload and peer chatter.
STALLED_TORRENT_HOURS="${STALLED_TORRENT_HOURS:-48}"
STALL_STATE="$MEDIA_DIR/state/stalled-torrents.json"

arr_api_key() {
    grep -o '<ApiKey>[^<]*</ApiKey>' "$MEDIA_DIR/config/$1/config.xml" 2>/dev/null | sed 's/<[^>]*>//g'
}

if ! command -v jq &>/dev/null; then
    log "WARN: jq not found, skipping stalled torrent check"
elif torrents=$(docker exec qbittorrent curl -sf http://127.0.0.1:8080/api/v2/torrents/info 2>/dev/null) && [[ -n "$torrents" ]]; then
    mkdir -p "$(dirname "$STALL_STATE")"
    prev_state=$(cat "$STALL_STATE" 2>/dev/null || echo '{}')
    jq -e type <<< "$prev_state" &>/dev/null || prev_state='{}'
    now=$(date +%s)

    # since = when progress last changed. Queued/paused torrents never had a
    # chance to download, so their clock stays reset until they're started.
    new_state=$(jq --argjson prev "$prev_state" --argjson now "$now" '
        map(select(.progress < 1)) | map({
            key: .hash,
            value: {
                progress: .progress,
                since: (
                    if (.state | test("^(queued|paused|stopped)")) then $now
                    elif ($prev[.hash] and $prev[.hash].progress == .progress) then $prev[.hash].since
                    elif $prev[.hash] then $now
                    else ([$now, (if .last_activity > 0 then .last_activity else .added_on end)] | min)
                    end)
            }
        }) | from_entries' <<< "$torrents")
    echo "$new_state" > "$STALL_STATE.tmp" && mv "$STALL_STATE.tmp" "$STALL_STATE"

    stalled=$(jq -r --argjson st "$new_state" --argjson now "$now" --argjson limit "$((STALLED_TORRENT_HOURS * 3600))" '
        .[] | select(.progress < 1 and .num_seeds == 0 and (.state == "stalledDL" or .state == "metaDL"))
            | select($st[.hash] and ($now - $st[.hash].since) > $limit)
            | "\(.hash)\t\(.name)"' <<< "$torrents")

    if [[ -n "$stalled" ]]; then
        # Fetch each arr's queue once. Plain variables rather than an
        # associative array: launchd runs macOS's bash 3.2.
        sonarr_key=$(arr_api_key sonarr)
        radarr_key=$(arr_api_key radarr)
        sonarr_queue=""
        radarr_queue=""
        [[ -n "$sonarr_key" ]] && sonarr_queue=$(curl -sf -H "X-Api-Key: $sonarr_key" \
            "http://localhost:8989/api/v3/queue?pageSize=1000&includeUnknownSeriesItems=true" 2>/dev/null)
        [[ -n "$radarr_key" ]] && radarr_queue=$(curl -sf -H "X-Api-Key: $radarr_key" \
            "http://localhost:7878/api/v3/queue?pageSize=1000&includeUnknownMovieItems=true" 2>/dev/null)

        while IFS=$'\t' read -r hash tname; do
            handled=0
            for arr in sonarr:8989 radarr:7878; do
                name=${arr%%:*}
                if [[ "$name" == "sonarr" ]]; then
                    queue=$sonarr_queue; key=$sonarr_key
                else
                    queue=$radarr_queue; key=$radarr_key
                fi
                [[ -z "$queue" ]] && continue
                ids=$(jq -c --arg h "$hash" '[.records[]? | select((.downloadId // "" | ascii_downcase) == ($h | ascii_downcase)) | .id]' <<< "$queue" 2>/dev/null)
                [[ -z "$ids" || "$ids" == "[]" ]] && continue
                if curl -sf -X DELETE -H "X-Api-Key: $key" -H "Content-Type: application/json" \
                    -d "{\"ids\": $ids}" \
                    "http://localhost:${arr##*:}/api/v3/queue/bulk?removeFromClient=true&blocklist=true" &>/dev/null; then
                    log "FIXED: Removed stalled torrent via $name (blocklisted, re-searching): $tname"
                    ((HEALED++))
                else
                    log "ERROR: $name failed to remove stalled torrent: $tname"
                fi
                handled=1
            done
            [[ $handled -eq 0 ]] && log "WARN: Stalled torrent not managed by Sonarr/Radarr, leaving it: $tname"
        done <<< "$stalled"
    fi
else
    log "WARN: Could not query qBittorrent, skipping stalled torrent check"
fi

if [[ $HEALED -gt 0 ]]; then
    log "Healed $HEALED issue(s)"
else
    log "All healthy"
fi
