# Image Lock Matrix

This stack is pinned to exact image digests in `docker-compose.yml` for reproducible installs.

Tested lock snapshot:
- Date: `2026-09-26`
- Docker Engine: `29.8.0`
- Platform: `aarch64 (Docker Desktop)`

| Service | Locked Image |
|---|---|
| flaresolverr | `ghcr.io/flaresolverr/flaresolverr@sha256:c80ae007ce2ccdcd217a12426e4f039ef763ff90738c808d38810c3e59323767` |
| prowlarr | `lscr.io/linuxserver/prowlarr@sha256:f2b26429893d4c4cb71941b7ee50b1bdecd9d5f9f9e02d5410615e9f4f7c8d95` |
| gluetun | `qmcgaw/gluetun@sha256:5cedd587404f96202060385d541faa4a73e51544ea098ec8d31c614f4d9c6ee0` |
| qbittorrent | `lscr.io/linuxserver/qbittorrent@sha256:caab2ebce30799ab342c374ea268fef4ec063a8ec3733a4e5d4a8e856ee32ce8` |
| radarr | `lscr.io/linuxserver/radarr@sha256:adb6c09d6b729ea5e642c99cea35af72702ef476bf4763f153299ac5db9f0b4f` |
| seerr | `ghcr.io/seerr-team/seerr@sha256:f4768de5f616248d723e05891f3345a1402123775d03bf0890dbfedc0831bda1` |
| watchtower (optional) | `containrrr/watchtower@sha256:6dd50763bbd632a83cb154d5451700530d1e44200b268a4e9488fefdfcf2b038` |
| bazarr | `lscr.io/linuxserver/bazarr@sha256:762f802274598da27255b2e5778f262b2b71b355a23e3812d9ee1520f8dbe37c` |
| jellyfin (optional) | `lscr.io/linuxserver/jellyfin@sha256:51252e7a416e703cdc3cd91e8a54673a2430cc80409be8a38abe511411577b95` |
| sonarr | `lscr.io/linuxserver/sonarr@sha256:f247545d23ba8b233d6604575347e48a623fe6ad75dda02348bf81917f3b5c06` |
| hbbs (optional) | `rustdesk/rustdesk-server@sha256:8ecdab65deb7c84652a626380e31d11a8f1fbafd97916d57f95c20628f943c00` |
| hbbr (optional) | `rustdesk/rustdesk-server@sha256:8ecdab65deb7c84652a626380e31d11a8f1fbafd97916d57f95c20628f943c00` |

## Updating The Lock

Run:
```bash
bash scripts/refresh-image-lock.sh
```

Then smoke test the stack and commit the updated lock files.
