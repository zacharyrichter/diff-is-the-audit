# diff-is-the-audit

**The playbook is the standard. The same playbook run in check mode is the audit.**

Twelve hosts: four Proxmox nodes, a backup server, five Debian VMs and two LXC containers, in a self-hosted lab I run as an enterprise-style environment. This repo is how I keep all twelve to one standard without a document per host that drifts the day after it is written.

Each playbook enforces its part of the standard. Run it with `--check --diff` and it reports every place a host has strayed, with the exact lines that differ. A fleet that meets the standard reports `changed=0 failed=0`.

```
TASK [journald settings (drop-in)]
--- before: /etc/systemd/journald.conf.d/60-fleet.conf
+++ after: /etc/systemd/journald.conf.d/60-fleet.conf
@@ -1,3 +1,5 @@
 # Managed by Ansible (base-standards.yml)
 [Journal]
 SystemMaxUse=500M
+Storage=persistent
+Compress=yes

changed: [dmz]
```

That is real output from a standard being tightened: two lines added to the playbook, and the check run showed exactly what each host was missing before anything was changed. [The worked example](docs/the-audit-model.md#a-change-from-start-to-finish) follows it through to the rescan.

## Four rules

1. **Anything that can be a change is a change.** The playbook makes the host match. Check mode shows what it would change; that is drift.
2. **Anything that can't be a change is an assertion in the same playbook.** No privileged containers, no moving image tags, no real mail server where the notification shim belongs, backup jobs in the right mode. The check and the fix live in one file, so they can't disagree.
3. **Roles come from inventory groups.** A host gets the Docker standard because it is in `docker_hosts`, not because someone edited a playbook.
4. **Every exception is a `host_vars` entry with its reason next to it.** The exceptions are the only per-host documentation there is, and they sit beside the values they change.

## What's here

| Path | What it is |
|---|---|
| [`docs/the-audit-model.md`](docs/the-audit-model.md) | How the model works, how to run it, and a standards change followed from start to finish |
| [`docs/base-standards.md`](docs/base-standards.md) | Every host: package sources, updates, time, journald, SSH keys, accounts |
| [`docs/docker-standards.md`](docs/docker-standards.md) | Docker hosts: daemon settings, containers, image tags, networks |
| [`docs/traefik-standards.md`](docs/traefik-standards.md) | Traefik, in Docker and native: config rules, log rotation, checksum-verified updates |
| [`docs/proxmox-standards.md`](docs/proxmox-standards.md) | Proxmox and backup server: firewall, root keys, and proof that the backup path works |
| [`docs/cis-baseline.md`](docs/cis-baseline.md) | CIS hardening scored by Wazuh SCA, with every accepted failure and its reason |
| `playbooks/` | The five playbooks, and the files and templates they install |
| `inventory/` | Role and network groups, shared values, and example per-host exceptions |

## Run it

From the repo root on the management host. The checks need root (Docker, `/etc/pve`, sudoers), so they run as the admin account through SSH aliases named `<host>-admin`:

```
Z=(-e ansible_user=admin -e 'ansible_host={{ inventory_hostname }}-admin' -K)
ansible-playbook playbooks/base-standards.yml    "${Z[@]}" --check --diff
ansible-playbook playbooks/docker-standards.yml  "${Z[@]}" --check --diff
ansible-playbook playbooks/traefik-standards.yml "${Z[@]}" --check --diff
ansible-playbook playbooks/pve-standards.yml     "${Z[@]}" --check --diff
```

To fix drift, run the same command without `--check`, one host at a time with `-l <host>`. The default `ansible` account has no sudo beyond a short list of read-only commands, so nothing that changes a host runs as it.

## Limits

- **A check only finds what someone wrote a rule for.** Passing the audit means the fleet matches the standard, not that the standard is complete.
- **The management host is a high-value target.** Whatever runs these playbooks can become root on every host in the inventory, so the controller sits on the isolated management network.
- **One host sits outside the model on purpose.** The bastion has no path from the management host, so its part of the base standard is applied by hand from a block in [`docs/base-standards.md`](docs/base-standards.md#bastion).
- **Some preconditions live outside this repo:** the SSH certificate authority that issues the normal login, the sendmail-compatible notification shim at `/usr/local/bin/ntfy-sendmail`, and the repository keyrings the playbooks refuse to run without.

## Related

- [no-open-doors](https://github.com/zacharyrichter/no-open-doors): the internet-facing host's own hardening, which builds on the Docker and Traefik standards here.
- [trust-no-cache](https://github.com/zacharyrichter/trust-no-cache): rebuilding the lab from a config repo, which applies the CIS baseline from this one.

Everything here is sanitized: domains are `example.net`, addresses are `10.0.x.x`, and the human account is `admin`.

MIT licensed. See [`LICENSE`](LICENSE).
