# CIS baseline (Wazuh SCA)

`playbooks/cis-baseline.yml` hardens every Debian-based host against the CIS Debian
benchmark as scored by Wazuh SCA. It is idempotent and safe to rerun on the whole fleet.
Checks it does not remediate are listed under [Accepted checks](#accepted-checks) with the reason.

## Scope

| Group | Hosts | Notes |
|---|---|---|
| `debian_fleet` | bastion, mgmt-services, apps, dmz, ntfy, cups, wazuh | ntfy and cups are LXCs (auditd, `/dev/shm`, GRUB tasks skip) |
| `proxmox` | pve1-4 | `/etc/issue` left to `pvebanner` |
| `backup` | pbs | same as `proxmox` |

bastion has no `-admin` alias, so every section is applied there by hand (same content as the playbook), including `/etc/sudoers.d/ansible-audit`.

## Running it

From the repo root on mgmt-services, one host at a time, as `admin`:

```
H=<host>
ansible-playbook playbooks/cis-baseline.yml -e ansible_user=admin -e ansible_host=$H-admin -K --check --diff -l $H
ansible-playbook playbooks/cis-baseline.yml -e ansible_user=admin -e ansible_host=$H-admin -K -l $H
```

For `sshd` and `pam` changes, keep a session (or a `sudo -i` root shell) open on the host until a new login and `sudo -v` are confirmed.
Quick sudo check after a PAM change:

```
ansible $H -m command -a true -b -e ansible_user=admin -e ansible_host=$H-admin -K
```

Rescan after changes (all agents except bastion; restart bastion by hand):

```
ansible 'all:!bastion' -m systemd -a "name=wazuh-agent state=restarted" -b -e ansible_user=admin -e 'ansible_host={{ inventory_hostname }}-admin' -K
```

## Sections and tags

Checks are named by title throughout, never by number: the policy's check numbers change with every Wazuh policy update, and an update can also fix or add checks.

| Tag | What it does |
|---|---|
| `cron` | `/etc/crontab` 0600, `/etc/cron.*` 0700 |
| `banners` | `/etc/issue.net` warning text, `/etc/issue` too except on Proxmox/PBS, `/etc/motd` removed |
| `packages` | telnet and vim removed (nano is the editor), `apparmor-utils` installed |
| `rpcbind` | rpcbind stopped and masked (no NFS, LVM only) |
| `sysctl` | `/etc/sysctl.d/60-cis-hardening.conf`: no ICMP redirects or source routing, martians logged, SYN cookies, ICMP broadcast/bogus-error ignores, SysRq off, `kptr_restrict 2`, `dmesg_restrict 1`, ASLR, symlink/hardlink protection (LXCs: `net.*` only); keeps martian logging on in `/etc/ufw/sysctl.conf` where ufw is installed |
| `shm` | `/dev/shm` mounted `nodev,nosuid,noexec` (not LXCs) |
| `sshd` | `Include` line ensured first in `sshd_config`; drop-in `/etc/ssh/sshd_config.d/00-cis-hardening.conf` |
| `sudo` | `logfile=/var/log/sudo.log`, `timestamp_timeout=15` (drop-in and `/etc/sudoers`), `opasswd`/`opasswd.old` 0600; the `ansible` account's read-only audit scope in `/etc/sudoers.d/ansible-audit` (exact arguments, no wildcards) |
| `su` | `pam_wheel.so use_uid group=sugroup` (empty group; root still works via `pam_rootok`) |
| `auditd` | auditd + CIS rules in `/etc/audit/rules.d/50-cis.rules`; optional `-e 2` lock (`audit_immutable`) |
| `auditgrub` | `apparmor=1 security=apparmor audit=1 audit_backlog_limit=8192` on the kernel command line (audits processes that start before auditd) |
| `chrony` | explicit `user _chrony` on chrony hosts |
| `pam` | faillock (`deny=5`, `unlock_time=900`), pwquality, pwhistory (`remember=24`), `nullok` removed, via pam-auth-update profiles |

### sshd drop-in

```
PermitRootLogin no
LoginGraceTime 30
MaxAuthTries 3
MaxStartups 10:30:60
ClientAliveInterval 15
ClientAliveCountMax 3
DisableForwarding yes
Banner /etc/issue.net
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha2-512,hmac-sha2-256
AllowUsers admin ansible
```

`DisableForwarding` is safe everywhere: nothing uses ProxyJump, agent forwarding or port forwards (checked on the admin workstation, bastion, mgmt-services and `ansible.cfg`). The Git server's SSH runs in its own container on a separate port, so `AllowUsers` does not affect it.

### Kernel and network settings (sysctl)

- **Current Debian releases no longer read `/etc/sysctl.conf`**, only `/etc/sysctl.d/` (and `/usr/lib/sysctl.d/`). Settings left in `sysctl.conf` are silently ignored at boot, so a host can run on kernel defaults without anyone noticing.
- **Interface wildcards.** The network settings use `net.ipv4.conf.*.<key>`, not `all` + `default`. Several keys (`send_redirects`, `secure_redirects`, `log_martians`, and `accept_redirects` on hosts that don't forward) take effect if *either* `all` or the interface's own value is on, and `default` only applies to interfaces created later. Without the `*`, interfaces that exist before boot-time sysctl (e.g. `ens18`) keep sending redirects. systemd's udev rule applies the same settings to interfaces created later (Docker bridges, veth, Proxmox `tap`).
- **Applied with `systemd-sysctl`**, not `sysctl -p`: only `systemd-sysctl` expands the `*`, and it is what loads the file at boot.
- **Left out on purpose:** `ip_forward` (Docker turns it on where it runs; Proxmox bridges guests at layer 2 and doesn't route) and `rp_filter` (distro defaults stay: `all=0`, every interface `2`/loose; strict would risk dropping traffic on Docker and Proxmox bridges).
- **LXCs** (ntfy, cups) get only the `net.*` keys. Their `kernel.*` and `fs.*` values come from the Proxmox node they run on.
- **`kernel.sysrq = 0` everywhere**, Proxmox nodes and pbs included. Keyboard SysRq is off; root can still use `/proc/sysrq-trigger`. With physical access, a hung node gets the power button rather than a keyboard and REISUB.
- **ufw (dmz):** ufw applies `/etc/ufw/sysctl.conf` every time it starts, which is after `systemd-sysctl`, and its stock file sets `log_martians=0`. The playbook sets those two lines to `1` wherever the file exists. ufw's other settings (no redirects, ICMP ignores) already agree.
- Martian logging may add kernel log lines on the Proxmox nodes. That is expected.

Check the whole fleet at once (reads only; runs as `ansible`, no sudo). Every host should print `1 2 sendredirects_on:` with nothing after the colon:

```
ansible 'debian_fleet:proxmox:backup:!bastion' -m shell -a 'echo "$(cat /proc/sys/net/ipv4/conf/all/log_martians) $(cat /proc/sys/kernel/kptr_restrict) sendredirects_on: $(grep -l 1 /proc/sys/net/ipv4/conf/*/send_redirects | xargs -r -n1 dirname | xargs -r -n1 basename | tr "\n" " ")"'
```

bastion: the same file installed by hand, applied with `sudo /usr/lib/systemd/systemd-sysctl /etc/sysctl.d/60-cis-hardening.conf`.

### PAM lockout behaviour

- 5 failed password attempts within 15 minutes lock `admin` for 15 minutes; it clears itself.
- Counted: `sudo` prompts, console logins, Proxmox/PBS web logins via the `pam` realm (one shared counter). An abandoned `sudo` prompt (Ctrl+C) also counts.
- Not counted: certificate SSH logins, which keep working during a lockout.
- Counter lives in `/var/run/faillock` (cleared at reboot). Inspect or clear as root: `faillock --user admin [--reset]`.
- pwquality and pwhistory only apply at the next password change (new passwords need 14+ characters).

### Audit rules

- Rules load immediately with `augenrules --load` while `audit_immutable: false`.
- With `audit_immutable: true`, `99-finalize.rules` adds `-e 2`: rules lock until reboot, and any later rule change needs a reboot (the playbook warns instead of failing).
- The Wazuh agent reads `/var/log/audit/audit.log` through its group configuration, set centrally on the manager rather than in this repo.
- Expected `auditctl` warnings ("Old style watch rules are slower", "perm used without an arch is slower") are informational.

## Host exceptions

### dmz (internet-facing)

dmz is the only host with a host firewall (ufw), as defense in depth on top of network segmentation.

- ufw: default deny inbound; allow 22/tcp from bastion (10.0.99.5) and mgmt-services (10.0.99.6).
- No published web ports: the reverse proxy is reached only by the tunnel client over a Docker network.
- Docker-published ports bypass ufw's input rules, so the one published port (the container-management agent's) is restricted in the `DOCKER-USER` chain through `/etc/ufw/after.rules`: allowed from mgmt-services, dropped from everything else. Check with `sudo iptables -L DOCKER-USER -v -n`.

The full design, with the rules and the reasoning, is [`docs/segmentation-and-host-firewall.md` in no-open-doors](https://github.com/zacharyrichter/no-open-doors/blob/main/docs/segmentation-and-host-firewall.md).

### LXCs (ntfy, cups)

No kernel audit, no bootloader, `/dev/shm` controlled by the container runtime. cups is the print server, so avahi/cups checks fail by design.

## Accepted checks

| Check (by title) | Hosts | Reason |
|---|---|---|
| Separate partition for `/home`, `/var`, `/var/tmp`, `/var/log` and `/var/log/audit` (each with nodev, nosuid, noexec); `/tmp` a separate partition with noexec | All | VMs/LXCs on thin disks; repartitioning not worth it |
| Bootloader password is set | Every host with a bootloader | Physical access is controlled: the hardware is in my house |
| Access to bootloader config is configured | ntfy, cups | LXCs have no bootloader |
| AppArmor is enabled in the bootloader configuration | pbs, pve1-4 | Check requires every `linux` line in grub.cfg to carry `apparmor=1`; only memtest86+ entries lack it. All kernel entries have it (verified in `/proc/cmdline`) |
| noexec option set on `/dev/shm` | ntfy, cups | Mount controlled by the container runtime |
| auditd packages installed and service active; every audit-rule check; audit configuration is immutable | ntfy, cups | No kernel audit inside LXCs |
| Avahi daemon and print server services are not in use | cups | That host is the print server |
| systemd-timesyncd enabled and running; chrony enabled and running | All | Either/or check: each host passes the one it uses. The LXCs use the Proxmox host's clock and fail both |
| ufw installed and enabled; nftables table, base chains, loopback, default deny and service; iptables packages, default deny and loopback; ip6tables default deny and loopback; nftables not in use with iptables | All hosts but dmz (each host fails the ones that apply to it) | Network segmentation in OPNsense is the chosen control |
| The same nftables and iptables checks, plus: ufw default deny firewall policy; ufw uninstalled or disabled with nftables; ufw not in use with iptables | dmz | Policy assumes one firewall tool; ufw is a front end to nftables. Egress filtering handled at OPNsense |
| Users must provide a password for privilege escalation | All | `ansible` account's NOPASSWD is limited to read-only audit commands with exact arguments, by design |
| Password complexity is configured | All | Length-based policy (14-character minimum); NIST 800-63B advises against composition rules |
| Password history enforced for the root user; pam_pwhistory includes use_authtok | All | Policy regex bug (expects bare `remember` before `enforce_for_root`). pwhistory is set with `remember=24 enforce_for_root try_first_pass use_authtok` |
| pam_unix does not include remember | All | Contradicts the history checks: any `remember` in the PAM common files fails it, and pwhistory needs `remember=24` |
| Password expiration, minimum days, expiration warning days and inactive lock | All | Key-only SSH; NIST 800-63B advises against forced rotation |
| Strong password hashing algorithm | All | Policy bug (requires SHA512 and YESCRYPT at once); YESCRYPT is set |
| Root account access is controlled | All | Policy bug (requires root locked and password-set at once) |
| systemd-journal-remote installed; journal-upload active; rsyslog installed and active; journald ForwardToSyslog disabled; journald sends logs to rsyslog | All | Wazuh agent forwards logs. The last two checks contradict each other (one requires ForwardToSyslog off, the other on) |
| audit_backlog_limit is sufficient | Hosts with auditd | Policy bug (fails if any line of `/etc/default/grub` lacks the parameter); the parameter is set |
| Audit logs are not automatically deleted; system disabled when audit logs are full; system warns when audit logs are low on space | Hosts with auditd | Logs rotate; a full audit disk must not halt a host. Wazuh holds the long-term copy |
| Audit-rule checks: actions as another user, network environment changes, Mandatory Access Controls, chcon, setfacl, chacl, usermod, kernel module loading | Hosts with auditd | Policy regex bugs; rules verified loaded with `auditctl -l` |
| AIDE installed; filesystem integrity regularly checked | All | Covered by Wazuh FIM (syscheck) |
| Accounts in `/etc/passwd` use shadowed passwords | All | False positive; `awk -F: '$2 != "x"' /etc/passwd` prints nothing |

## Lessons from the rollout

- **sshd `Include` missing** on bastion and mgmt-services (older `sshd_config`), so the drop-in was ignored. The playbook now ensures `Include /etc/ssh/sshd_config.d/*.conf` as the first line.
- **Drop-ins beat appended settings.** sshd uses the first value it reads; settings appended to the end of `sshd_config` lose to anything earlier. apps had never received the old hardening at all (`permitrootlogin without-password`).
- **Socket-activated sshd** (cups): a reload re-execs sshd, which then cannot bind the socket's port and dies. The playbook restarts instead of reloading when `ssh.socket` is active.
- **`pwquality.conf.d`** is not created by the package; the playbook creates it.
- **`/etc/issue` on Proxmox/PBS** is rewritten by `pvebanner` at boot; only `/etc/issue.net` is managed there.
- **`/etc/sysctl.conf` is dead on current Debian.** Live values didn't match the file on any host; settings now live in `/etc/sysctl.d/`.
- **`all` + `default` isn't enough for OR'd sysctl keys.** Interfaces present before boot-time sysctl keep their own value; use `net.ipv4.conf.*` and apply with `systemd-sysctl`.
- **ufw re-applies its own sysctl file after boot** and turned martian logging back off on dmz until the playbook fixed its file.
- **Policy updates renumber and change checks.** A Wazuh policy update replaced every check number and changed which checks fail, which left the old accepted-checks table pointing at numbers that no longer existed. Checks are now named by title, and the table is rebuilt from a fresh per-host export.
- **SCA policy bugs** are common in the Debian CIS policy (escaping, `(d+)`, contradictory checks). Always compare a failing check's rule with the live state before changing config to satisfy it.

## Results

The baseline is applied fleet-wide, including the audit lock (`audit_immutable: true`; the bastion by hand). Checks passed of 207, from a fresh Wazuh SCA export per host:

| Hosts | Passed |
|---|---|
| apps, bastion, dmz, pbs, pve1-4 | 138 |
| mgmt-services, wazuh | 137 |
| ntfy (LXC) | 118 |
| cups (LXC) | 116 |

Before the baseline the same hosts scored 81 to 88. Every remaining failure is listed under [Accepted checks](#accepted-checks).
