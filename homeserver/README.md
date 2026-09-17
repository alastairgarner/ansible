# Homeserver workspace network

Static host configuration for Fedora + Docker + Incus. These files are not applied by Ansible. The script expects Docker, firewalld, and Incus with `incusbr0` at `10.66.85.1/24`. After `git pull`, run it on `homeserver` from the repository root. It is safe to rerun; keep a terminal open and stop on any error because it changes networking.

The policy allows workspaces outbound IPv4 and Coder at `100.90.71.107:443`. It blocks other host services, RFC1918/Tailscale/link-local destinations, and outbound IPv6. IPv6 is deliberately blocked because the home LAN has a delegated global IPv6 prefix that can change. The IPv4 denylist covers the current private networks, not every possible non-public address. Each workspace NIC rejects new inbound connections and outbound traffic to other bridge addresses or any IPv6 address, while allowing replies to its outbound connections. Port isolation also separates workspaces that both use this profile. The ACL leaves bridge gateway `10.66.85.1` available for DHCP/DNS; firewalld restricts other host services. Update the ACL if the bridge's IPv4 subnet changes. **This staged policy has not passed live DHCP or isolation tests.**

## Apply

```sh
git pull
bash homeserver/apply.sh
```

The script loads `br_netfilter` now and at boot, creates or updates the Incus ACL and profile, installs the static Docker/firewalld files, and clears Docker's global IPv4 forwarding drop. It removes the old DHCP `notrack` direct rule from both permanent and running firewalld configuration, leaving unrelated direct rules intact. It reloads firewalld or restarts Docker only when their files change; a Docker restart interrupts running Docker containers. `ip-forward-no-drop` prevents Docker from reinstating the forwarding drop, while firewalld still filters forwarding.

After applying the host files, push the Coder Incus template from this checkout with `coder templates push incus -d homeserver/coder-templates/incus`. Then recreate test workspaces. It attaches `default` and `coder-isolated`; the latter overrides `eth0`. Do not update Green until the test workspaces pass the checks below.

## Verify

```sh
sudo firewall-cmd --get-zone-of-interface=incusbr0
sudo firewall-cmd --info-policy=incus-host
sudo firewall-cmd --info-policy=incus-world
sudo firewall-cmd --permanent --direct --get-all-rules
sudo firewall-cmd --direct --get-all-rules
sudo iptables -S FORWARD | head -1
incus network show incusbr0
incus network acl show coder-isolated
incus profile show coder-isolated
```

The two direct-rule listings should no longer contain the DHCP `--notrack` rule. From each new workspace, confirm GitHub and the Coder URL connect. Run a known listening service in a second workspace and another host container; verify connections fail in both directions, including to their IPv6 addresses. Also check that `10.66.85.1:22` and the LAN router are unreachable, then retest after reboot. A closed port alone does not prove isolation. The Coder and LAN addresses are homeserver-specific; update these files if they change.

The bridge still uses `ipv4.firewall=false` and `ipv6.firewall=false` as recommended when firewalld manages the bridge. Do not add `incusbr0` back to `trusted`. An Incus profile/ACL is an additional filter, not a replacement for keeping the containers unprivileged and Incus admin access out of them.

After DHCP and isolation pass, test whether `br_netfilter` is needed. If not, remove its load/install lines from `apply.sh` and `modules-load.d/incus.conf`; also remove `/etc/modules-load.d/incus.conf` on the host. The loaded module remains until reboot. Retest after reboot before removing the forced `FORWARD ACCEPT` line; Docker's `ip-forward-no-drop` may already make it redundant.

Sources: [Incus firewall](https://linuxcontainers.org/incus/docs/main/howto/network_bridge_firewalld/), [Incus ACLs](https://linuxcontainers.org/incus/docs/main/howto/network_acls/), [Incus profiles](https://linuxcontainers.org/incus/docs/main/profiles/), [firewalld policies](https://firewalld.org/documentation/man-pages/firewalld.policy.html), [Docker forwarding](https://docs.docker.com/engine/network/packet-filtering-firewalls/).
