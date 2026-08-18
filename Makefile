PODMAN = sudo podman

IMAGE_NAME = almalinux-bootc
VERSION_MAJOR = 10
PLATFORM = linux/amd64
LABELS ?=

SKOPEO ?= skopeo
PUBLIC_KEY ?= cosign.pub
MULTI_ARCH ?=

.ONESHELL:
.PHONY: all
all: rechunk

.PHONY: image
image:
	$(PODMAN) build \
		--platform=$(PLATFORM) \
		--security-opt=label=disable \
		--cap-add=all \
		--device /dev/fuse \
		--iidfile /tmp/image-id \
		$(LABELS) \
		-t $(IMAGE_NAME) \
		-f $(VERSION_MAJOR)/Containerfile \
		.

rechunk:
	$(PODMAN) run \
		--rm --privileged \
		--security-opt=label=disable \
		-v /var/lib/containers:/var/lib/containers:z \
		quay.io/centos-bootc/centos-bootc:stream10 \
		/usr/libexec/bootc-base-imagectl rechunk \
		localhost/$(IMAGE_NAME):latest localhost/rechunked-$(IMAGE_NAME):latest && \
	$(PODMAN) tag localhost/rechunked-$(IMAGE_NAME):latest localhost/$(IMAGE_NAME):latest && \
	$(PODMAN) rmi localhost/rechunked-$(IMAGE_NAME):latest

.PHONY: sign
sign:
	set -e
	ref='$(IMAGE_REF)'; dig='$(DIGEST)'; pub='$(PUBLIC_KEY)'; key='$(SIGN_KEY)'; pass='$(SIGN_PASS)'; ma='$(MULTI_ARCH)'
	repo="$${ref%:*}"
	src="docker://$${repo}@$${dig}"
	flag=""; [ -n "$$ma" ] && flag="--multi-arch $$ma"
	regd="$$(mktemp -d)"
	printf 'docker:\n  %s:\n    use-sigstore-attachments: true\n' "$${ref%%/*}" > "$$regd/sign.yaml"
	policy="$$(mktemp)"
	printf '{"default":[{"type":"reject"}],"transports":{"docker":{"%s":[{"type":"sigstoreSigned","keyPath":"%s","signedIdentity":{"type":"matchRepository"}}]}}}' "$$repo" "$$pub" > "$$policy"
	$(SKOPEO) --registries.d "$$regd" copy --preserve-digests $$flag --sign-by-sigstore-private-key "$$key" --sign-passphrase-file "$$pass" "$$src" "docker://$$ref"
	verify="$$(mktemp -d)"
	$(SKOPEO) --registries.d "$$regd" copy --preserve-digests $$flag --policy "$$policy" "$$src" "dir:$$verify"
	rm -rf "$$regd" "$$policy" "$$verify"
