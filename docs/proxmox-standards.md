# Proxmox and backup standard

Enforced by [`playbooks/pve-standards.yml`](../playbooks/pve-standards.yml) on the `proxmox` and `backup` groups. Package sources, time, journald, keys and accounts come from the [base standard](base-standards.md); this adds what is specific to the hypervisors and the backup server.

Both are updated by hand, never by unattended-upgrades, and the base audit fails if it is installed there.

## Firewall

`/etc/pve/firewall/cluster.fw` is rendered from [`playbooks/templates/pve-cluster.fw.j2`](../playbooks/templates/pve-cluster.fw.j2) and is identical on every node except the node's own name:

| From | To |
|---|---|
| bastion and mgmt-services | SSH |
| the admin workstation's out-of-band address | SSH and the web UI (8006) |
| bastion, the admin workstation, and the firewall | ICMP |

Proxmox's built-in management ipset always allows ports 22 and 8006 from the node's own network, whatever `cluster.fw` says, so a bad rule can't lock the management network out. That also covers the other management-network hosts that need the web UI.

After the file is installed, the play requires `pve-firewall status` to report `enabled/running`, which proves the file compiled.

### Files under /etc/pve

`/etc/pve` is the cluster filesystem, and it doesn't take Ansible's atomic rename. The play therefore:

1. renders the file to a staging file in `/root` (written even in check mode, so the diff is against what is live)
2. compares it with `diff`, and shows the difference as a change
3. copies it over with `cp` only when it differs and only outside check mode

The same pattern applies to root's `authorized_keys`.

## Root keys

Root login is off fleet-wide. Root's `authorized_keys` keeps only the node's own key, which is what Proxmox sets up on a standalone node, and keys from other nodes are removed. When the play shows a key change it prints the key type and comment only, never the key material.

## The backup path

Backups run unattended and are rarely looked at, so the audit doesn't trust that they work. It proves it. The backup system itself, with its schedule, restore procedure and design, is in [backups-nobody-watches](https://github.com/zacharyrichter/backups-nobody-watches).

On each Proxmox node:

| Check | Why |
|---|---|
| The backup storage connects to the backup server **by hostname**, as the dedicated token user, with no pinned `fingerprint` | The backup server has a Let's Encrypt certificate that renews every few months. A pinned fingerprint, or the IP (which the certificate doesn't cover), breaks every backup at the next renewal |
| The storage is enabled and `active` now | `pvesm status` exercises the network, the login, the certificate and the datastore together |
| Every backup job writes to that storage and is enabled | A disabled job fails silently |
| Backup mode is `snapshot`, except for jobs listed in `pve_backup_stop_jobs`, which must be `stop` | VMs with databases are stopped for a clean backup, and the exception list is the only place that is allowed |
| NUT is `MODE=netclient` | Nodes act as clients of the network UPS monitor ([graceful-power-loss](https://github.com/zacharyrichter/graceful-power-loss) has the full chain) |
| A webhook notification target exists | Failures reach the notification server |

On the backup server:

| Check | Why |
|---|---|
| The datastore path is a mounted `9p` share | Without the mount, the datastore path is just a local directory |
| The datastore exists at that path, with a garbage-collection schedule | |
| A prune job and a verify job exist for it | Retention and integrity are both automatic |
| A webhook notification target exists | |
