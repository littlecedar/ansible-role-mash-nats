#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Travis Wichert
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# Validates .github/renovate.json and proves every manager extracts the pins it is
# meant to own. No credentials and no network: extraction reads the committed tree.
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# An optional image version lets maintainers reproduce failures before changing the pin.
mapfile -t versions < <(
    sed -n "s/^          NATS_RENOVATE_VERSION: '\([^']*\)'$/\1/p" \
        "$repo_dir/.github/workflows/renovate.yml"
)
if (( ${#versions[@]} != 1 )) || [[ -z "${versions[0]}" ]]; then
    echo 'Could not resolve exactly one pinned Renovate version' >&2
    exit 1
fi
version="${1:-${versions[0]}}"
image="ghcr.io/renovatebot/renovate:$version"
log_file="$(mktemp)"
trap 'rm -f -- "$log_file"' EXIT

docker_args=(
    --rm
    --network none
    --volume "$repo_dir:/workspace:ro"
    --workdir /workspace
    --env NODE_OPTIONS=--unhandled-rejections=strict
)

echo "Validating configuration with $image"
docker run "${docker_args[@]}" \
    --entrypoint renovate-config-validator \
    "$image" --strict

echo "Extracting dependencies with $image"
docker run "${docker_args[@]}" \
    --env LOG_LEVEL=info \
    --env LOG_FORMAT=json \
    "$image" --platform=local --dry-run=extract \
    | tee "$log_file"

# Exit status alone is insufficient: a startup crash can still exit 0.
# The missing-token warnings are expected: extraction needs no GitHub API access.
if ! jq --slurp --exit-status '
    all(.[]; .level < 50)
    and any(.[]; .msg == "Repository finished" and .repository == "local")
    and any(.[];
        .msg == "Dependency extraction complete"
        and .stats.managers.regex.fileCount >= 4
        and .stats.managers.regex.depCount >= 5
        and .stats.managers["github-actions"].depCount > 0
    )
    and any(.[];
        .msg == "Extracted dependencies"
        and any(.packageFiles.regex[]?.deps[]?;
            .depName == "golang" and .datasource == "golang-version")
    )
    and any(.[];
        .msg == "Extracted dependencies"
        and any(.packageFiles.regex[]?.deps[]?;
            .depName == "nats-io/nats-server"
            and .datasource == "github-tags"
            and .currentValue == "2.15.1"
            and ((.currentDigest // "") | test("^[0-9a-f]{40}$")))
    )
    and any(.[];
        .msg == "Extracted dependencies"
        and (.packageFiles.regex | keys) as $files
        | all(["Dockerfile", "defaults/main.yml", "README.md", "docs/configuring-nats.md"][];
            . as $wanted | $files | index($wanted))
    )
' "$log_file"; then
    echo 'Renovate did not extract every expected dependency' >&2
    exit 1
fi

echo "Renovate $version passed configuration validation and dependency extraction"