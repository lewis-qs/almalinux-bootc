# AlmaLinux Bootable Container Base Images (bootc)

**<ins>Caution</ins>: AlmaLinux bootc images are currently *experimental*. Please use with care and report any issues.**

## Available Pre-built Images

Signed, pre-built images are published to the GitHub Container Registry:

* **`ghcr.io/lewis-qs/bootc/almalinux`** — base (tags: `9`, `10`, `10-kitten`, and dated release tags)
  * **minimal:** `9-minimal`, `10-minimal`, `10-kitten-minimal` (+ dated, e.g. `10.2-minimal-<date>`)
  * **workstation:** `9-workstation`, `10-workstation`, `10-kitten-workstation` (+ dated)

Images are signed with sigstore; the public key ships in each image at `/usr/share/almalinux-bootc/cosign.pub` and is enforced on update via the container policy shipped in `/usr`. Variants publish to the same repository, so the same key and policy cover them.

This project provides tooling to build experimental AlmaLinux bootable container images. These images leverage the [bootc project](https://containers.github.io/bootc/), which enables the creation of bootable OS images from container images.

Our images are based on the work done for [CentOS Bootc Base Images](https://gitlab.com/redhat/centos-stream/containers/bootc/-/tree/c10s?ref_type=heads) and utilize [bootc-base-imagectl](https://gitlab.com/fedora/bootc/base-images/-/blob/main/bootc-base-imagectl.md?ref_type=heads) for their construction.

## Current versions

Key package versions in the latest published image of each major, refreshed automatically on every release:

<!-- versions:start -->

| Package | 9 | 10 | 10-kitten |
| --- | --- | --- | --- |
| kernel | `5.14.0` | `6.12.0` | `6.12.0` |
| bootc | `1.13.0` | `1.15.2` | `1.16.2` |
| systemd | `252` | `257` | `257` |
| podman | `5.8.2` | `5.8.2` | `6.0.1` |
| dnf | `4.14.0` | `4.20.0` | `4.20.0` |
| ostree | `2025.7` | `2025.7` | `2026.2` |
| NetworkManager | `1.54.3` | `1.56.0` | `1.58~rc1` |
| glibc | `2.34` | `2.39` | `2.39` |
| openssl | `3.5.5` | `3.5.5` | `3.5.7` |
| selinux-policy | `38.1.75` | `42.1.18` | `42.1.25` |

<!-- versions:end -->

## Project Status & News

* **[2024-09-02]** AlmaLinux announces experimental bootc support and HeliumOS: [Read the blog post](https://almalinux.org/blog/2024-09-02-bootc-almalinux-heliumos/)
* For the latest general information about AlmaLinux, visit [almalinux.org](https://almalinux.org/get-almalinux/).



## Building Images (Advanced)

This repository uses [`just`](https://just.systems) to build the images locally. Run `just --list` to see the available recipes.

### Prerequisites

* `just`
* A container runtime like `podman` or `docker` (ensure it's running and you have appropriate permissions).
* Sufficient disk space and internet connectivity.

### Build Instructions

Build variables are passed as environment variables (`PLATFORM`, `VERSION_MAJOR`, `IMAGE_NAME`). The following examples demonstrate how to build specific variants:

### Example: AlmaLinux OS Kitten 10

```bash
PLATFORM=linux/amd64 VERSION_MAJOR=10-kitten just image
```

### Example: AlmaLinux OS 10 (x86_64-v2)

```bash
PLATFORM=linux/amd64/v2 VERSION_MAJOR=10 just image
```

### Example: AlmaLinux 9 (x86_64)

```bash
PLATFORM=linux/amd64 VERSION_MAJOR=9 just image
```

Then `just rechunk` (with the same `IMAGE_NAME`) to produce the final layered image.

**Explanation of Build Variables:**

* `PLATFORM`: Specifies the target architecture and variant (e.g., linux/amd64, linux/amd64/v2, linux/arm64).
* `IMAGE_NAME`: The base name for the output container image (defaults to `almalinux`).
* `VERSION_MAJOR`: The AlmaLinux major version (e.g., 9, 10, 10-kitten).

## Contributing and Community

We welcome contributions and feedback!  
Join the discussion and get involved with the relevant AlmaLinux Special Interest Groups (SIGs):

* **Atomic SIG:** Focused on atomic updates and related tooling (like bootc).  
  * [Wiki](https://wiki.almalinux.org/sigs/Atomic.html)  
  * Chat: [Mattermost](https://chat.almalinux.org/almalinux/channels/sigatomic) | [Matrix](https://matrix.to/#/#sig-atomic:almalinux.im)  
* **Cloud SIG:** Focused on cloud images and deployments.  
  * [Wiki](https://wiki.almalinux.org/sigs/Cloud.html)  
  * Chat: [Mattermost](https://chat.almalinux.org/almalinux/channels/sigcloud) | [Matrix](https://matrix.to/#/#sig-cloud:almalinux.im)
