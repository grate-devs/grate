# Provision inputs with networking, before the isolated source build. Only the
# official Ubuntu archive is configured by this base image. Pin the resolved
# image digest and record dpkg-query output alongside each build's evidence.
ARG UBUNTU_IMAGE=ubuntu:26.04
FROM ${UBUNTU_IMAGE}
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       ca-certificates debhelper dotnet-sdk-10.0 \
       dotnet-sdk-10.0-source-built-artifacts fakeroot \
    && rm -rf /var/lib/apt/lists/*
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /work
