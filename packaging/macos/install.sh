#!/bin/sh
# Install garrett on this Mac as a LaunchDaemon (it starts at boot and is restarted if it stops).
#   sudo sh install.sh          remove it again with:  sudo sh install.sh --remove
# The agent is one program file that runs on Apple silicon and Intel Macs alike. Nothing else has to be installed.
set -eu
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
[ "$(id -u)" = 0 ] || { echo "Run this as root (sudo sh install.sh)." >&2; exit 1; }
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PLIST=/Library/LaunchDaemons/com.garrett.agent.plist
if [ "${1:-}" = --remove ]; then
  launchctl bootout system "$PLIST" >/dev/null 2>&1 || true
  rm -rf "$PLIST" /usr/local/lib/garrett /usr/local/bin/garrett /usr/local/var/garrett /usr/local/etc/garrett.conf
  echo "garrett was removed."
  exit 0
fi
# The LaunchDaemon runs from shared /usr/local paths. On a Mac where a desktop user can
# write one of those paths, installing there would let that user replace root-run code.
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
for path in /usr/local /usr/local/bin /usr/local/bin/garrett /usr/local/lib /usr/local/lib/garrett /usr/local/lib/garrett/garrett /usr/local/lib/garrett/garrett-agent /usr/local/etc /usr/local/etc/garrett.conf /usr/local/var /usr/local/var/garrett /Library/LaunchDaemons "$PLIST" /private/var/log /private/var/log/garrett.log; do
  private_path "$path"
done
install -d -m 0755 /usr/local/lib/garrett /usr/local/bin /usr/local/etc
install -d -m 0700 /usr/local/var/garrett
install -m 0755 "$HERE/garrett-agent" /usr/local/lib/garrett/garrett-agent
install -m 0755 "$HERE/garrett" /usr/local/lib/garrett/garrett
# The command people type: the shared launcher, pointed at this system's folders.
cat > /usr/local/bin/garrett <<'WRAPPER'
#!/bin/sh
PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH
GARRETT_LIB=/usr/local/lib/garrett GARRETT_STATE_DIR=/usr/local/var/garrett GARRETT_CONF=/usr/local/etc/garrett.conf exec /bin/sh /usr/local/lib/garrett/garrett "$@"
WRAPPER
chmod 0755 /usr/local/bin/garrett
cat > "$PLIST" <<'DAEMON'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.garrett.agent</string>
  <key>ProgramArguments</key>
  <array><string>/bin/sh</string><string>-c</string><string>/usr/local/bin/garrett auto; exec /usr/local/bin/garrett run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>20</integer>
  <key>StandardOutPath</key><string>/var/log/garrett.log</string>
  <key>StandardErrorPath</key><string>/var/log/garrett.log</string>
</dict>
</plist>
DAEMON
chmod 0644 "$PLIST"
[ -e /private/var/log/garrett.log ] || : > /private/var/log/garrett.log
chmod 0600 /private/var/log/garrett.log
launchctl bootout system "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap system "$PLIST"
echo "garrett is running. Its log: /var/log/garrett.log"
