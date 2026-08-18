set shell := ["bash", "-euc"]

image_name := env_var_or_default("IMAGE_NAME", "almalinux")
registry := env_var_or_default("IMAGE_REGISTRY", "ghcr.io/lewis-qs/bootc")
image := registry + "/" + image_name
version_major := env_var_or_default("VERSION_MAJOR", "10")
platform := env_var_or_default("PLATFORM", "linux/amd64")
public_key := "cosign.pub"
skopeo_image := env_var_or_default("SKOPEO_IMAGE", "quay.io/skopeo/stable@sha256:8870d39b1f18e6421da42aa13e562ce61cc58f230d238f4a905efe959ff8f491")
rechunk_image := env_var_or_default("RECHUNK_IMAGE", "ghcr.io/hhd-dev/rechunk:v1.2.4")
rechunk_out := "/tmp/rechunk"
podman := "sudo podman"

[group('build')]
image:
    #!/usr/bin/env bash
    set -euo pipefail
    {{podman}} build \
        --platform={{platform}} \
        --security-opt=label=disable \
        --cap-add=all \
        --device /dev/fuse \
        -t {{image_name}} \
        -f {{version_major}}/Containerfile \
        .

[group('build')]
rechunk:
    #!/usr/bin/env bash
    set -euo pipefail
    src="localhost/{{image_name}}:latest"
    rm -rf "{{rechunk_out}}"; mkdir -p "{{rechunk_out}}"
    {{podman}} volume rm -f rechunk_ostree >/dev/null 2>&1 || true
    work="$(mktemp -d)"; cref=""
    cleanup() {
        [ -n "$cref" ] && { {{podman}} unmount "$cref" >/dev/null 2>&1 || true; {{podman}} rm -f "$cref" >/dev/null 2>&1 || true; }
        rm -rf "$work"
        {{podman}} volume rm -f rechunk_ostree >/dev/null 2>&1 || true
    }
    trap cleanup EXIT
    host='{{image}}'; host="${host%%/*}"
    if [ -n "${GHCR_TOKEN:-}" ] && [ -n "${GITHUB_ACTOR:-}" ]; then
        authb64="$(printf '%s:%s' "$GITHUB_ACTOR" "$GHCR_TOKEN" | base64 -w0)"
        printf '{"auths":{"%s":{"auth":"%s"}}}' "$host" "$authb64" > "$work/auth.json"
    else
        printf '{}' > "$work/auth.json"
    fi
    cref="$({{podman}} create "$src" bash)"
    mount="$({{podman}} mount "$cref")"
    {{podman}} run --rm --security-opt label=disable -v "$mount":/var/tree -e TREE=/var/tree -u 0:0 {{rechunk_image}} /sources/rechunk/1_prune.sh
    {{podman}} run --rm --security-opt label=disable -v "$mount":/var/tree -e TREE=/var/tree -v rechunk_ostree:/var/ostree -e REPO=/var/ostree/repo -e RESET_TIMESTAMP=1 -u 0:0 {{rechunk_image}} /sources/rechunk/2_create.sh
    {{podman}} unmount "$cref"; {{podman}} rm "$cref"; cref=""; {{podman}} rmi "$src"
    {{podman}} run --rm --security-opt label=disable \
        -v "{{rechunk_out}}":/workspace -v "$work:/work:Z" -v rechunk_ostree:/var/ostree \
        -e REPO=/var/ostree/repo -e REGISTRY_AUTH_FILE=/work/auth.json \
        -e OUT_NAME={{image_name}} -e OUT_REF="oci:{{image_name}}" -e VERSION_FN=/workspace/version.txt \
        -e PREV_REF="${PREV_REF:-}" -e LABELS="${LABELS:-}" -e VERSION="${VERSION:-<date>}" \
        -u 0:0 {{rechunk_image}} /sources/rechunk/3_chunk.sh
    sudo chown -R "$(id -u):$(id -g)" "{{rechunk_out}}"
    echo "Rechunked -> oci:{{rechunk_out}}/{{image_name}}"

[group('publish')]
push-image ref oci_dir:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${GHCR_TOKEN:?push-image needs GHCR_TOKEN}"
    : "${GITHUB_ACTOR:?push-image needs GITHUB_ACTOR}"
    work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
    ref='{{ref}}'; host="${ref%%/*}"
    authb64="$(printf '%s:%s' "$GITHUB_ACTOR" "$GHCR_TOKEN" | base64 -w0)"
    printf '{"auths":{"%s":{"auth":"%s"}}}' "$host" "$authb64" > "$work/auth.json"
    tls=(); [ "${SIGN_INSECURE:-}" = "true" ] && tls=(--dest-tls-verify=false)
    for i in 1 2 3 4 5; do
        {{podman}} run --rm --security-opt label=disable --network host \
            -v '{{oci_dir}}':/img:Z -v "$work:/work:Z" -e REGISTRY_AUTH_FILE=/work/auth.json \
            {{skopeo_image}} copy --digestfile=/work/digestfile "${tls[@]}" oci:/img "docker://${ref}" && break || sleep $((10 * i))
    done
    sudo test -s "$work/digestfile"
    sudo cat "$work/digestfile" > /tmp/digestfile
    just sign-image "$ref" "$(cat /tmp/digestfile)"

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
    {{podman}} run --rm --security-opt label=disable --network host \
        -v "$work:/work:Z" -e REGISTRY_AUTH_FILE=/work/auth.json \
        {{skopeo_image}} copy --registries.d /work/regd --preserve-digests "${ma[@]}" "${tls[@]}" \
        --sign-by-sigstore-private-key /work/key --sign-passphrase-file /work/pass \
        "$src" "docker://${ref}"
    echo "Verifying ${ref} @ {{digest}} against the committed public key"
    {{podman}} run --rm --security-opt label=disable --network host \
        -v "$work:/work:Z" -e REGISTRY_AUTH_FILE=/work/auth.json \
        {{skopeo_image}} copy --policy /work/verify.json --registries.d /work/regd --preserve-digests "${ma[@]}" "${tls[@]}" \
        "$src" dir:/tmp/verified
    echo "Signed + verified ${ref} @ {{digest}}"

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

