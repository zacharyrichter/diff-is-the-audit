# Base standard

What every host is held to, enforced by [`playbooks/base-standards.yml`](../playbooks/base-standards.yml). It applies to the whole `debian_fleet`, `proxmox` and `backup` set except the bastion (see [below](#bastion)).

| Area | Standard |
|---|---|
| Package sources | deb822 files only in `/etc/apt/sources.list.d/`, from `playbooks/files/apt/`. `debian.sources` has the release, its updates and its security suite, `main contrib non-free-firmware`, binary only (no `deb-src`). `/etc/apt/sources.list` stays empty. Any other file in `sources.list.d` (`*.list`, `*.disabled`) is removed unless it is named in `apt_sources_extra`. Role files: `docker.sources` (Docker hosts), `ntfy.sources` (the notification server), `pve-no-subscription.sources` plus `pve-enterprise.sources` and `ceph.sources` kept with `Enabled: false` (Proxmox nodes), `proxmox.sources` plus `pbs-enterprise.sources` with `Enabled: false` (backup server). |
| apt leftovers | No `*.bak`, `*.save`, `*.orig`, `*.ucf-*`, `*.dpkg-*`, and no installer CD-ROM settings (`00trustcdrom`, `00CDMountPoint`). |
| Updates | Debian VMs and LXCs: unattended-upgrades on (`20auto-upgrades`), reports to the notification server when something changes (`51unattended-upgrades-mail`), and `/usr/sbin/sendmail` links to the notification shim and is never a real mail server. Proxmox and backup hosts are updated by hand; the audit fails if unattended-upgrades is installed on them. |
| Time | Zone from `fleet_timezone`. Source: the host's VLAN gateway (`ntp_server` from its `vlan_*` group). chrony hosts: every `pool`/`server` line in `chrony.conf` commented out, the gateway in `/etc/chrony/sources.d/fleet.sources`. timesyncd hosts: `NTP=` in `timesyncd.conf`. LXCs: none (they use the Proxmox node's clock). |
| journald | `SystemMaxUse=500M`, `Storage=persistent` and `Compress=yes` in `/etc/systemd/journald.conf.d/60-fleet.conf`; no size settings in the main `journald.conf`. |
| SSH keys | `admin`: certificate login, plus exactly two plain keys, the primary and backup hardware keys (break-glass), mode 0600. The `ansible` account: certificate only, no `authorized_keys` (the bastion is the exception: a raw key, by design). |
| Accounts | Login accounts: root, `admin`, `ansible`. Any other system account has `/usr/sbin/nologin`. `admin` gets sudo from the `sudo` group; no per-user files in `/etc/sudoers.d`. A human-UID account other than `admin` fails the audit. |
| Leftovers | Paths in a host's `fleet_remove_paths` are removed, after checking that no systemd unit references them. |

## Preconditions

The playbook assumes three things it does not create:

- **Keyrings.** The keyring files the sources point at must already exist. The playbook stops with the missing paths named rather than writing a source that `apt` can't verify.
- **The notification shim.** `/usr/local/bin/ntfy-sendmail` is a sendmail-compatible script that posts its input to the notification server. `/usr/sbin/sendmail` is linked to it so cron, unattended-upgrades and similar tools report through one channel.
- **Certificate login.** The SSH certificate authority and the `<host>-admin` aliases exist already. The playbook only enforces what the accounts keep as `authorized_keys`.

## Print server

One role play, to show how a role-scoped standard looks: `admin` administers printers as a member of `lpadmin` (CUPS' `SystemGroup`), and `DefaultEncryption Required` means the admin pages only accept passwords over HTTPS. There is no separate CUPS admin account.

## Tags

`apt`, `updates`, `time`, `journald`, `keys`, `accounts`, `leftovers`, and `cups` for the print server play. `--tags journald` audits only that area.

## bastion

The bastion has no `-admin` alias: there is no path to it from the management host, by design. Its part of the base standard is applied by hand, as `admin` on the bastion, with the same content as `playbooks/files/apt/`:

```
sudo tee /etc/apt/sources.list.d/debian.sources >/dev/null <<'SRC'
# Managed by Ansible (base-standards.yml)
Types: deb
URIs: http://deb.debian.org/debian/
Suites: trixie trixie-updates
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security/
Suites: trixie-security
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
SRC
printf '%s\n' '# Managed by Ansible (base-standards.yml).' '# All sources are deb822 files in /etc/apt/sources.list.d/. This file stays empty.' | sudo tee /etc/apt/sources.list >/dev/null
sudo rm -f /etc/apt/apt.conf.d/00trustcdrom /etc/apt/apt.conf.d/00CDMountPoint
sudo install -d -m 0755 /etc/systemd/journald.conf.d
printf '%s\n' '# Managed by Ansible (base-standards.yml)' '[Journal]' 'SystemMaxUse=500M' 'Storage=persistent' 'Compress=yes' | sudo tee /etc/systemd/journald.conf.d/60-fleet.conf >/dev/null
sudo systemctl restart systemd-journald && sudo apt update
```

The bastion also keeps the raw `ansible` key for its `ansible` account, because there is no user CA trust on the host that holds the CA.
