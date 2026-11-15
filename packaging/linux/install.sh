#!/bin/sh
# Install garrett from this folder on a Linux machine that has no apt (Fedora, RHEL, SUSE, Arch, Alpine and others).
#   sudo sh install.sh          remove it again with:  sudo sh install.sh --remove
set -eu
[ "$(id -u)" = 0 ] || { echo "Run this as root." >&2; exit 1; }
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ "${1:-}" = --remove ]; then
  if [ -d /run/systemd/system ]; then systemctl disable --now garrett.service >/dev/null 2>&1 || true; fi
  /usr/lib/garrett/unblock 2>/dev/null || true
  rm -rf /usr/lib/garrett /usr/bin/garrett /etc/systemd/system/garrett.service /var/lib/garrett /etc/garrett
  if [ -d /run/systemd/system ]; then systemctl daemon-reload || true; fi
  echo "garrett was removed."
  exit 0
fi
command -v ss >/dev/null 2>&1 || { echo "The ss command (package iproute or iproute2) is required." >&2; exit 1; }
install -d -m 0755 /usr/lib/garrett
install -m 0755 "$HERE/garrett-agent" /usr/lib/garrett/garrett-agent
install -m 0755 "$HERE/unblock" /usr/lib/garrett/unblock
install -m 0755 "$HERE/garrett" /usr/bin/garrett
if [ -d /run/systemd/system ]; then
  install -m 0644 "$HERE/garrett.service" /etc/systemd/system/garrett.service
  systemctl daemon-reload
  systemctl enable garrett.service >/dev/null 2>&1 || true
  systemctl restart garrett.service
  echo "garrett is running. Check: systemctl status garrett"
else
  echo "garrett is installed. This machine has no systemd: start it from your own supervisor with:  garrett auto && garrett run"
fi
