# AlmaLinux Bootable Container Base Images (bootc)

**<ins>Caution</ins>: AlmaLinux bootc images are currently *experimental*. Please use with care and report any issues.**

## Available Pre-built Images

Official pre-built experimental images are available on Quay.io:

* **[quay.io/almalinuxorg/almalinux-bootc](https://quay.io/repository/almalinuxorg/almalinux-bootc?tab=tags)**

This project provides tooling to build experimental AlmaLinux bootable container images. These images leverage the [bootc project](https://containers.github.io/bootc/), which enables the creation of bootable OS images from container images.

Our images are based on the work done for [CentOS Bootc Base Images](https://gitlab.com/redhat/centos-stream/containers/bootc/-/tree/c10s?ref_type=heads) and utilize [bootc-base-imagectl](https://gitlab.com/fedora/bootc/base-images/-/blob/main/bootc-base-imagectl.md?ref_type=heads) for their construction.

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
