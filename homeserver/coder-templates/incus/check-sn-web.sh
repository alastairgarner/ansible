#!/usr/bin/env bash
set -euo pipefail

cd "$HOME/sn-web"
export NVM_DIR="$HOME/.nvm"
set +u
. "$NVM_DIR/nvm.sh"
set -u

[[ $(node --version) == "v$(< .nvmrc)" ]]
[[ $(npm --version) == "$(node -p "require('./package.json').engines.npm")" ]]
[[ -d node_modules ]]
[[ $(mongosh --quiet --eval 'db.version()') == 8.* ]]
[[ $(mongosh --quiet --eval 'db.hello().isWritablePrimary') == true ]]
[[ $(redis-cli ping) == PONG ]]

echo 'sn-web tools, MongoDB replica set, and Redis are ready.'
