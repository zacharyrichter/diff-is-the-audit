# The audit model

A standard that lives in a document drifts. A standard that lives in a playbook can be run, and a playbook that can be run can be run in check mode: it reports what it *would* change without changing anything. That report is the audit.

## The rule

| Run | What it does |
|---|---|
| `ansible-playbook <playbook> --check --diff` | Changes nothing. Every task that would change something reports `changed` and shows the lines that differ. |
| `ansible-playbook <playbook>` | Makes the host match the standard. |

A host that already meets the standard reports `changed=0 failed=0`. Anything else is drift, and the diff names it.

## Rules that can't be a change

Some requirements can't be fixed by writing a file. They are assertions in the same playbook, and an assertion that fails stops with a message that names the host and the cause:

| Playbook | Assertion |
|---|---|
| `base-standards.yml` | Every repository keyring the sources files point at exists |
| | Proxmox and backup hosts must not have unattended-upgrades installed (they are patched by hand) |
| | `/usr/sbin/sendmail` is never a regular file, so a real mail server can't appear unnoticed |
| | No login account other than `admin` has a human UID |
| | A leftover file marked for removal isn't still referenced by a systemd unit |
| `docker-standards.yml` | No privileged containers, no Docker socket mounts or published ports outside the host's allow-lists, no moving or major-only image tags, one log size everywhere, every network owned by a compose project |
| `traefik-standards.yml` | The static and dynamic config meet the rules in [traefik-standards.md](traefik-standards.md) |
| `pve-standards.yml` | The backup storage is reachable now, and every backup job writes to it in the right mode |

Because the check and the fix are the same file, they can't disagree about what "correct" means.

## Roles

A host gets a standard because it is in a group in `inventory/hosts.yml`:

| Inventory group | Hosts | Playbooks |
|---|---|---|
| `debian_fleet` | bastion, mgmt-services, apps, dmz, ntfy, cups, wazuh | `base-standards.yml`, `cis-baseline.yml` |
| `proxmox` | pve1-4 | `base-standards.yml`, `pve-standards.yml`, `cis-baseline.yml` |
| `backup` | pbs | `base-standards.yml`, `pve-standards.yml`, `cis-baseline.yml` |
| `docker_hosts` | apps, dmz, mgmt-services, wazuh | `docker-standards.yml` |
| `traefik_docker` | apps, dmz, mgmt-services | `traefik-standards.yml` |
| `traefik_native` | ntfy | `traefik-standards.yml` |
| `lxc` | ntfy, cups | (no time sync inside; they use the Proxmox node's clock) |

The `vlan_*` groups carry per-network values, such as which gateway a host takes its time from.

## Where values live

- **Shared values** are in `inventory/group_vars/all.yml`: the time zone, the journald limit, the Docker daemon base, the image-tag rules.
- **Per-network values** are in `inventory/group_vars/vlan_*.yml`.
- **Every exception** is in `inventory/host_vars/<host>.yml`, with the reason next to it. [`dmz.yml`](../inventory/host_vars/dmz.yml) adds daemon hardening for the internet-facing host. [`mgmt-services.yml`](../inventory/host_vars/mgmt-services.yml) shows image-tag exceptions, each with a reason. [`pve1.yml`](../inventory/host_vars/pve1.yml) names the backup job that stops its VMs.

If a standard changes, one value changes. If a host is the exception, the reason is in the file that makes it one.

## Running the audit

Run from the repo root on the management host. The checks read Docker, `/etc/pve` and sudoers, so they need root. They run as the `admin` account, using SSH aliases named `<host>-admin` that connect with its certificate:

```
Z=(-e ansible_user=admin -e 'ansible_host={{ inventory_hostname }}-admin' -K)
ansible-playbook playbooks/base-standards.yml    "${Z[@]}" --check --diff
ansible-playbook playbooks/docker-standards.yml  "${Z[@]}" --check --diff
ansible-playbook playbooks/traefik-standards.yml "${Z[@]}" --check --diff
ansible-playbook playbooks/pve-standards.yml     "${Z[@]}" --check --diff
```

If `Z` is empty in your shell, the command silently runs as the `ansible` account and fails with "Missing sudo password". `echo "${Z[@]}"` shows whether it is set.

Reading the result:

- **`changed=0 failed=0` on every host** means the fleet meets the standard.
- **A handler counts as a change.** A task that notifies a handler, such as a service restart, shows as two changes in check mode: the task and the handler it would run.
- **A failed assertion** prints the host and the reason. Nothing is fixed automatically, because the fix is a decision.
- **Skipped tasks are normal.** Role-scoped tasks skip on hosts outside the role.

## Applying a fix

Run the same command without `--check`, one host at a time (`-l <host>`), and check the host before moving on. Two playbooks deserve the caution:

- `docker-standards.yml` restarts Docker when `daemon.json` changes, which restarts every container on that host.
- `pve-standards.yml` replaces files under `/etc/pve`, which the cluster filesystem replicates to every node. See [proxmox-standards.md](proxmox-standards.md#files-under-etcpve).

After a real run, run the check again. It should report `changed=0`.

## New hosts

After the host's initial install hardening, add it to its role groups in `inventory/hosts.yml`. Run each of its role playbooks with `--check --diff`, then for real. A new Docker host also gets a `host_vars` file with `docker_socket_allowed` and `docker_published_ports`.

## A change from start to finish

The Wazuh SCA scan of the CIS baseline reported two failing checks on every host: "Ensure journald Compress is configured" and "Ensure journald Storage is configured". The fix was two lines in the journald drop-in in `base-standards.yml`:

```
[Journal]
SystemMaxUse={{ journald_system_max_use }}
Storage=persistent
Compress=yes
```

1. **Check, whole fleet.** `base-standards.yml --check --diff` showed one changed task on each of the 11 hosts the playbook reaches. Each diff was the same two added lines, and no host showed anything else or failed. Each host reported two changes, the task and the journald restart handler.
2. **Apply to one host, then verify.** On the first host the drop-in held all three settings, `/var/log/journal` existed, and journald was active.
3. **Apply to the rest.** `-l 'all:!<first host>:!bastion'`.
4. **Check again.** `changed=0 failed=0` on all 11 hosts.
5. **The host outside the model.** The same lines went onto the bastion by hand, from the block in [base-standards.md](base-standards.md#bastion), which was updated in the same commit as the playbook.
6. **Rescan.** The Wazuh agents were restarted to trigger a scan, and each host gained exactly two passed checks (see [cis-baseline.md](cis-baseline.md#results)).

The playbook, the documented standard and the by-hand block changed together, and the audit proved the fleet had followed.

## Lessons

- **Make the check and the fix one file.** Separate audit scripts and fix scripts disagree eventually.
- **Run the audit before the fix, every time.** The diff is the review.
- **Docker restarts everything on a `daemon.json` change.** That is why applying is one host at a time.
- **Name policy checks by title, never by number.** Scanner policies renumber on update, which left an accepted-checks table pointing at checks that no longer existed ([cis-baseline.md](cis-baseline.md#lessons-from-the-rollout)).
- **`docker kill` marks a container as stopped by hand.** A restart policy of `unless-stopped` then won't bring it back after a daemon restart. Signalling the container's process directly avoids that ([traefik-standards.md](traefik-standards.md#access-log-rotation)).
