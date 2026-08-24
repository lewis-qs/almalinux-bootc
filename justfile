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
driftah_image := env_var_or_default("DRIFTAH_IMAGE", "ghcr.io/lewis-qs/driftah@sha256:e953b9f0e42b10ed62e588ef1cfde417b0d739c367cadb749f1f09a3b3af8126")  # v1.4.1
bib_image := env_var_or_default("BIB_IMAGE", "quay.io/centos-bootc/bootc-image-builder:latest")
ovmf := env_var_or_default("OVMF_CODE", "/usr/share/edk2/ovmf/OVMF_CODE.fd")
local_image := "localhost/" + image_name + ":latest"
output_dir := env_var_or_default("OUTPUT_DIR", "output")
podman := "sudo podman"

# build the base image, or a variant: `just image workstation 10-kitten`
[group('build')]
image variant=variant major=version_major:
    #!/usr/bin/env bash
    set -euo pipefail
    cf="{{ major }}/Containerfile"
    if [ -n "{{ variant }}" ]; then cf="{{ major }}/Containerfile.{{ variant }}"; fi
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

# the previous released tag for a major+variant (empty if none), for release-note diffs
[private]
[group('release')]
previous-release major variant current:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${GHCR_TOKEN:?previous-release needs GHCR_TOKEN}"
    : "${GITHUB_ACTOR:?previous-release needs GITHUB_ACTOR}"
    work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
    dest='{{image}}'; host="${dest%%/*}"
    authb64="$(printf '%s:%s' "$GITHUB_ACTOR" "$GHCR_TOKEN" | base64 -w0)"
    printf '{"auths":{"%s":{"auth":"%s"}}}' "$host" "$authb64" > "$work/auth.json"
    tls=(); [ "${SIGN_INSECURE:-}" = "true" ] && tls=(--tls-verify=false)
    vs=""; [ '{{ variant }}' != "base" ] && vs="-{{ variant }}"
    case '{{ major }}' in
      10-kitten) pat="^10-kitten${vs}-[0-9]{8}$" ;;
      *) pat="^{{ major }}\.[0-9]+${vs}-[0-9]{8}$" ;;
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

# fill arches missing from a partial nightly's DIGESTS_JSON from the published manifest, so the manifest is always complete
[private]
[group('release')]
backfill-digests major variant digests:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${GHCR_TOKEN:?backfill-digests needs GHCR_TOKEN}"
    : "${GITHUB_ACTOR:?backfill-digests needs GITHUB_ACTOR}"
    dest='{{image}}'; host="${dest%%/*}"
    vs=""; [ '{{ variant }}' != "base" ] && vs="-{{ variant }}"
    src="${dest}:{{ major }}${vs}"
    merged='{{ digests }}'
    arches=(amd64 arm64); [ '{{ major }}' != "9" ] && arches+=(amd64/v2)
    complete=1  # already complete -> return unchanged, no registry call
    for a in "${arches[@]}"; do jq -e --arg a "$a" 'has($a)' <<<"$merged" >/dev/null || complete=0; done
    [ "$complete" = 1 ] && { printf '%s' "$merged"; exit 0; }
    work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
    authb64="$(printf '%s:%s' "$GITHUB_ACTOR" "$GHCR_TOKEN" | base64 -w0)"
    printf '{"auths":{"%s":{"auth":"%s"}}}' "$host" "$authb64" > "$work/auth.json"
    tls=(); [ "${SIGN_INSECURE:-}" = "true" ] && tls=(--tls-verify=false)
    raw="$({{podman}} run --rm --security-opt label=disable --network host \
        -v "$work:/work:Z" -e REGISTRY_AUTH_FILE=/work/auth.json \
        {{skopeo_image}} inspect "${tls[@]}" --raw "docker://${src}" 2>/dev/null || true)"
    [ -n "$raw" ] || { echo "backfill: no existing manifest at ${src}; leaving digests as-is" >&2; printf '%s' "$merged"; exit 0; }
    tmpl="$(jq -c 'to_entries | .[0].value' <<<"$merged")"  # version-id is uniform across arches
    for a in "${arches[@]}"; do
        jq -e --arg a "$a" 'has($a)' <<<"$merged" >/dev/null && continue
        arch="${a%%/*}"; var=""; [ "$a" != "$arch" ] && var="${a#*/}"
        d="$(jq -r --arg ar "$arch" --arg v "$var" \
            '.manifests[] | select(.platform.architecture==$ar and ((.platform.variant // "")==$v)) | .digest' \
            <<<"$raw" | head -1)"
        [ -n "$d" ] || { echo "backfill: ${a} not found in existing manifest ${src}" >&2; continue; }
        # refuse a version mismatch: the arch is genuinely stale (failed rebuild), not a no-update skip
        tver="$(jq -r '.version // empty' <<<"$tmpl")"
        bver="$({{podman}} run --rm --security-opt label=disable --network host \
            -v "$work:/work:Z" -e REGISTRY_AUTH_FILE=/work/auth.json \
            {{skopeo_image}} inspect "${tls[@]}" "docker://${dest}@${d}" \
            | jq -r '.Labels["version"] // .Labels["redhat.version-id"] // empty')"
        if [ -n "$tver" ] && [ -n "$bver" ] && [ "$bver" != "$tver" ]; then
            echo "backfill: ${a} is version ${bver} but the rebuilt arches are ${tver} — refusing to ship a stale arch" >&2
            exit 1
        fi
        merged="$(jq -c --arg a "$a" --arg d "$d" --argjson t "$tmpl" '. + {($a): ($t + {digest: $d})}' <<<"$merged")"
        echo "backfill: ${a} <- ${d} @ ${bver:-?} (from ${src})" >&2
    done
    printf '%s' "$merged"

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