[group('release')]
image-version source:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${GHCR_TOKEN:?image-version needs GHCR_TOKEN}"
    : "${GITHUB_ACTOR:?image-version needs GITHUB_ACTOR}"
    work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
    dest='{{image}}'; host="${dest%%/*}"
    authb64="$(printf '%s:%s' "$GITHUB_ACTOR" "$GHCR_TOKEN" | base64 -w0)"
    printf '{"auths":{"%s":{"auth":"%s"}}}' "$host" "$authb64" > "$work/auth.json"
    tls=(); [ "${SIGN_INSECURE:-}" = "true" ] && tls=(--tls-verify=false)
    {{podman}} run --rm --security-opt label=disable --network host \
        -v "$work:/work:Z" -e REGISTRY_AUTH_FILE=/work/auth.json \
        {{skopeo_image}} inspect "${tls[@]}" "docker://${dest}:{{source}}" \
        | jq -r '.Labels["version"] // .Labels["redhat.version-id"] // empty' | tr -d '\r\n'

[group('release')]
release-promote version source:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${GHCR_TOKEN:?release-promote needs GHCR_TOKEN}"
    : "${GITHUB_ACTOR:?release-promote needs GITHUB_ACTOR}"
    work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
    dest='{{image}}'; host="${dest%%/*}"
    authb64="$(printf '%s:%s' "$GITHUB_ACTOR" "$GHCR_TOKEN" | base64 -w0)"
    printf '{"auths":{"%s":{"auth":"%s"}}}' "$host" "$authb64" > "$work/auth.json"
    tls=(); [ "${SIGN_INSECURE:-}" = "true" ] && tls=(--src-tls-verify=false --dest-tls-verify=false)
    itls=(); [ "${SIGN_INSECURE:-}" = "true" ] && itls=(--tls-verify=false)
    if {{podman}} run --rm --security-opt label=disable --network host \
         -v "$work:/work:Z" -e REGISTRY_AUTH_FILE=/work/auth.json \
         {{skopeo_image}} inspect "${itls[@]}" --raw "docker://${dest}:{{version}}" >/dev/null 2>&1; then
        echo "${dest}:{{version}} already present — skipping promote"
        exit 0
    fi
    echo "Promoting ${dest}:{{source}} -> ${dest}:{{version}}"
    {{podman}} run --rm --security-opt label=disable --network host \
        -v "$work:/work:Z" -e REGISTRY_AUTH_FILE=/work/auth.json \
        {{skopeo_image}} copy --all --preserve-digests "${tls[@]}" \
        "docker://${dest}:{{source}}" "docker://${dest}:{{version}}"

[group('release')]
verify-image ref:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${GHCR_TOKEN:?verify-image needs GHCR_TOKEN}"
    : "${GITHUB_ACTOR:?verify-image needs GITHUB_ACTOR}"
    work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
    cp '{{public_key}}' "$work/pub"
    ref='{{ref}}'; host="${ref%%/*}"; repo="${ref%:*}"
    mkdir "$work/regd"
    printf 'docker:\n  %s:\n    use-sigstore-attachments: true\n' "$host" > "$work/regd/reg.yaml"
    authb64="$(printf '%s:%s' "$GITHUB_ACTOR" "$GHCR_TOKEN" | base64 -w0)"
    printf '{"auths":{"%s":{"auth":"%s"}}}' "$host" "$authb64" > "$work/auth.json"
    printf '{"default":[{"type":"reject"}],"transports":{"docker":{"%s":[{"type":"sigstoreSigned","keyPath":"/work/pub","signedIdentity":{"type":"matchRepository"}}]}}}' "$repo" > "$work/verify.json"
    tls=(); [ "${SIGN_INSECURE:-}" = "true" ] && tls=(--src-tls-verify=false)
    echo "Verifying every instance of ${ref} against the committed public key"
    {{podman}} run --rm --security-opt label=disable --network host \
        -v "$work:/work:Z" -e REGISTRY_AUTH_FILE=/work/auth.json \
        {{skopeo_image}} copy --multi-arch all --policy /work/verify.json --registries.d /work/regd "${tls[@]}" \
        "docker://${ref}" dir:/tmp/verified
    echo "VERIFIED all instances of ${ref}"
