#!/bin/sh
# Install garrett on this FreeBSD machine as a service (it starts at boot and is restarted if it stops).
#   sh install.sh          remove it again with:  sh install.sh --remove
# Run it as root. The agent is one program file; nothing else has to be installed, and no firewall has to be on.
set -eu
PATH=/sbin:/bin:/usr/sbin:/usr/bin
export PATH
[ "$(id -u)" = 0 ] || { echo "Run this as root." >&2; exit 1; }
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RC=/usr/local/etc/rc.d/garrett
if [ "${1:-}" = --remove ]; then
  [ -x "$RC" ] && service garrett stop >/dev/null 2>&1 || true
  sysrc -x garrett_enable >/dev/null 2>&1 || true
  rm -rf "$RC" /usr/local/lib/garrett /usr/local/bin/garrett /var/db/garrett /usr/local/etc/garrett.conf /var/run/garrett.pid
  echo "garrett was removed."
  exit 0
fi
install -d -m 0755 /usr/local/lib/garrett /usr/local/bin /usr/local/etc/rc.d
install -d -m 0700 /var/db/garrett
install -m 0755 "$HERE/garrett-agent" /usr/local/lib/garrett/garrett-agent
install -m 0755 "$HERE/garrett" /usr/local/lib/garrett/garrett
# The command people type: the shared launcher, pointed at this system's folders.
cat > /usr/local/bin/garrett <<'WRAPPER'
#!/bin/sh
PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH
GARRETT_LIB=/usr/local/lib/garrett GARRETT_STATE_DIR=/var/db/garrett GARRETT_CONF=/usr/local/etc/garrett.conf exec /bin/sh /usr/local/lib/garrett/garrett "$@"
WRAPPER
chmod 0755 /usr/local/bin/garrett
install -m 0755 "$HERE/garrett.rc" "$RC"
sysrc garrett_enable=YES >/dev/null
service garrett stop >/dev/null 2>&1 || true
service garrett start
echo "garrett is running. Check: service garrett status. Its log: /var/log/garrett.log"
