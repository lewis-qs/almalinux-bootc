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
| kernel | `5.14.0-687.39.1` | `6.12.0-211.47.1` | `6.12.0-250` |
| bootc | `1.13.0-1` | `1.15.2-1` | `1.16.2-1` |
| systemd | `252-67` | `257-23` | `257-30` |
| podman | `5.8.2-5` | `5.8.2-5` | `6.0.1-1` |
| dnf | `4.14.0-34` | `4.20.0-22` | `4.20.0-26` |
| ostree | `2025.7-1` | `2025.7-1` | `2026.2-1` |
| NetworkManager | `1.54.3-4` | `1.56.0-2` | `1.58~rc1-1` |
| glibc | `2.34-275` | `2.39-128` | `2.39-130` |
| openssl | `3.5.5-6` | `3.5.5-6` | `3.5.7-2` |
| selinux-policy | `38.1.75-2` | `42.1.18-4` | `42.1.25-1` |

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

### Building install media and VMs locally

The published images are the source of truth — you can turn any of them into an
installer ISO or a bootable disk image on your own machine. The recipes take
`<variant> <major>` (variant omitted builds the base):

```bash
just pull-image workstation 10-kitten   # pull ghcr.io/lewis-qs/bootc/almalinux:10-kitten-workstation
just build-iso  workstation 10-kitten   # -> output/bootiso/install.iso  (anaconda, via bootc-image-builder)
just build-vm   workstation 10-kitten   # -> output/disk.raw             (bootc install to-disk)
```

`build-iso` and `build-vm` verify the image's signature against `cosign.pub`
before building. The `build-*` recipes need a Linux host (`build-vm` runs
`bootc install to-disk` against the host's loop devices, and podman is invoked
with `sudo`); the `run-*` recipes work on Linux and macOS. Boot the result in
qemu (UEFI, with KVM on Linux and HVF on macOS):

```bash
just run-iso    # boots output/bootiso/install.iso
just run-vm     # boots output/disk.raw
```

Extra prerequisites: `bootc-image-builder` (pulled automatically) for `build-iso`,
and for the `run-*` recipes `qemu` plus UEFI firmware — `brew install qemu` on
macOS, `edk2-ovmf`/`qemu-system-*` on Linux. The recipes find the firmware for
your platform automatically; override with `OVMF_CODE=` if yours differs. The
guest architecture follows `PLATFORM` (override with `VM_ARCH=`), and qemu drops
to TCG emulation when it doesn't match the host. Run `just --list` for the full
recipe set.

## Contributing and Community

We welcome contributions and feedback!  
Join the discussion and get involved with the relevant AlmaLinux Special Interest Groups (SIGs):

* **Atomic SIG:** Focused on atomic updates and related tooling (like bootc).  
  * [Wiki](https://wiki.almalinux.org/sigs/Atomic.html)  
  * Chat: [Mattermost](https://chat.almalinux.org/almalinux/channels/sigatomic) | [Matrix](https://matrix.to/#/#sig-atomic:almalinux.im)  
* **Cloud SIG:** Focused on cloud images and deployments.  
  * [Wiki](https://wiki.almalinux.org/sigs/Cloud.html)  
  * Chat: [Mattermost](https://chat.almalinux.org/almalinux/channels/sigcloud) | [Matrix](https://matrix.to/#/#sig-cloud:almalinux.im)
