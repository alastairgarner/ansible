#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ $(incus network get incusbr0 ipv4.address) != 10.66.85.1/24 ]]; then
  echo 'incusbr0 must use 10.66.85.1/24 for the workspace ACL.' >&2
  exit 1
fi

sudo install -Dm644 homeserver/modules-load.d/incus.conf /etc/modules-load.d/incus.conf
sudo modprobe br_netfilter

if ! incus network acl show coder-isolated >/dev/null 2>&1; then
  incus network acl create coder-isolated
fi
incus network acl edit coder-isolated < homeserver/incus/coder-isolated-acl.yaml

if ! incus profile show coder-isolated >/dev/null 2>&1; then
  incus profile create coder-isolated
fi
incus profile edit coder-isolated < homeserver/incus/coder-isolated-profile.yaml

docker_changed=false
if ! sudo cmp -s homeserver/docker/daemon.json /etc/docker/daemon.json; then
  sudo install -Dm644 homeserver/docker/daemon.json /etc/docker/daemon.json
  docker_changed=true
fi

firewall_changed=false
for file in zones/incus.xml policies/incus-host.xml policies/incus-world.xml; do
  if ! sudo cmp -s "homeserver/firewalld/$file" "/etc/firewalld/$file"; then
    sudo install -Dm644 "homeserver/firewalld/$file" "/etc/firewalld/$file"
    firewall_changed=true
  fi
done

if sudo firewall-cmd --permanent --zone=trusted --query-interface=incusbr0 >/dev/null; then
  sudo firewall-cmd --permanent --zone=trusted --remove-interface=incusbr0
  firewall_changed=true
fi

sudo firewall-cmd --check-config
if $firewall_changed; then
  sudo firewall-cmd --reload
fi
if $docker_changed; then
  sudo systemctl restart docker
fi
sudo iptables -P FORWARD ACCEPT
