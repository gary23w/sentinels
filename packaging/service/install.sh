#!/bin/sh
# Turn this Linux machine into your own Sentinel service, from this folder.
#   sudo sh install.sh [--port 8443] [--address <name or address other machines reach this one by>] [--memory neuron-db|off]
#                      [--model crivo-sentinel-v1|off] [--wizard]
#   sudo sh install.sh --remove
#
# It installs the service under /usr/lib/garrett-service, makes its keys and its own HTTPS certificate, runs it as
# the unprivileged user garrett-service, and prints the command that joins other machines to it.
# Beside this file there may be, as the one-file installer (garrett-sentinels-linux-*) carries them:
#   node       the Node.js runtime; otherwise the official build is fetched from nodejs.org and checked
#   model/     the decision model that comes with Sentinels (crivo-sentinel-v1): the service runs it in its own
#              process and decides what happens to a frozen program with it, unless --model off
#   agent/     the Sentinel agent for this machine: installed and joined to this service, so the machine that runs
#              the service is protected too (left alone when garrett is already installed)
# --wizard asks a few questions first (the port and address, the model that decides or one of your own, how much
# it may decide) instead of taking the defaults.
# Running it again upgrades the program and keeps the keys, the certificate, the database and the settings; only
# what is asked for on the command line changes.
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
[ "$(id -u)" = 0 ] || { echo "Run this as root." >&2; exit 1; }
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LIB=/usr/lib/garrett-service; ETC=/etc/garrett-service; DATA=/var/lib/garrett-service; UNIT=/etc/systemd/system/garrett-service.service
NODE_VERSION=v24.22.3
NODE_SUM_x64=061ec3e3062115705b56b51fa9cc330ab50d34b6969387d4e4b1a50c6809acc2
NODE_SUM_arm64=261af2af250dfd7e9f25cf151d1b2713a0adf8f10a9ad116c4947f68627affe8
BUNDLED=crivo-sentinel-v1
PORT=""; ADDRESS=""; REMOVE=""; MEMORY=""; MODEL=""; WIZARD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT=$2; shift 2 ;;
    --address) ADDRESS=$2; shift 2 ;;
    --memory) MEMORY=$2; shift 2 ;;
    --model) MODEL=$2; shift 2 ;;
    --wizard) WIZARD=1; shift ;;
    --remove) REMOVE=1; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done
if [ -n "$REMOVE" ]; then
  # The agent this installer put on the machine goes with it; one installed any other way stays.
  [ ! -f "$ETC/agent-installed" ] || [ ! -f "$LIB/agent-install.sh" ] || sh "$LIB/agent-install.sh" --remove >/dev/null 2>&1 || true
  systemctl disable --now garrett-service.service >/dev/null 2>&1 || true
  rm -rf "$LIB" "$ETC" "$DATA" "$UNIT" /usr/bin/garrett-service
  systemctl daemon-reload 2>/dev/null || true
  userdel garrett-service >/dev/null 2>&1 || true
  echo "The Sentinel service, its model, its keys and its database were removed. Machines that reported to it protect themselves alone until they are enrolled somewhere else."
  exit 0
