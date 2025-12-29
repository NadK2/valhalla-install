#!/usr/bin/env bash
set -e

echo "▶ Valhalla UK bootstrap starting..."

# ------------------------------
# 1️⃣ Install Docker if missing
# ------------------------------
if ! command -v docker &> /dev/null; then
  echo "▶ Installing Docker..."
  sudo apt update
  sudo apt install -y ca-certificates curl gnupg lsb-release
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt update
  sudo apt install -y docker-ce docker-ce-cli containerd.io
  sudo usermod -aG docker $USER
  newgrp docker
fi

# ------------------------------
# 2️⃣ Install Docker Compose
# ------------------------------
if ! docker compose version &> /dev/null; then
  echo "▶ Installing Docker Compose..."
  sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
    -o /usr/local/bin/docker-compose
  sudo chmod +x /usr/local/bin/docker-compose
fi

# ------------------------------
# 3️⃣ Create Valhalla directories
# ------------------------------
BASE="$HOME/valhalla"
mkdir -p "$BASE"/{tiles,osm,scripts}

# ------------------------------
# 4️⃣ docker-compose.yml
# ------------------------------
cat > "$BASE/docker-compose.yml" <<EOF
version: '3.9'
services:
  valhalla:
    image: ghcr.io/valhalla/valhalla:latest
    container_name: valhalla
    ports:
      - "8002:8002"
    volumes:
      - ./tiles/current:/data/valhalla/tiles/current
      - ./osm:/data/valhalla/osm
      - ./valhalla.json:/valhalla.json
    command: valhalla_service /valhalla.json
    restart: unless-stopped
EOF

# ------------------------------
# 5️⃣ valhalla.json
# ------------------------------
cat > "$BASE/valhalla.json" <<EOF
{
  "mjolnir": {
    "tile_dir": "/data/valhalla/tiles/current",
    "tile_extract": "/data/valhalla/tiles.tar",
    "concurrency": 4
  },
  "loki": { "use_connectivity": true },
  "thor": {},
  "skadi": { "actives": ["Europe/London"] }
}
EOF

# ------------------------------
# 6️⃣ Update script
# ------------------------------
cat > "$BASE/scripts/update-valhalla.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BASE="$HOME/valhalla"
TILES="$BASE/tiles"
OSM="$BASE/osm"
OSM_FILE="$OSM/great-britain-latest.osm.pbf"
DATE=$(date +%Y_%m_%d_%H%M)
NEW_TILES="$TILES/tiles_$DATE"
IMG="ghcr.io/valhalla/valhalla:latest"

REMOTE_SHA=$(curl -s https://download.geofabrik.de/europe/great-britain-latest.osm.pbf.sha256)
LOCAL_SHA=$(sha256sum "$OSM_FILE" 2>/dev/null | cut -d' ' -f1 || echo "")

if [ "$REMOTE_SHA" = "$LOCAL_SHA" ]; then
  echo "▶ OSM unchanged, skipping rebuild"
  exit 0
fi

echo "▶ Downloading new UK OSM extract..."
wget -q -O "$OSM_FILE" https://download.geofabrik.de/europe/great-britain-latest.osm.pbf

mkdir -p "$NEW_TILES"

# -------------------------------------------------
# Create TEMP config that writes into NEW_TILES
# -------------------------------------------------
TMP_CONFIG="$BASE/valhalla.build.json"

jq --arg dir "/data/valhalla/tiles/$(basename "$NEW_TILES")" \
  '.mjolnir.tile_dir = $dir' \
  "$BASE/valhalla.json" > "$TMP_CONFIG"

docker pull "$IMG" > /dev/null

echo "▶ Building tiles in $NEW_TILES"

docker run --rm \
  -v "$BASE:/data/valhalla" \
  "$IMG" \
  valhalla_build_tiles \
  -c /data/valhalla/valhalla.build.json \
  /data/valhalla/osm/great-britain-latest.osm.pbf

docker run --rm \
  -v "$BASE:/data/valhalla" \
  "$IMG" \
  valhalla_build_extract \
  -c /data/valhalla/valhalla.build.json

# -------------------------------------------------
# Atomic symlink swap
# -------------------------------------------------
ln -sfn "$(basename "$NEW_TILES")" "$TILES/current"

# Restart service (milliseconds)
cd "$BASE"
docker compose restart valhalla

# Cleanup
ls -dt "$TILES"/tiles_* | tail -n +3 | xargs -r rm -rf

rm -f "$TMP_CONFIG"

echo "✅ Valhalla updated with ZERO downtime"
EOF

chmod +x "$BASE/scripts/update-valhalla.sh"

# ------------------------------
# 7️⃣ First build
# ------------------------------
cd "$BASE"
docker compose up -d
"$BASE/scripts/update-valhalla.sh"

# ------------------------------
# 8️⃣ Cron job (4 AM)
# ------------------------------
(crontab -l 2>/dev/null; echo "0 4 * * * $BASE/scripts/update-valhalla.sh >> $BASE/valhalla-update.log 2>&1") | crontab -

echo "✅ Valhalla UK installed and running"
echo "➡ API: http://localhost:8002/route"
