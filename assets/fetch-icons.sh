#!/bin/bash
# Fetch vertical tile art (600x900 capsule) from the Steam CDN for Moonlight tiles.
# Sunshine accepts one image per app (apps.json "image-path"); the 2:3 capsule
# renders much better on Moonlight's square-ish tiles than the horizontal
# store banner. Requires: curl, and ImageMagick's `convert` if you want PNG.
set -euo pipefail
OUT="${1:-.}"

# appid: name
APPS=(
  "2868840:Slay the Spire 2"
  "427520:Factorio"
)

for entry in "${APPS[@]}"; do
  appid="${entry%%:*}"; name="${entry#*:}"
  slug="$(echo "$name" | tr '[:upper:] ' '[:lower:]_')"
  url="https://cdn.cloudflare.steamstatic.com/steam/apps/$appid/library_600x900_2x.jpg"
  echo "fetching $name ($appid)..."
  curl -fsSL "$url" -o "$OUT/$slug.jpg"
  if command -v convert >/dev/null; then
    convert "$OUT/$slug.jpg" "$OUT/$slug.png" && rm "$OUT/$slug.jpg"
    echo "  -> $OUT/$slug.png"
  else
    echo "  -> $OUT/$slug.jpg (install imagemagick to convert to png)"
  fi
done
# Moonlight caches tile art client-side: restart the client after replacing art.
