#!/usr/bin/env bash
set -euo pipefail

. /etc/os-release
if [[ $ID != debian || $VERSION_ID != 12 || $(dpkg --print-architecture) != amd64 ]]; then
  echo 'sn-web setup requires a Debian 12 amd64 workspace image (MongoDB 8).' >&2
  exit 1
fi

if ! command -v mongod >/dev/null; then
  if ! command -v gpg >/dev/null; then
    sudo apt-get install -y gnupg
  fi
  curl -fsSL https://pgp.mongodb.com/server-8.0.asc | sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/mongodb-server-8.0.gpg
  echo 'deb [ signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/debian bookworm/mongodb-org/8.0 main' | sudo tee /etc/apt/sources.list.d/mongodb-org-8.0.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y mongodb-org
fi

if ! command -v redis-server >/dev/null; then
  sudo apt-get install -y redis-server
fi

if ! grep -Eq '^[[:space:]]*replSetName:[[:space:]]*rs0([[:space:]]|$)' /etc/mongod.conf; then
  if grep -Eq '^[[:space:]]*replSetName:' /etc/mongod.conf; then
    echo 'MongoDB already has a different replica set configuration.' >&2
    exit 1
  fi
  printf '\nreplication:\n  replSetName: rs0\n' | sudo tee -a /etc/mongod.conf >/dev/null
  sudo systemctl restart mongod
fi

sudo systemctl enable --now mongod redis-server

for attempt in {1..30}; do
  if mongosh --quiet --eval 'db.adminCommand({ ping: 1 }).ok' | grep -qx 1; then
    break
  fi
  sleep 1
done

if ! mongosh --quiet --eval 'db.adminCommand({ ping: 1 }).ok' | grep -qx 1; then
  echo 'MongoDB did not become ready.' >&2
  exit 1
fi

if ! mongosh --quiet --eval 'db.version()' | grep -Eq '^8\.'; then
  echo 'sn-web setup requires MongoDB 8.' >&2
  exit 1
fi

if ! mongosh --quiet --eval 'try { rs.status().ok } catch (_) { 0 }' | grep -qx 1; then
  mongosh --quiet --eval 'rs.initiate({_id: "rs0", members: [{_id: 0, host: "localhost:27017"}]})'
fi

for attempt in {1..30}; do
  if mongosh --quiet --eval 'db.hello().isWritablePrimary' | grep -qx true; then
    break
  fi
  sleep 1
done

if ! mongosh --quiet --eval 'db.hello().isWritablePrimary' | grep -qx true; then
  echo 'MongoDB replica set did not become primary.' >&2
  exit 1
fi

redis-cli ping | grep -qx PONG

export NVM_DIR="$HOME/.nvm"
if [[ ! -s $NVM_DIR/nvm.sh ]]; then
  git clone --depth 1 --branch v0.40.7 https://github.com/nvm-sh/nvm.git "$NVM_DIR"
fi
set +u
. "$NVM_DIR/nvm.sh"
nvm install
nvm alias default "$(< .nvmrc)"
set -u

if ! grep -Fq '/.nvm/nvm.sh' "$HOME/.zshrc" 2>/dev/null; then
  cat >> "$HOME/.zshrc" <<'EOF'
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
EOF
fi

stamp="$HOME/.cache/coder/sn-web-npm-lock.sha256"
lock_hash="$(sha256sum package-lock.json .nvmrc | sha256sum | cut -d' ' -f1)"
if [[ ! -d node_modules || ! -f $stamp || $(< "$stamp") != "$lock_hash" ]]; then
  npm ci
  mkdir -p "$(dirname "$stamp")"
  printf '%s\n' "$lock_hash" > "$stamp"
fi
