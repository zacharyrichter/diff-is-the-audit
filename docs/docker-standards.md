# Docker standard

What every Docker host is held to, enforced by [`playbooks/docker-standards.yml`](../playbooks/docker-standards.yml) on the `docker_hosts` group. The playbook writes `daemon.json` and checks every container and network against the rules below.

## Daemon

`/etc/docker/daemon.json` is rendered from `docker_daemon_base` (in `group_vars/all.yml`) merged with the host's `docker_daemon_extra`, and validated with `dockerd --validate` before it is installed. The fleet base:

```json
{
  "default-address-pools": [
    { "base": "172.28.0.0/14", "size": 24 }
  ],
  "log-driver": "json-file",
  "log-opts": { "max-file": "3", "max-size": "10m" }
}
```

- **Logs** are `json-file`, 10 MB times 3 files per container, so no container can fill a disk with its own log.
- **Address pools** hand out a /24 from `172.28.0.0/14` to any network without a pinned subnet. That range is clear of the pinned stack networks (`172.17` to `172.26`), the LANs and the VPN, so an unpinned network can never land on an address something else already uses.

The internet-facing host adds four settings through `docker_daemon_extra`, in [`host_vars/dmz.yml`](../inventory/host_vars/dmz.yml): `no-new-privileges`, `live-restore`, `userland-proxy: false` and `icc: false`. The reasons are in [no-open-doors](https://github.com/zacharyrichter/no-open-doors/blob/main/docs/container-and-daemon-hardening.md#the-docker-daemon).

A `daemon.json` change restarts Docker, and with it every container on the host, so the playbook is applied one host at a time. A container keeps its old log settings until it is recreated.

## Containers

The audit reads every container on the host and reports each problem by name:

| Rule | Detail |
|---|---|
| Not privileged | |
| Docker socket | A container may mount the socket only if it is listed in `docker_socket_allowed` (a socket proxy, the management agent, a CI runner) |
| Published ports | Only the ports in `docker_published_ports`, written as `container port/proto->hostport` |
| Image tags | A tag must name a version. Not allowed: no tag at all, `latest`, `nightly`, or any tag containing `rolling`; and a major-only tag such as `16` or `v3`, except for the databases in `docker_major_pin_allowed`, which are pinned to a major version on purpose. Renovate keeps the pins current ([trust-but-verify](https://github.com/zacharyrichter/trust-but-verify)) |
| Tag exceptions | `docker_tag_exceptions` holds a regular expression per exception, with its reason beside it. [`host_vars/mgmt-services.yml`](../inventory/host_vars/mgmt-services.yml) shows two: a browser image that follows its daily build for security fixes, and a locally built image with no upstream version |
| Log size | The container's `max-size` matches the daemon's. A mismatch means the container predates the setting and needs recreating |
| Management agent | `PERIPHERY_DISABLE_TERMINALS=true` (all host access is SSH), and `PERIPHERY_ALLOWED_IPS` set wherever the agent's port is published |

## Networks

- Every network except `bridge`, `host` and `none` is created and owned by a compose project. The audit flags a network with no compose project label, because it was made by hand and nothing records it.
- A network other stacks join is declared `external: true` in those stacks and owned by exactly one stack, pinned to its subnet wherever an address is referenced elsewhere (allow-lists, trusted proxies). Deploy the owning stack first.
- Never `down` a stack that owns a shared network; redeploy it.
