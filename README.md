<!--
SPDX-FileCopyrightText: 2026 Travis Wichert
SPDX-License-Identifier: AGPL-3.0-or-later
-->
# NATS

An Ansible role that deploys a standalone [NATS](https://github.com/nats-io/nats-server)
server for MASH playbooks: one systemd-wrapped container from a hardened image built by
this repository.

## Requirements

- Linux with Docker and systemd on the target host.
- The `community.docker` Ansible collection.
- The `com.devture.ansible.role.playbook_help` and
  `com.devture.ansible.role.systemd_docker_base` roles, which provide
  `devture_playbook_help_container_retries_*` and `devture_systemd_docker_base_*`
  (systemd path, Docker command, pull and network-creation methods, network driver
  options, stop grace time, cleanup timeouts). These are **not** declared in
  `meta/main.yml`, so the role stays usable standalone.

## Container image

The default image is public, so the role pulls it anonymously with no registry login.

| Image | Upstream | Pinned version |
| --- | --- | --- |
| `ghcr.io/littlecedar/ansible-role-mash-nats:2.15.1` | [NATS server](https://github.com/nats-io/nats-server) | NATS `2.15.1` (`b2fd3efc`) |

To use a locally built image, point `nats_container_image` at it and set
`nats_container_image_pull: false`.

```sh
docker build -t ansible-role-mash-nats:local .
./scripts/smoke-test-nats.sh ansible-role-mash-nats:local
```

The Dockerfile records both the upstream version and the commit and fails the build if
the tag no longer points at that commit. To upgrade NATS, bump `ARG NATS_VERSION` and
`ARG NATS_COMMIT` in the `Dockerfile`, update `nats_container_image_tag` in
`defaults/main.yml`, and update the pin table here and in
[`docs/configuring-nats.md`](docs/configuring-nats.md). The publish workflow derives the
image tags from the Dockerfile ARGs.

## Contract for consumers

These four values are the stable interface other roles consume; everything else is an
implementation detail of this role.

| Variable | Default | Meaning |
| --- | --- | --- |
| `nats_identifier` | `nats` | Container and unit name, and the Docker DNS name on its network |
| `nats_container_network` | `{{ nats_identifier }}` | The network the server listens on |
| `nats_token` | empty, required | The bearer token: the server accepts it, the client presents it |
| port | `4222` | Fixed; not a variable |

The server network is `internal`, so it has no host route. A consumer MUST attach its
container to that network and connect to `{{ nats_identifier }}:4222`; the server
publishes no host port.

## Using the role in a MASH playbook

`inventory/components/nats/requirements.yml`:

```yaml
- src: git+https://github.com/littlecedar/ansible-role-mash-nats.git
  version: v2.15.1-0
  name: nats
```

`inventory/components/nats/component.yml` (the component is in use when the inventory
sets any variable starting with `nats_`):

```yaml
activation_prefix: nats_
inject:
  systemd_service_manager:
    services:
      - name: "{{ nats_identifier }}.service"
        priority: 2000
        restart_necessary: "{{ nats_restart_necessary | bool }}"
        groups: [mash, nats]
        when: "{{ nats_enabled }}"
```

`inventory/components/nats/wiring.yml`:

```yaml
nats_enabled: false
nats_identifier: "{{ mash_playbook_service_identifier_prefix }}nats"
nats_base_path: "{{ mash_playbook_base_path }}/{{ mash_playbook_service_base_directory_name_prefix }}nats"
nats_uid: "{{ mash_playbook_uid }}"
nats_gid: "{{ mash_playbook_gid }}"
nats_token: "{{ (mash_playbook_generic_secret_key + ':nats.token') | hash('sha512') }}"
```

Then, in the inventory's `vars.yml`, set `nats_enabled: true`. Install the service with
`just install-service nats` (or `just setup-service nats` to run the uninstall path too).

## Variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `nats_enabled` | `false` | Master toggle for the whole role |
| `nats_identifier` | `nats` | Container, unit and Docker DNS name |
| `nats_base_path` | `/{{ nats_identifier }}` | Host directory holding `nats.conf` |
| `nats_uid` | empty, required | User owning the support file and running the container |
| `nats_gid` | empty, required | Group owning the support file and running the container |
| `nats_token` | empty, required | Bearer token accepted by the server |
| `nats_container_network` | `{{ nats_identifier }}` | Internal container network the server listens on |
| `nats_container_network_deletion_enabled` | `true` | Remove the network on uninstall |
| `nats_container_image_tag` | `2.15.1` | Tag of the published image |
| `nats_container_image` | `ghcr.io/littlecedar/ansible-role-mash-nats:{{ nats_container_image_tag }}` | Image reference |
| `nats_container_image_pull` | `true` | Pull the image before starting the container |
| `nats_systemd_required_services_list` | `_default` + `_auto` + `_custom` | `Requires=`/`After=` of the unit |
| `nats_systemd_required_services_list_default` | the Docker service | Docker must be up first |
| `nats_systemd_required_services_list_auto` | `[]` | Filled in by the playbook |
| `nats_systemd_required_services_list_custom` | `[]` | Operator additions |
| `nats_systemd_wanted_services_list` | `_default` + `_auto` + `_custom` | `Wants=` of the unit |
| `nats_systemd_wanted_services_list_default` | `[]` | Empty by default |
| `nats_systemd_wanted_services_list_auto` | `[]` | Filled in by the playbook |
| `nats_systemd_wanted_services_list_custom` | `[]` | Operator additions |
| `nats_container_tmpfs_tmp_size` | `16m` | Size of the `/tmp` tmpfs |
| `nats_container_stop_grace_time_seconds` | `devture_systemd_docker_base_container_stop_grace_time_seconds` | Graceful stop timeout |
| `nats_container_cleanup_timeout_seconds` | `devture_systemd_docker_base_container_cleanup_timeout_seconds` | Stale-container cleanup timeout |
| `nats_container_cleanup_retry_delay_seconds` | `devture_systemd_docker_base_container_cleanup_retry_delay_seconds` | Delay between cleanup attempts |
| `nats_container_cleanup_command` | rendered | The unit's `ExecStartPre` cleanup loop |
| `nats_restart_necessary` | `false` | Set during installation; drives the playbook's restart handling |

## Security

- Non-root: the image defaults to UID/GID `1000:1000`; the role runs the container as
  `nats_uid`/`nats_gid`.
- Read-only root filesystem, `--cap-drop=ALL`, `--security-opt=no-new-privileges`.
- Shell-free `scratch` runtime: no `/bin/sh`, no compiler, no package manager.
- The token lives only in the mode-`0640` `nats.conf`, never in the container's
  arguments or environment.
- No host port, and the container network is an `internal` bridge.

## Operating

```sh
systemctl status nats
journalctl -u nats -f
```

Containers log through systemd only (`--log-driver=none`). Setting `nats_enabled: false`
and re-running the playbook stops and removes the unit, the container, and — when
`nats_container_network_deletion_enabled` is true — the network, plus `nats_base_path`.

## Development

```sh
yamllint .
ansible-lint
shellcheck scripts/*.sh
ansible-galaxy role install -r molecule/default/requirements.yml   # once
ansible-galaxy collection install community.docker ansible.posix  # once
molecule test          # nested Docker inside a privileged VM-like container
```

`molecule test` builds the image in `molecule/default/prepare.yml`, converges the role,
starts the unit and asserts the security and configuration invariants in
`molecule/verify_tasks.yml`: a token client completes the NATS handshake, a client without
the token is refused, and a published message reaches a subscriber.

## License

AGPL-3.0-or-later. See [`LICENSE`](LICENSE).
