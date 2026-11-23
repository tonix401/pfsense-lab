#!/usr/bin/env bash
# Downloads the pfSense CE ISO into iso/ and checks it against hashes pinned here, so a file
# swapped on a mirror is caught too. Skips the download when a good ISO is already there.
set -euo pipefail

name=pfSense-CE-2.7.2-RELEASE-amd64.iso
gz_sha256=883fb7bc64fe548442ed007911341dd34e178449f8156ad65f7381a02b7cd9e4
iso_sha256=441005f79ea0c155bc4b830a2b4207f8c0804cf7b075d2a6489c0a136cbc5d51
mirrors=(
  https://atxfiles.netgate.com/mirror/downloads # Netgate's own mirror
  https://repo.ialab.dsu.edu/pfsense            # Dakota State University mirror
)

dir="$(cd "$(dirname "$0")/.." && pwd)/iso"
mkdir -p "$dir"
cd "$dir"

if [[ -f "$name" ]] && echo "$iso_sha256  $name" | sha256sum -c --quiet 2>/dev/null; then
  echo "$dir/$name is already there and verified"
  exit 0
fi

for m in "${mirrors[@]}"; do
  echo "downloading from $m"
  if curl -fL --retry 3 -C - -o "$name.gz" "$m/$name.gz" \
     && echo "$gz_sha256  $name.gz" | sha256sum -c --quiet; then
    gunzip -f "$name.gz"
    echo "$iso_sha256  $name" | sha256sum -c --quiet
    echo "$dir/$name verified"
    exit 0
  fi
  echo "download or checksum failed from $m" >&2
  rm -f "$name.gz"
done
echo "no mirror delivered a valid ISO" >&2
exit 1
