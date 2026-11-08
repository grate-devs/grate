# Provision native libraries before the offline install/migration checks.
# No SDK, shared .NET runtime, PowerShell or development NuGet cache is installed.
ARG UBUNTU_IMAGE=ubuntu:26.04
FROM ${UBUNTU_IMAGE}
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       ca-certificates libbrotli1 libgcc-s1 libgssapi-krb5-2 libicu78 liblttng-ust1t64 libssl3t64 \
       libstdc++6 zlib1g binutils file \
    && rm -rf /var/lib/apt/lists/*
# Ubuntu's minimal Docker image excludes doc/man files during dpkg installation.
# Retain the candidate package's notices and manual so these checks exercise them.
RUN rm -f /etc/dpkg/dpkg.cfg.d/excludes
CMD ["sleep", "infinity"]
