#!/bin/bash

# Build Docker image locally the same way as GitHub Actions does
# This script mimics the build-docker-image job in .github/workflows/build.yml

set -euo pipefail

# Resolve repository paths even when invoked from another working directory.
cd "$(dirname "${BASH_SOURCE[0]}")"

# Parse command line arguments
PLATFORM="linux/amd64,linux/arm64"
LOAD_IMAGE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --platform)
            [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { echo "--platform requires a value" >&2; exit 1; }
            PLATFORM="$2"
            LOAD_IMAGE=true
            shift 2
            ;;
        --amd64)
            PLATFORM="linux/amd64"
            LOAD_IMAGE=true
            shift
            ;;
        --arm64)
            PLATFORM="linux/arm64"
            LOAD_IMAGE=true
            shift
            ;;
        --load)
            LOAD_IMAGE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--platform linux/amd64|linux/arm64] [--amd64] [--arm64] [--load]"
            exit 1
            ;;
    esac
done

# Get version from GitVersion if available, otherwise use a default
if command -v dotnet &> /dev/null; then
    echo "Attempting to get version using GitVersion..."
    if dotnet tool list -g | grep -q gitversion.tool; then
        VERSION=$(dotnet gitversion /showvariable SemVer 2>/dev/null || echo "1.0.0-local")
    else
        echo "GitVersion not installed globally. Using default version."
        VERSION="1.0.0-local"
    fi
else
    VERSION="1.0.0-local"
fi

echo "Building Docker image with version: $VERSION"
echo "Image name: gratedevs/grate"
echo "Platform(s): $PLATFORM"
echo ""

if [[ "$LOAD_IMAGE" = true && "$PLATFORM" == *,* ]]; then
    echo "--load requires a single platform; use --amd64 or --arm64." >&2
    exit 1
fi

# Use the same version/tag policy as release automation, without publishing.
TAGS=$(python3 installers/docker/release_tags.py "$VERSION")

# Create a builder instance if it doesn't exist
if ! docker buildx ls | grep -q "multiarch-builder"; then
    echo "Creating multiarch-builder..."
    docker buildx create --name multiarch-builder --use
else
    echo "Using existing multiarch-builder..."
    docker buildx use multiarch-builder
fi

# Build arguments
BUILD_ARGS=(
    --pull
    --file ./installers/docker/Dockerfile
    --platform "$PLATFORM"
    --build-arg VERSION="$VERSION"
)

while IFS= read -r tag; do
    BUILD_ARGS+=(--tag "$tag")
done <<< "$TAGS"

# Add --load if single platform or explicitly requested
if [ "$LOAD_IMAGE" = true ]; then
    BUILD_ARGS+=(--load)
    echo "Loading image into Docker (single platform only)"
else
    echo "Building multi-platform (not loading into Docker)"
fi

# Build for specified platform(s)
docker buildx build "${BUILD_ARGS[@]}" .

echo ""
echo "Build completed successfully!"
echo "Image tags:"
while IFS= read -r tag; do
    printf '  - %s\n' "$tag"
done <<< "$TAGS"
echo ""
echo "To test the image:"
if [[ "$LOAD_IMAGE" = true ]]; then
    FIRST_TAG=${TAGS%%$'\n'*}
    echo "  docker run --rm --platform $PLATFORM --entrypoint ./grate $FIRST_TAG --help"
else
    echo "Rebuild with --amd64 or --arm64 to load and run the image locally."
fi
