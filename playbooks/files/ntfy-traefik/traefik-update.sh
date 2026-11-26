#!/bin/bash
# Managed by Ansible (traefik-standards.yml) - edit in the playbooks repo, not on the host.
# Daily (traefik-update.timer): install the newest Traefik v3.x release.
#  - stays on major version 3; a new major is a deliberate, manual move
#  - verifies the download against the release's published sha256 checksums
#  - installs root:root 0755, keeps the previous binary, rolls back if Traefik doesn't come up
#  - notifies ntfy only when something changed or failed
set -euo pipefail

MAJOR=3
BIN=/usr/local/bin/traefik
REPO=https://github.com/traefik/traefik/releases/download

notify() { printf '%s\n' "$2" | /usr/local/bin/ntfy-sendmail -s "$1" || true; }
fail()   { notify "Traefik update FAILED on $(hostname)" "$1"; exit 1; }

current="v$("$BIN" version 2>/dev/null | awk '/^Version:/ {print $2}')"

# Newest stable v3.x tag (release candidates have a suffix and don't match)
latest=$(curl -fsS --max-time 30 "https://api.github.com/repos/traefik/traefik/releases?per_page=50" \
  | grep -oE "\"tag_name\": *\"v${MAJOR}\.[0-9]+\.[0-9]+\"" | grep -oE "v${MAJOR}\.[0-9]+\.[0-9]+" \
  | sort -V | tail -n 1) || true
[ -n "$latest" ] || fail "Could not read the latest v${MAJOR}.x release from GitHub."

[ "$current" = "$latest" ] && exit 0

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
cd "$tmp"
tarball="traefik_${latest}_linux_amd64.tar.gz"
curl -fsSL --max-time 300 -o "$tarball" "$REPO/$latest/$tarball" || fail "Download of $tarball failed."
curl -fsSL --max-time 60 -o checksums.txt "$REPO/$latest/traefik_${latest}_checksums.txt" || fail "Download of the checksums for $latest failed."
grep -E "  ${tarball}\$" checksums.txt > expected.txt || fail "No checksum listed for $tarball."
sha256sum -c --status expected.txt || fail "Checksum mismatch for $tarball; nothing installed."

tar -xzf "$tarball" traefik
./traefik version >/dev/null 2>&1 || fail "Downloaded $latest binary does not run; nothing installed."

install -o root -g root -m 0755 "$BIN" "$BIN.prev"
install -o root -g root -m 0755 traefik "$BIN.new"
systemctl stop traefik
mv -f "$BIN.new" "$BIN"
systemctl start traefik
sleep 5

if systemctl is-active --quiet traefik; then
  notify "Traefik updated on $(hostname)" "Traefik updated from $current to $latest (checksum verified)."
else
  mv -f "$BIN.prev" "$BIN"
  systemctl restart traefik || true
  fail "Traefik $latest did not start; rolled back to $current."
fi
