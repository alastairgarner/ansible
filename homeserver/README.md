# Homeserver workspace network

Static host configuration for Fedora + Docker + Incus. These files are not applied by Ansible. Run the commands below on `homeserver` from the repository root. They change networking; keep an SSH session open and stop on any error.

The policy allows workspaces outbound IPv4 and Coder at `100.90.71.107:443`. It blocks other host services, RFC1918/Tailscale/link-local destinations, and outbound IPv6. IPv6 is deliberately blocked because the home LAN has a delegated global IPv6 prefix that can change. The IPv4 denylist covers the current private networks, not every possible non-public address. Incus DNS/DHCP remain available. Each workspace NIC rejects new inbound connections, including from other workspaces, while allowing replies to its outbound connections.

## Apply

First create the Incus ACL and profile (the `create` commands are one-time):

```sh
incus network acl create coder-isolated
incus network acl edit coder-isolated < homeserver/incus/coder-isolated-acl.yaml
incus profile create coder-isolated
incus profile edit coder-isolated < homeserver/incus/coder-isolated-profile.yaml
```

Install the host files, remove the old `trusted` binding, and check firewalld before reloading:

```sh
sudo install -Dm644 homeserver/docker/daemon.json /etc/docker/daemon.json
sudo install -Dm644 homeserver/firewalld/zones/incus.xml /etc/firewalld/zones/incus.xml
sudo install -Dm644 homeserver/firewalld/policies/incus-host.xml /etc/firewalld/policies/incus-host.xml
sudo install -Dm644 homeserver/firewalld/policies/incus-world.xml /etc/firewalld/policies/incus-world.xml
sudo firewall-cmd --permanent --zone=trusted --remove-interface=incusbr0
sudo firewall-cmd --check-config
sudo firewall-cmd --reload
sudo systemctl restart docker
sudo iptables -P FORWARD ACCEPT
```

The last command clears Docker's existing global IPv4 forwarding drop. `ip-forward-no-drop` prevents Docker from reinstating it; firewalld still filters forwarding. Restarting Docker interrupts running Docker containers.

In the Coder Incus template, set `profiles = ["default", "coder-isolated"]` on `incus_instance.dev`, then push the template and recreate workspaces. The later profile overrides only `eth0`; `default` still supplies the root disk. **Until this template change, workspaces are not isolated from one another.**

## Verify

```sh
sudo firewall-cmd --get-zone-of-interface=incusbr0
sudo firewall-cmd --info-policy=incus-host
sudo firewall-cmd --info-policy=incus-world
sudo iptables -S FORWARD | head -1
incus config show coder-alastairgarner-red --expanded
```

From each new workspace, confirm GitHub and the Coder URL connect; the bridge address `10.66.85.1:22`, the LAN router `192.168.1.1`, and another workspace address do not. Also retest after reboot. The Coder and LAN addresses are homeserver-specific; update these files if they change.

The bridge still uses `ipv4.firewall=false` and `ipv6.firewall=false` as recommended when firewalld manages the bridge. Do not add `incusbr0` back to `trusted`. An Incus profile/ACL is an additional filter, not a replacement for keeping the containers unprivileged and Incus admin access out of them.

Sources: [Incus firewall](https://linuxcontainers.org/incus/docs/main/howto/network_bridge_firewalld/), [Incus ACLs](https://linuxcontainers.org/incus/docs/main/howto/network_acls/), [Incus profiles](https://linuxcontainers.org/incus/docs/main/profiles/), [firewalld policies](https://firewalld.org/documentation/man-pages/firewalld.policy.html), [Docker forwarding](https://docs.docker.com/engine/network/packet-filtering-firewalls/).
