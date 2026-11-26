# Traefik standard

Enforced by [`playbooks/traefik-standards.yml`](../playbooks/traefik-standards.yml). It has two plays, for the two ways Traefik runs.

## Traefik in Docker

The `traefik_docker` group. The config lives in each host's stack repo, so this play doesn't write it; it **checks** the static and dynamic config and the container's labels, and it **installs** the access-log rotation.

### Config rules

| Rule | Why |
|---|---|
| `log.level: INFO`, with `maxSize`, `maxBackups` and `maxAge` set | Traefik rotates its own `traefik.log` |
| Every entrypoint sets `aliasHeadersStrategy: delete` (or `reject`) | A client can't send `X_Forwarded_For` to a backend that reads it as `X-Forwarded-For` |
| No deprecated keys (`disablePropagationCheck`, `delayBeforeCheck`) | Keys Traefik has deprecated |
| No global `serversTransport.insecureSkipVerify` | A backend with a self-signed certificate gets a named `serversTransport`, so the exception is visible and scoped |
| The dashboard is off, or its router has a middleware | The dashboard is never exposed bare |
| Every `forwardAuth` middleware sets `maxResponseBodySize` | Bounds how large an auth response Traefik will read |
| `accessLog.filePath` is the path logrotate rotates | The log being written and the log being rotated are the same file |

### Access log rotation

Traefik never rotates its access log. The play installs `/etc/logrotate.d/traefik-access`: daily, or at 100 MB, 14 kept, compressed. `traefik.log` is left to Traefik itself.

After a rotation Traefik must reopen the file, and it does that on `USR1`. The rule signals the container's process directly:

```
pid=$(docker inspect -f '{{.State.Pid}}' traefik) && kill -USR1 "$pid"
```

It never uses `docker kill`. Any `docker kill`, whatever the signal, marks the container as stopped by hand, and a container with `restart: unless-stopped` then stays down after the next daemon stop (a reboot, a stop-mode backup, a Docker upgrade). A rotation that signalled Traefik with `docker kill` had been arming exactly that on every host. The full account is [the postmortem in no-open-doors](https://github.com/zacharyrichter/no-open-doors/blob/main/docs/postmortem-the-logrotate-that-stopped-traefik.md).

A stale rotation rule under an older name is removed, so there is exactly one rule per log.

## Traefik on the notification server (native)

The `traefik_native` group, one host, where Traefik runs as a systemd service outside the container tooling. Ansible owns everything, with the files in `playbooks/files/ntfy-traefik/`:

- **`traefik.yml` and `dynamic.yml`** as in the repo: HTTP redirects to HTTPS, `aliasHeadersStrategy: delete`, the certificate requested explicitly, TLS 1.3 minimum with strict SNI, and logs to the journal (journald rotates them).
- **`/usr/local/bin/traefik` is owned by root**, so only root can replace what the service runs.
- **A daily update timer** runs [`traefik-update.sh`](../playbooks/files/ntfy-traefik/traefik-update.sh):
  - stays on the current major version; a new major is a deliberate, manual move
  - verifies the download against the release's published sha256 checksums before installing
  - keeps the previous binary and restores it if Traefik doesn't come up
  - notifies only when something changed or failed
