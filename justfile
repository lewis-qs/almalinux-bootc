set shell := ["bash", "-euc"]

image_name := env_var_or_default("IMAGE_NAME", "almalinux")
registry := env_var_or_default("IMAGE_REGISTRY", "ghcr.io/lewis-qs/bootc")
image := registry + "/" + image_name
version_major := env_var_or_default("VERSION_MAJOR", "10")
platform := env_var_or_default("PLATFORM", "linux/amd64")
public_key := "cosign.pub"
skopeo_image := env_var_or_default("SKOPEO_IMAGE", "quay.io/skopeo/stable@sha256:8870d39b1f18e6421da42aa13e562ce61cc58f230d238f4a905efe959ff8f491")
podman := "sudo podman"

# Build the bootc image for {{version_major}} on {{platform}} (LABELS env -> labels + annotations).
[group('build')]
image:
    #!/usr/bin/env bash
    set -euo pipefail
    args=()
    while IFS= read -r l; do
        [ -n "$l" ] && args+=(--label "$l" --annotation "$l")
    done <<< "${LABELS:-}"
    {{podman}} build \
        --platform={{platform}} \
        --security-opt=label=disable \
        --cap-add=all \
        --device /dev/fuse \
        --iidfile /tmp/image-id \
        "${args[@]}" \
        -t {{image_name}} \
        -f {{version_major}}/Containerfile \
        .

# Rechunk the freshly built image into fewer, reproducible layers.
[group('build')]
rechunk:
    #!/usr/bin/env bash
    set -euo pipefail
    {{podman}} run --rm --privileged --security-opt=label=disable \
        -v /var/lib/containers:/var/lib/containers:z \
        quay.io/centos-bootc/centos-bootc:stream10 \
        /usr/libexec/bootc-base-imagectl rechunk \
        localhost/{{image_name}}:latest localhost/rechunked-{{image_name}}:latest
    {{podman}} tag localhost/rechunked-{{image_name}}:latest localhost/{{image_name}}:latest
    {{podman}} rmi localhost/rechunked-{{image_name}}:latest

# Push {{image_id}} to {{ref}} (with retries), then sign + verify the pushed digest.
[group('publish')]
push-image ref image_id:
    #!/usr/bin/env bash
    set -euo pipefail
    rm -f /tmp/digestfile
    for i in 1 2 3 4 5; do
        {{podman}} push --authfile "$HOME/.docker/config.json" --digestfile=/tmp/digestfile {{image_id}} "docker://{{ref}}" && break || sleep $((10 * i))
    done
    [ -f /tmp/digestfile ]
    just sign-image '{{ref}}' "$(cat /tmp/digestfile)"

# Assemble, push, and sign the multi-arch manifest (reads DIGESTS_JSON, TAGS, LABELS from env).
[group('publish')]
push-manifest:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${DIGESTS_JSON:?push-manifest needs DIGESTS_JSON}"
    : "${TAGS:?push-manifest needs TAGS}"
    dest='{{image}}'
    podman manifest create "$dest"
    for platform in $(jq -r 'to_entries | .[].key' <<< "$DIGESTS_JSON"); do
        digest=$(jq -r --arg p "$platform" '.[$p].digest' <<< "$DIGESTS_JSON")
        if [[ "$platform" == */v* ]]; then
            podman manifest add "$dest" "$dest@$digest" --arch "${platform%/*}" --variant "${platform#*/}"
        else
            podman manifest add "$dest" "$dest@$digest" --arch "$platform"
        fi
    done
    while IFS= read -r l; do
        [ -n "$l" ] && podman manifest annotate --index --annotation "$l" "$dest"
    done <<< "${LABELS:-}"
    ref=""
    while IFS= read -r tag; do
        [ -n "$tag" ] || continue
        rm -f /tmp/digestfile
        for i in 1 2 3 4 5; do
            podman manifest push --authfile "$HOME/.docker/config.json" --all=false --digestfile=/tmp/digestfile "$dest" "$dest:$tag" && break || sleep $((10 * i))
        done
        [ -f /tmp/digestfile ]
        ref="$dest:$tag"
    done <<< "$TAGS"
    just sign-image "$ref" "$(cat /tmp/digestfile)" index-only

