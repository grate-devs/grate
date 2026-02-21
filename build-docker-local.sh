#!/bin/bash

# Build Docker image locally the same way as GitHub Actions does
# This script mimics the build-docker-image job in .github/workflows/build.yml

set -e

# Parse command line arguments
PLATFORM="linux/amd64,linux/arm64"
LOAD_IMAGE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --platform)
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
        VERSION=$(dotnet gitversion /showvariable NuGetVersionV2 2>/dev/null || echo "1.0.0-local")
    else
        echo "GitVersion not installed globally. Using default version."
        VERSION="1.0.0-local"
    fi
else
    VERSION="1.0.0-local"
fi

echo "Building Docker image with version: $VERSION"
echo "Image name: grate-devs/grate"
echo "Platform(s): $PLATFORM"
echo ""

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
    --file ./installers/docker/Dockerfile
    --platform "$PLATFORM"
    --build-arg VERSION="$VERSION"
    --tag erikbra/grate:$VERSION
    --tag erikbra/grate:latest
)

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
echo "  - erikbra/grate:$VERSION"
echo "  - erikbra/grate:latest"
echo ""
echo "To test the image:"
echo "  docker run --rm --platform $PLATFORM erikbra/grate:latest --help"
