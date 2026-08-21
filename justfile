set shell := ["bash", "-euc"]

image_name := env_var_or_default("IMAGE_NAME", "almalinux")
registry := env_var_or_default("IMAGE_REGISTRY", "ghcr.io/lewis-qs/bootc")
image := registry + "/" + image_name
version_major := env_var_or_default("VERSION_MAJOR", "10")
variant := env_var_or_default("IMAGE_VARIANT", "")
platform := env_var_or_default("PLATFORM", "linux/amd64")
public_key := "cosign.pub"
skopeo_image := env_var_or_default("SKOPEO_IMAGE", "quay.io/skopeo/stable:latest")
rechunk_image := env_var_or_default("RECHUNK_IMAGE", "quay.io/centos-bootc/centos-bootc:stream10")
podman := "sudo podman"

# build the base image, or a variant (e.g. `just image gnome`) from Containerfile.<variant>
[group('build')]
image var=variant:
    #!/usr/bin/env bash
    set -euo pipefail
    cf="{{version_major}}/Containerfile"
    if [ -n "{{ var }}" ]; then cf="{{version_major}}/Containerfile.{{ var }}"; fi
    {{podman}} build \
        --platform={{platform}} \
        --security-opt=label=disable \
        --cap-add=all \
        --device /dev/fuse \
        -t {{image_name}} \
        -f "$cf" \
        .

[group('build')]
rechunk:
    #!/usr/bin/env bash
    set -euo pipefail
    src="localhost/{{image_name}}:latest"
    labels=()
    while IFS= read -r l; do [ -n "$l" ] && labels+=(-l "$l"); done <<< "${LABELS:-}"
    {{podman}} run --rm --privileged --security-opt=label=disable \
        -v /var/lib/containers:/var/lib/containers \
        {{rechunk_image}} \
        rpm-ostree compose build-chunked-oci --bootc --format-version=1 \
        --from="$src" --output="containers-storage:localhost/rechunked-{{image_name}}:latest" \
        "${labels[@]}"
    {{podman}} tag localhost/rechunked-{{image_name}}:latest "$src"
    {{podman}} rmi localhost/rechunked-{{image_name}}:latest
    echo "Rechunked $src"

[group('publish')]
push-image ref image_id:
    #!/usr/bin/env bash
    set -euo pipefail
    sudo rm -f /tmp/digestfile
    for i in 1 2 3 4 5; do
        {{podman}} push --authfile "$HOME/.docker/config.json" --digestfile=/tmp/digestfile {{image_id}} "docker://{{ref}}" && break || sleep $((10 * i))
    done
    sudo test -s /tmp/digestfile
    sudo chown "$(id -u):$(id -g)" /tmp/digestfile
    just sign-image '{{ref}}' "$(cat /tmp/digestfile)"

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
        "$src" dir:/tmp/verified \
        || { echo "verify failed; skopeo runs unpinned ({{skopeo_image}}) — check whether a skopeo update introduced a breaking change" >&2; exit 1; }
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

# the previous released tag for a major (empty if none), for release-note diffs
[private]
[group('release')]
previous-release major current:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${GHCR_TOKEN:?previous-release needs GHCR_TOKEN}"
    : "${GITHUB_ACTOR:?previous-release needs GITHUB_ACTOR}"
    work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
    dest='{{image}}'; host="${dest%%/*}"
    authb64="$(printf '%s:%s' "$GITHUB_ACTOR" "$GHCR_TOKEN" | base64 -w0)"
    printf '{"auths":{"%s":{"auth":"%s"}}}' "$host" "$authb64" > "$work/auth.json"
    tls=(); [ "${SIGN_INSECURE:-}" = "true" ] && tls=(--tls-verify=false)
    case '{{ major }}' in
      10-kitten) pat='^10-kitten-[0-9]{8}$' ;;
      *) pat='^{{ major }}\.[0-9]+-[0-9]{8}$' ;;
    esac
    tags="$({{podman}} run --rm --security-opt label=disable --network host \
        -v "$work:/work:Z" -e REGISTRY_AUTH_FILE=/work/auth.json \
        {{skopeo_image}} list-tags "${tls[@]}" "docker://${dest}" | jq -r '.Tags[]')"
    printf '%s\n' "$tags" | grep -E "$pat" | grep -vx '{{ current }}' | sort -V | tail -1 || true

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
        "docker://${ref}" dir:/tmp/verified \
        || { echo "verify failed; skopeo runs unpinned ({{skopeo_image}}) — check whether a skopeo update introduced a breaking change" >&2; exit 1; }
    echo "VERIFIED all instances of ${ref}"
