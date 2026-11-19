#!/bin/sh
# Ready the Ansible collection (deploy/ansible) and the Puppet module (deploy/puppet) for building: copies of both,
# with this checkout's version (rust/Cargo.toml) and its LICENSE.
#
#   sh deploy/stage-fleet.sh <output folder>
#
#   <output>/ansible   the collection gary23w.sentinels:  cd <output>/ansible && ansible-galaxy collection build
#   <output>/garrett   the module gary23w-garrett, in a folder of its short name:  cd <output>/garrett && pdk build
#
# The release workflow builds, checks and runs both, and publishes them to Ansible Galaxy and the Puppet Forge with
# each tag.
set -eu
[ $# -eq 1 ] || { echo "Usage: $0 <output folder>" >&2; exit 1; }
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=$1
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' "$HERE/rust/Cargo.toml" | head -1)
[ -n "$VERSION" ] || { echo "No version in rust/Cargo.toml." >&2; exit 1; }
rm -rf "$OUT/ansible" "$OUT/garrett"
mkdir -p "$OUT"
cp -R "$HERE/deploy/ansible" "$OUT/ansible"
cp -R "$HERE/deploy/puppet" "$OUT/garrett"
for dir in "$OUT/ansible" "$OUT/garrett"; do
  cp "$HERE/LICENSE" "$dir/LICENSE"
  # A checkout on Windows keeps its line ends out of what is published.
  find "$dir" -type f | while IFS= read -r file; do sed 's/\r$//' "$file" > "$file.lf" && mv "$file.lf" "$file"; done
done
for file in "$OUT/ansible/galaxy.yml" "$OUT/garrett/metadata.json"; do
  sed "s/@VERSION@/$VERSION/" "$file" > "$file.new" && mv "$file.new" "$file"
done
if grep -q "@VERSION@" "$OUT/ansible/galaxy.yml" "$OUT/garrett/metadata.json"; then echo "The version was not written." >&2; exit 1; fi
echo "gary23w.sentinels and gary23w-garrett $VERSION, ready to build in $OUT"
