---
title: "Alpine Linux Support"
permalink: /alpine-linux-support/
nav_order: 10
---

# Alpine Linux Support

## Overview

Alpine Linux users can use grate through multiple distribution methods without needing a dedicated Alpine package (.apk).

## Available Options for Alpine Linux Users

### 1. Docker Image (Recommended)

The official grate Docker image is built on Alpine Linux and is the recommended approach for Alpine users:

```sh
docker pull erikbra/grate:latest
```

The Docker image:
- Uses Alpine 3 as the base image
- Includes all necessary dependencies (icu-libs for globalization)
- Supports multiple architectures (amd64, arm64)
- Is published to Docker Hub on every release

See the [Getting Grate](/getting-grate/) documentation for Docker usage examples.

### 2. Standalone linux-musl Binaries

Pre-built binaries for linux-musl (Alpine's libc implementation) are available for download from the [releases page](https://github.com/grate-devs/grate/releases/latest):

- `grate-linux-musl-x64-self-contained-{version}.zip` - For x86_64/amd64 systems
- `grate-linux-musl-arm64-self-contained-{version}.zip` - For ARM64 systems

These self-contained binaries work on Alpine Linux without requiring .NET runtime installation.

**Installation:**

```sh
# Download the appropriate binary (replace {version} with actual version like 2.0.5)
wget https://github.com/grate-devs/grate/releases/download/{version}/grate-linux-musl-x64-self-contained-{version}.zip

# Or use latest release
wget https://github.com/grate-devs/grate/releases/latest/download/grate-linux-musl-x64-self-contained-{version}.zip

# Extract to a directory
unzip grate-linux-musl-x64-self-contained-{version}.zip -d grate-bin

# Install to system path
sudo cp grate-bin/grate /usr/local/bin/
sudo chmod +x /usr/local/bin/grate
```

### 3. Build from Source

For Alpine users who prefer to build from source:

```sh
# Install .NET SDK
apk add dotnet-sdk icu-libs

# Clone and build
git clone https://github.com/grate-devs/grate.git
cd grate
dotnet build -c Release
```

## Why Not Create an Alpine Package (.apk)?

While Alpine packages provide native integration with Alpine's package manager (`apk`), creating and maintaining one is not currently prioritized because:

1. **Docker Coverage**: The Docker image already provides excellent Alpine support and is the most common use case for Alpine users
2. **Binary Availability**: Self-contained linux-musl binaries work on Alpine without modification
3. **Maintenance Overhead**: Alpine packages require:
   - Creating and maintaining APKBUILD files
   - Submitting to and maintaining packages in Alpine's repository infrastructure
   - Following Alpine's packaging guidelines and policies
   - Regular updates synchronized with Alpine's release cycle
4. **Limited Use Case**: Most Alpine Linux usage is in containerized environments where Docker is the preferred distribution method
5. **Other Priorities**: The project already supports 7+ distribution methods (Docker, .NET tool, Winget, Homebrew, Chocolatey, .deb, MSI)

## Community Contributions

If there is significant demand for a native Alpine package, community contributions are welcome. The package would need to:

- Follow [Alpine package creation guidelines](https://wiki.alpinelinux.org/wiki/Creating_an_Alpine_package)
- Include proper APKBUILD files
- Be maintained in sync with grate releases
- Potentially be submitted to the Alpine package repository

Please open a discussion on the [GitHub repository](https://github.com/grate-devs/grate) if you're interested in contributing this.

## Summary

Alpine Linux users are well-supported through:
- ✅ Official Docker image (Alpine-based)
- ✅ linux-musl standalone binaries
- ✅ Source code compilation

A dedicated Alpine .apk package is not currently planned but community contributions would be considered.
