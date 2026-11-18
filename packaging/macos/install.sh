#!/bin/sh
# Install garrett as a root LaunchDaemon. The code and credential live in a system-owned folder.
#   sudo sh install.sh          remove it again with: sudo sh install.sh --remove
set -eu
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
[ "$(id -u)" = 0 ] || { echo "Run this as root (sudo sh install.sh)." >&2; exit 1; }
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT='/Library/Application Support/Garrett'
STATE="$ROOT/state"
CONF="$ROOT/garrett.conf"
PLIST=/Library/LaunchDaemons/com.garrett.agent.plist
LOG=/private/var/log/garrett.log

private_path() {
  path=$1
  while :; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      [ ! -L "$path" ] || { echo "Unsafe garrett path: $path" >&2; exit 1; }
      [ "$(stat -f %u "$path")" = 0 ] || { echo "Unsafe garrett owner: $path" >&2; exit 1; }
      mode=$(stat -f %p "$path")
      [ $(( 0$mode & 0022 )) -eq 0 ] || { echo "Writable garrett path: $path" >&2; exit 1; }
      acl=$(ls -lde "$path")
      case "$acl" in *' allow '*) echo "Unverified garrett ACL: $path" >&2; exit 1 ;; esac
    fi
    [ "$path" = / ] && break
    path=${path%/*}
    [ -n "$path" ] || path=/
  done
}

for path in "$ROOT" "$ROOT/garrett" "$ROOT/garrett-agent" "$STATE" "$STATE/agent.json" "$CONF" /Library/LaunchDaemons "$PLIST" /private/var/log "$LOG"; do
  private_path "$path"
done

if [ "${1:-}" = --remove ]; then
  launchctl bootout system "$PLIST" >/dev/null 2>&1 || true
  rm -f "$PLIST" "$LOG"
  rm -rf "$ROOT"
  echo "garrett was removed."
  exit 0
fi

# An older release put root-run code and its token under /usr/local. Do not silently reuse or
# leave a possibly exposed credential there; revoke that device before installing the new layout.
for old in /usr/local/lib/garrett /usr/local/bin/garrett /usr/local/var/garrett /usr/local/etc/garrett.conf; do
  if [ -e "$old" ] || [ -L "$old" ]; then
    echo "An older /usr/local garrett install remains. Revoke its device and remove it before installing this release." >&2
    exit 1
  fi
done

install -d -m 0755 "$ROOT"
install -d -m 0700 "$STATE"
[ ! -e "$STATE/agent.json" ] || chmod 0600 "$STATE/agent.json"
install -m 0755 "$HERE/garrett-agent" "$ROOT/garrett-agent"
install -m 0755 "$HERE/garrett" "$ROOT/garrett"
[ -e "$CONF" ] || : > "$CONF"
chmod 0600 "$CONF"

cat > "$PLIST" <<'DAEMON'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.garrett.agent</string>
  <key>ProgramArguments</key>
  <array><string>/bin/sh</string><string>-c</string><string>"/Library/Application Support/Garrett/garrett" auto; exec "/Library/Application Support/Garrett/garrett" run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>20</integer>
  <key>StandardOutPath</key><string>/private/var/log/garrett.log</string>
  <key>StandardErrorPath</key><string>/private/var/log/garrett.log</string>
</dict>
</plist>
DAEMON
chmod 0644 "$PLIST"
[ -e "$LOG" ] || : > "$LOG"
chmod 0600 "$LOG"
launchctl bootout system "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap system "$PLIST"
echo "garrett is running. Its command: sudo \"$ROOT/garrett\". Its log: $LOG"