# Sign {{ref}} at {{digest}} with the sigstore key, then verify it against the
# committed public key under a fail-closed policy. Skopeo runs from a pinned
# container; auth and key material stay in a throwaway work dir.
[group('signing')]
[private]
sign-image ref digest multi_arch="":
    #!/usr/bin/env bash
    set -euo pipefail
    : "${SIGSTORE_PRIVATE_KEY:?sign-image needs SIGSTORE_PRIVATE_KEY}"
    : "${GHCR_TOKEN:?sign-image needs GHCR_TOKEN}"
    : "${GITHUB_ACTOR:?sign-image needs GITHUB_ACTOR}"
    work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
    printf '%s' "$SIGSTORE_PRIVATE_KEY" > "$work/key"
    printf '%s' "${SIGSTORE_PASSPHRASE:-}" > "$work/pass"
    cp '{{public_key}}' "$work/pub"
    ref='{{ref}}'; host="${ref%%/*}"; repo="${ref%:*}"
    src="docker://${repo}@{{digest}}"
    mkdir "$work/regd"
    printf 'docker:\n  %s:\n    use-sigstore-attachments: true\n' "$host" > "$work/regd/reg.yaml"
    authb64="$(printf '%s:%s' "$GITHUB_ACTOR" "$GHCR_TOKEN" | base64 -w0)"
    printf '{"auths":{"%s":{"auth":"%s"}}}' "$host" "$authb64" > "$work/auth.json"
    printf '{"default":[{"type":"reject"}],"transports":{"docker":{"%s":[{"type":"sigstoreSigned","keyPath":"/work/pub","signedIdentity":{"type":"matchRepository"}}]}}}' "$repo" > "$work/verify.json"
    ma=(); [ -n '{{multi_arch}}' ] && ma=(--multi-arch '{{multi_arch}}')
    tls=(); [ "${SIGN_INSECURE:-}" = "true" ] && tls=(--src-tls-verify=false --dest-tls-verify=false)
    echo "Signing ${ref} @ {{digest}} (native sigstore via {{skopeo_image}})"
    podman run --rm --security-opt label=disable --network host \
        -v "$work:/work:Z" -e REGISTRY_AUTH_FILE=/work/auth.json \
        {{skopeo_image}} copy --registries.d /work/regd --preserve-digests "${ma[@]}" "${tls[@]}" \
        --sign-by-sigstore-private-key /work/key --sign-passphrase-file /work/pass \
        "$src" "docker://${ref}"
    echo "Verifying ${ref} @ {{digest}} against the committed public key"
    podman run --rm --security-opt label=disable --network host \
        -v "$work:/work:Z" -e REGISTRY_AUTH_FILE=/work/auth.json \
        {{skopeo_image}} copy --policy /work/verify.json --registries.d /work/regd --preserve-digests "${ma[@]}" "${tls[@]}" \
        "$src" dir:/tmp/verified
    echo "Signed + verified ${ref} @ {{digest}}"

# Log podman in to the registry host using GHCR_TOKEN + GITHUB_ACTOR.
[group('auth')]
[private]
ghcr-login:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${GHCR_TOKEN:?ghcr-login needs GHCR_TOKEN}"
    : "${GITHUB_ACTOR:?ghcr-login needs GITHUB_ACTOR}"
    install -m 700 -d "$HOME/.docker"
    host='{{registry}}'; host="${host%%/*}"
    printf '%s' "$GHCR_TOKEN" | podman login --authfile "$HOME/.docker/config.json" -u "$GITHUB_ACTOR" --password-stdin "$host"

# Generate a passphrase-less sigstore keypair and install the public key to {{public_key}}.
[group('signing')]
sigstore-keygen:
    #!/usr/bin/env bash
    set -euo pipefail
    command -v skopeo >/dev/null || { echo "skopeo required" >&2; exit 1; }
    out="$(mktemp -d)"; chmod 700 "$out"
    : > "$out/pass"
    skopeo generate-sigstore-key --output-prefix "$out/sigstore" --passphrase-file "$out/pass"
    [ -s "$out/sigstore.private" ] && [ -s "$out/sigstore.pub" ]
    install -D -m 0644 "$out/sigstore.pub" '{{public_key}}'
    echo "Public key installed to {{public_key}} — commit it."
    echo "Private key: $out/sigstore.private"
    echo "Set GH secret SIGSTORE_PRIVATE_KEY from it and back it up, then: rm -rf $out"
