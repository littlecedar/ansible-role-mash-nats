<!--
SPDX-FileCopyrightText: 2026 Travis Wichert

SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Configuring NATS

This role deploys a single [NATS](https://github.com/nats-io/nats-server) server as one
systemd-wrapped container on an internal Docker network. Consumers attach their own
containers to that network; the server is never published on a host port.

## Contents

- [Requirements](#requirements)
- [Container images](#container-images)
- [Required variables](#required-variables)
- [Network](#network)
- [Secrets](#secrets)
- [Operating](#operating)
- [Troubleshooting](#troubleshooting)
- [License](#license)

## Requirements

- Docker and systemd on the target host.
- The `community.docker` collection.
- `com.devture.ansible.role.playbook_help` and
  `com.devture.ansible.role.systemd_docker_base` (provided by the MASH playbook).

## Container images

The role consumes an image built and published by this repository. The published
package is public, so the default pull needs no registry login. If you mirror it to a
private package, authenticate the target Docker daemon with a token that has
`read:packages`.

| Service | Default image | Pinned version |
| --- | --- | --- |
| NATS | `ghcr.io/littlecedar/ansible-role-mash-nats:2.15.1` | NATS `2.15.1` (`b2fd3efc`) |

| Variable | Default |
| --- | --- |
| `nats_container_image` | `ghcr.io/littlecedar/ansible-role-mash-nats:{{ nats_container_image_tag }}` |
| `nats_container_image_tag` | `2.15.1` |
| `nats_container_image_pull` | `true` |

There is no target-side self-build path. To use a locally built image, set
`nats_container_image` and `nats_container_image_pull: false`.

To upgrade NATS, change `ARG NATS_VERSION`/`ARG NATS_COMMIT` in the `Dockerfile`, then
update `nats_container_image_tag` in `defaults/main.yml` and the pin tables in this
guide and the README. The publish workflow derives its tags from the Dockerfile ARGs
(`sha-<short>`, plus `edge`, `latest` and the version on `main`); the role consumes the
defaults tag.

The publish workflow builds the image, runs its smoke test and the molecule scenario,
and only then pushes to GHCR. It runs on pushes to `main` and on manual dispatch, and it
never runs on tags: role releases (`v<version>-0`) are separate and publish no image.

## Required variables

`nats_enabled: true` makes the role validate its configuration before touching the
host. These variables have no usable default and must be set:

| Variable | Meaning |
| --- | --- |
| `nats_token` | Bearer token the server accepts and every client must present |
| `nats_uid` / `nats_gid` | Owner of the rendered support file, and the container's user and group |
| `nats_identifier` | Container and unit name, and the Docker DNS name on its network |

Validation rejects: empty required values, and an empty `nats_container_image` or
`nats_container_network`.

## Network

| Variable | Default | Notes |
| --- | --- | --- |
| `nats_container_network` | `{{ nats_identifier }}` | `internal` bridge; created by the role |
| `nats_container_network_deletion_enabled` | `true` | Remove the network on uninstall |

The network is an `internal` bridge with Docker's default address pool: it has no host
route and no gateway to the outside. A consumer MUST attach its container to
`nats_container_network` and connect to `<nats_identifier>:4222`; Docker's embedded DNS
resolves the container name on that network, so a recreated container keeps the same
address from the consumer's point of view. The server publishes no port.

| Port | Scope |
| --- | --- |
| `4222` | the NATS network only (no host publish) |

## Secrets

```sh
openssl rand -hex 32   # nats_token
```

In MASH the token is derived from `mash_playbook_generic_secret_key` (see the README
snippet). The token appears only in `nats.conf` under `nats_base_path` (mode `0640`,
owned by `nats_uid`/`nats_gid`) and is rendered into that file, never into the
container's arguments or environment. The file is mounted read-only; the container
runs with a read-only root filesystem, all capabilities dropped and
`no-new-privileges`.

## Operating

```sh
systemctl status nats
journalctl -u nats -f
```

The container logs through systemd (`--log-driver=none`). Restarting the unit recreates
only that container. Changing the rendered support file, the unit file or the image sets
`nats_restart_necessary`, which the MASH systemd service manager uses to restart the
unit.

`nats_enabled: false` (plus a playbook run) stops and removes the unit and the
container, removes the network when `nats_container_network_deletion_enabled` is true,
and removes `nats_base_path`.

## Troubleshooting

**The image cannot be pulled from GHCR.** The tag is not published yet, or the package
is not visible to the host. The published package is public, so the default pull needs
no login. If you use a private mirror, authenticate the target Docker daemon with a
token that has `read:packages`:

```sh
echo "$GHCR_TOKEN" | docker login ghcr.io -u <github-user> --password-stdin
```

**The client logs `Authorization Violation`.** The client's token differs from the
`nats_token` the server was rendered with. Both sides must use the same value;
`nats_token` is not stored by the server, so restart both units after changing it.

**A consumer cannot resolve the container name.** That container is not attached to
`nats_container_network`. Check `docker inspect --format '{{ "{{" }} json .NetworkSettings.Networks {{ "}}" }}' <consumer>`
and join the network the role created.

**The unit fails on start with a stale container.** The unit's `ExecStartPre` cleanup
loop removes a leftover container before creating a new one; if it reports a failure it
could not reach the Docker daemon. Check `systemctl status docker`, then
`systemctl restart nats`.

## License

AGPL-3.0-or-later. See [`LICENSE`](../LICENSE).