fi
[ -d /run/systemd/system ] || { echo "This installer needs systemd. On other systems run:  node serve.mjs <configuration file>  from your own supervisor (see serve.mjs)." >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "openssl is required. Install it with your package manager and run this again." >&2; exit 1; }
case "$PORT" in *[!0-9]*) echo "The port must be a number." >&2; exit 1 ;; esac
case "$MEMORY" in ""|off) ;; neuron-db) [ -f "$HERE/node_modules/@gary23w/neuron-db/neuron_core.wasm" ] || { echo "This bundle was built without neuron-db, so --memory neuron-db cannot be used." >&2; exit 1; } ;; *) echo "The memory must be neuron-db or off." >&2; exit 1 ;; esac
case "$MODEL" in ""|off|"$BUNDLED") ;; *) echo "The model must be $BUNDLED or off." >&2; exit 1 ;; esac
[ "$MODEL" != "$BUNDLED" ] || [ -f "$HERE/model/model.onnx" ] || { echo "This bundle does not carry the decision model. The one-file installer, garrett-sentinels-linux-*, does." >&2; exit 1; }
fetch() { if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"; else wget -q "$1" -O "$2"; fi; }
setting() { sed -n "s/^$1=//p" "$ETC/service.conf" | tail -n 1; }
# put NAME VALUE: the line NAME=VALUE in service.conf, replacing the one there or added at the end.
put() {
  awk -v name="$1" -v value="$2" 'index($0, name "=") == 1 { if (!done) { print name "=" value; done = 1 }; next } { print } END { if (!done) print name "=" value }' "$ETC/service.conf" > "$ETC/service.conf.new"
  mv "$ETC/service.conf.new" "$ETC/service.conf"
  chown root:garrett-service "$ETC/service.conf"; chmod 0640 "$ETC/service.conf"
}

umask 022
install -d -m 0755 "$LIB" "$LIB/src"
install -m 0644 "$HERE/serve.mjs" "$HERE/sqlite.mjs" "$HERE/setup.mjs" "$HERE/schema.sql" "$HERE/LICENSE" "$LIB/"
install -m 0644 "$HERE"/src/*.mjs "$LIB/src/"
# The packages the bundle carries: the optional memory engine, and what runs the decision model in the service.
rm -rf "$LIB/node_modules"
[ ! -d "$HERE/node_modules" ] || { cp -R "$HERE/node_modules" "$LIB/node_modules"; chown -R root:root "$LIB/node_modules"; chmod -R u=rwX,go=rX "$LIB/node_modules"; }
install -m 0755 "$HERE/garrett-service" /usr/bin/garrett-service
# The decision model, when it is beside this file.
if [ -f "$HERE/model/model.onnx" ]; then
  install -d -m 0755 "$LIB/model"
  install -m 0644 "$HERE"/model/* "$LIB/model/"
fi

# Node.js: the one this installer carries; else the one already here if it is new enough; else the official
# build from nodejs.org, checked against the SHA-256 this installer was published with.
NODE=""
if [ -f "$HERE/node" ]; then install -m 0755 "$HERE/node" "$LIB/node"; NODE=$LIB/node; fi
if [ -z "$NODE" ] && command -v node >/dev/null 2>&1 && node -e "require('node:sqlite'); process.exit(Number(process.versions.node.split('.')[0]) >= 22 ? 0 : 1)" >/dev/null 2>&1; then NODE=$(command -v node); fi
if [ -z "$NODE" ] && [ -x "$LIB/node" ] && [ "$("$LIB/node" --version 2>/dev/null)" = "$NODE_VERSION" ]; then NODE=$LIB/node; fi
if [ -z "$NODE" ]; then
  case "$(uname -m)" in
    x86_64|amd64) ARCH=x64; WANT=$NODE_SUM_x64 ;;
    aarch64|arm64) ARCH=arm64; WANT=$NODE_SUM_arm64 ;;
    *) echo "No Node.js 22.13 or newer was found, and there is no official build to fetch for $(uname -m). Install Node.js and run this again." >&2; exit 1 ;;
  esac
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || { echo "curl or wget is required to fetch Node.js. Install one and run this again." >&2; exit 1; }
  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' EXIT
  NAME=node-$NODE_VERSION-linux-$ARCH
  echo "Fetching Node.js $NODE_VERSION from nodejs.org ..."
  fetch "https://nodejs.org/dist/$NODE_VERSION/$NAME.tar.gz" "$WORK/node.tar.gz"
  HAVE=$(sha256sum "$WORK/node.tar.gz" | cut -d' ' -f1)
  [ "$WANT" = "$HAVE" ] || { echo "The Node.js download does not match its published checksum. Nothing was started." >&2; exit 1; }
  tar -xzf "$WORK/node.tar.gz" -C "$WORK" "$NAME/bin/node"
  install -m 0755 "$WORK/$NAME/bin/node" "$LIB/node"
  NODE=$LIB/node
fi

# The wizard: its answers stand in for the command line, and its model lines go into service.conf below.
ANSWERS=""
if [ -n "$WIZARD" ]; then
  [ -t 0 ] || [ -r /dev/tty ] || { echo "--wizard needs a terminal to ask its questions in." >&2; exit 1; }
  ANSWERS=$(mktemp)
  MEMORY_FLAG=""; [ -f "$HERE/node_modules/@gary23w/neuron-db/neuron_core.wasm" ] || MEMORY_FLAG=--no-memory
  if [ -t 0 ]; then "$NODE" --disable-warning=ExperimentalWarning "$LIB/setup.mjs" --install "$ANSWERS" $MEMORY_FLAG
  else "$NODE" --disable-warning=ExperimentalWarning "$LIB/setup.mjs" --install "$ANSWERS" $MEMORY_FLAG </dev/tty; fi
  [ -s "$ANSWERS" ] || { rm -f "$ANSWERS"; echo "Setup was not completed. Nothing was changed." >&2; exit 1; }
  PORT=$(sed -n 's/^PORT=//p' "$ANSWERS"); ADDRESS=$(sed -n 's/^ADDRESS=//p' "$ANSWERS")
  MEMORY=$(sed -n 's/^MEMORY=//p' "$ANSWERS"); MODEL=$(sed -n 's/^MODEL=//p' "$ANSWERS")
  [ "$MODEL" != "$BUNDLED" ] || [ -f "$LIB/model/model.onnx" ] || { rm -f "$ANSWERS"; echo "This bundle does not carry the decision model; choose another model or none." >&2; exit 1; }
fi

id garrett-service >/dev/null 2>&1 || useradd --system --home-dir "$DATA" --shell /usr/sbin/nologin garrett-service
install -d -m 0750 -o root -g garrett-service "$ETC"
install -d -m 0700 -o garrett-service -g garrett-service "$DATA"
umask 027
if [ ! -s "$ETC/service.conf" ]; then
  [ -n "$ADDRESS" ] || ADDRESS=$(hostname -I 2>/dev/null | cut -d' ' -f1)
  [ -n "$ADDRESS" ] || ADDRESS=$(hostname)
  if [ -z "$MODEL" ]; then if [ -f "$LIB/model/model.onnx" ]; then MODEL=$BUNDLED; else MODEL=off; fi; fi
  {
    echo "# The Sentinel service on this machine. Restart after a change:  systemctl restart garrett-service"
    echo "PORT=${PORT:-8443}"
    echo "ADDRESS=$ADDRESS"
    echo "DATABASE=$DATA/sentinel.db"
    echo "TLS_CERT=$ETC/tls.crt"
    echo "TLS_KEY=$ETC/tls.key"
    echo "# Lets a machine enrol. garrett-service join prints the command that carries it."
    echo "ENROLL_KEY=$(openssl rand -hex 32)"
    echo "# Lets you read cases and decide. Keep it to yourself."
    echo "ADMIN_TOKEN=$(openssl rand -hex 32)"
    echo "# Encrypts case evidence in the database. Lose it and stored evidence cannot be read."
    echo "DATA_KEY=$(openssl rand -hex 32)"
    echo "# What machines do about a hostile program: kill (the default), pause or report. See the README for the rest."
    echo "RESPONSE_MODE="
    echo "# Remember operators' verdicts and show a new case the nearest ones: neuron-db, or off (the default)."
    echo "MEMORY=${MEMORY:-off}"
    echo "# The model that decides what happens to a frozen program:  sudo garrett-service setup  changes it, or edit these."
    if [ "$MODEL" = "$BUNDLED" ]; then
      echo "AI_PROVIDER=decision"
      echo "AI_MODEL=$BUNDLED"
      echo "MODEL_DIR=$LIB/model"
    else
      echo "AI_PROVIDER=none"
    fi
  } > "$ETC/service.conf"
else
  # An upgrade keeps everything; only what was asked for on the command line changes.
  [ -z "$MEMORY" ] || put MEMORY "$MEMORY"
  [ -z "$PORT" ] || put PORT "$PORT"
  [ -z "$ADDRESS" ] || put ADDRESS "$ADDRESS"
  if [ "$MODEL" = "$BUNDLED" ]; then
    put AI_PROVIDER decision; put AI_MODEL "$BUNDLED"; put MODEL_DIR "$LIB/model"; put AI_BASE_URL ""; put AI_CA_CERT ""
  elif [ "$MODEL" = off ]; then
    put AI_PROVIDER none; put AI_MODEL ""; put MODEL_DIR ""
  fi
fi
if [ -n "$ANSWERS" ]; then
  # Every model line the wizard wrote, as it wrote it.
  grep -E '^(AI_[A-Z_]+|MODEL_DIR|DECISION_[A-Z_]+|RESPONSE_MODE)=' "$ANSWERS" | while IFS='=' read -r name value; do put "$name" "$value"; done
  rm -f "$ANSWERS"
fi
ADDRESS=$(setting ADDRESS)
if [ ! -s "$ETC/tls.crt" ] || [ ! -s "$ETC/tls.key" ]; then
  # The service's own certificate. Machines are given its SHA-256 with the join command and accept no other.
  case "$ADDRESS" in *[!0-9.]*|"") SAN="DNS:$ADDRESS" ;; *) SAN="IP:$ADDRESS" ;; esac
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 -subj "/CN=garrett-service" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1,$SAN" -keyout "$ETC/tls.key" -out "$ETC/tls.crt" >/dev/null 2>&1
fi
chown root:garrett-service "$ETC/service.conf" "$ETC/tls.crt" "$ETC/tls.key"
chmod 0640 "$ETC/service.conf" "$ETC/tls.key"; chmod 0644 "$ETC/tls.crt"

sed "s#@NODE@#$NODE#" "$HERE/garrett-service.service" > "$UNIT"
chmod 0644 "$UNIT"
systemctl daemon-reload
systemctl enable garrett-service.service >/dev/null 2>&1 || true
systemctl restart garrett-service.service
i=0
until garrett-service ready >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || { echo "The service did not start. See:  journalctl -u garrett-service -n 30" >&2; exit 1; }
  sleep 1
done
echo
echo "Your Sentinel service is running on this machine."
[ "$(setting AI_MODEL)" != "$BUNDLED" ] || echo "Its decision model, $BUNDLED, decides what happens to a program a machine freezes. To change that, or plug in a model of your own:  sudo garrett-service setup"

# The agent for this machine, when the installer carries it: installed and joined to this service.
if [ -f "$HERE/agent/install.sh" ]; then
  if [ -x /usr/bin/garrett ] && [ ! -f "$ETC/agent-installed" ]; then
    echo "garrett is already on this machine; join it to this service with the command below."
  else
    PIN=$(openssl x509 -in "$ETC/tls.crt" -outform der | sha256sum | cut -d' ' -f1)
    install -d -m 0755 /etc/garrett
    umask 077
    printf 'SERVER=https://127.0.0.1:%s\nENROLL_KEY=%s.%s\n' "$(setting PORT)" "$(setting ENROLL_KEY)" "$PIN" > /etc/garrett/garrett.conf
    chmod 0600 /etc/garrett/garrett.conf
    umask 022
    sh "$HERE/agent/install.sh"
    install -m 0755 "$HERE/agent/install.sh" "$LIB/agent-install.sh"
    : > "$ETC/agent-installed"
    echo "This machine is protected by garrett and reports to this service."
  fi
fi
echo
garrett-service join