# regenerate the "Current versions" table in README from the shipped images
[group('release')]
readme-versions:
    #!/usr/bin/env bash
    set -euo pipefail
    pkgs="kernel,bootc,systemd,podman,dnf,ostree,NetworkManager,glibc,openssl,selinux-policy"
    majors=(9 10 10-kitten)
    dest='{{image}}'

    s=$(grep -c '<!-- versions:start -->' README.md || true)
    e=$(grep -c '<!-- versions:end -->' README.md || true)
    [ "$s" = 1 ] && [ "$e" = 1 ] || { echo "README needs exactly one versions marker pair (start=$s end=$e)" >&2; exit 1; }
    [ "$(grep -n '<!-- versions:start -->' README.md | cut -d: -f1)" \
      -lt "$(grep -n '<!-- versions:end -->' README.md | cut -d: -f1)" ] \
      || { echo "README versions markers are out of order" >&2; exit 1; }

    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    declare -A cell
    for m in "${majors[@]}"; do
        {{podman}} run --rm --security-opt label=disable --network host \
            {{driftah_image}} --format json --paths '' --short-versions --highlight "$pkgs" \
            "${dest}:${m}" "${dest}:${m}" \
            | jq -r '.key_versions[] | [.name, (.versions | join(", "))] | @tsv' > "$tmp/kv"
        while IFS=$'\t' read -r name vers; do
            cell["${m}|${name}"]="$vers"
        done < "$tmp/kv"
        [ -n "${cell["${m}|kernel"]:-}" ] || { echo "no kernel version for ${m} — refusing to update README" >&2; exit 1; }  # kernel always present; absent = bad driftah output
    done

    {
        echo '| Package | 9 | 10 | 10-kitten |'
        echo '| --- | --- | --- | --- |'
        IFS=',' read -ra names <<<"$pkgs"
        for n in "${names[@]}"; do
            printf '| %s |' "$n"
            for m in "${majors[@]}"; do
                v="${cell["${m}|${n}"]:-}"
                if [ -n "$v" ]; then printf ' `%s` |' "$v"; else printf ' — |'; fi
            done
            printf '\n'
        done
    } > "$tmp/table"

    awk -v tbl="$tmp/table" '
        /<!-- versions:start -->/ {print; print ""; while ((getline l < tbl) > 0) print l; print ""; skip=1; next}
        /<!-- versions:end -->/   {skip=0}
        !skip {print}
    ' README.md > "$tmp/README.md"
    mv "$tmp/README.md" README.md
    echo "README versions table updated"

# verify a source image is signed by the project key before building from it (local images have no signature to check)
[private]
[group('disk')]
verify-source ref:
    #!/usr/bin/env bash
    set -euo pipefail
    case '{{ ref }}' in
        localhost/*|containers-storage:*|oci:*|dir:*)
            echo "verify-source: {{ ref }} is local — no signature to verify" ;;
        *)
            echo "verify-source: verifying {{ ref }} against {{public_key}} before building"
            just verify-image '{{ ref }}' ;;
    esac

# pull a published image: `just pull-image workstation 10-kitten`
[group('publish')]
pull-image variant=variant major=version_major:
    #!/usr/bin/env bash
    set -euo pipefail
    tag="{{ major }}"
    if [ -n "{{ variant }}" ]; then tag="{{ major }}-{{ variant }}"; fi
    {{podman}} pull "{{image}}:${tag}"

# build an installer ISO from a bootc image (osbuild via bootc-image-builder)
[group('disk')]
build-iso ref=local_image type="anaconda-iso":
    #!/usr/bin/env bash
    set -euo pipefail
    just verify-source "{{ ref }}"
    mkdir -p "{{output_dir}}"
    {{podman}} run --rm --privileged --security-opt label=disable \
        -v "$(pwd)/{{output_dir}}":/output \
        -v /var/lib/containers/storage:/var/lib/containers/storage \
        {{bib_image}} \
        --type {{ type }} --local "{{ ref }}"
    echo "ISO written under {{output_dir}}/bootiso/"

# generate a raw disk from a bootc image (bootc install to-disk --via-loopback)
[group('disk')]
build-vm ref=local_image size="10G":
    #!/usr/bin/env bash
    set -euo pipefail
    just verify-source "{{ ref }}"
    mkdir -p "{{output_dir}}"
    truncate -s {{ size }} "{{output_dir}}/disk.raw"
    {{podman}} run --rm --privileged --security-opt label=disable --pid=host \
        -v /var/lib/containers/storage:/var/lib/containers/storage \
        -v /dev:/dev \
        -v "$(pwd)/{{output_dir}}":/output \
        "{{ ref }}" \
        bootc install to-disk --via-loopback --generic-image --wipe /output/disk.raw
    echo "raw disk at {{output_dir}}/disk.raw"

# boot an installer ISO in qemu (UEFI + KVM)
[group('run')]
run-iso iso=(output_dir + "/bootiso/install.iso") mem="4096":
    qemu-system-x86_64 -machine q35 -accel kvm -cpu host -m {{ mem }} \
        -bios {{ovmf}} -cdrom "{{ iso }}" -boot d

# boot a raw disk image in qemu (UEFI + KVM)
[group('run')]
run-vm disk=(output_dir + "/disk.raw") mem="4096":
    qemu-system-x86_64 -machine q35 -accel kvm -cpu host -m {{ mem }} \
        -bios {{ovmf}} -drive file="{{ disk }}",format=raw,if=virtio
