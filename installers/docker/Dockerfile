FROM --platform=$BUILDPLATFORM mcr.microsoft.com/dotnet/sdk:11.0.100-alpine3.24@sha256:52556c0fb9d0f609ae9aeab9efeeba96f4acc2f7038f7696f2235ccbdbb8e290 AS build

ARG TARGETARCH
ARG TARGETFRAMEWORK=net11.0
ARG RUNTIME_VERSION=11.0.0
ARG RUNTIME
ARG VERSION=1.0.0
ARG GRATE_DISTRIBUTION=All
WORKDIR /app
COPY global.json NuGet.Config *.props ./
COPY *.ruleset ./
COPY src/ ./src/
COPY docs/skills/use-grate/ ./docs/skills/use-grate/
RUN if [ -z "$RUNTIME" ]; then \
      case "$TARGETARCH" in \
        amd64) RUNTIME=linux-musl-x64 ;; \
        arm64) RUNTIME=linux-musl-arm64 ;; \
        *) echo "Unsupported target architecture: $TARGETARCH" >&2; exit 1 ;; \
      esac; \
    fi; \
    dotnet publish --framework "$TARGETFRAMEWORK" --runtime "$RUNTIME" ./src/grate/grate.csproj \
    -c release --self-contained -p:SelfContained=true -p:TargetFrameworks="$TARGETFRAMEWORK" \
    -p:RuntimeFrameworkVersion="$RUNTIME_VERSION" -p:GrateDistribution="$GRATE_DISTRIBUTION" \
    /p:Version="$VERSION" /p:RuntimeIdentifiers="" \
    -o /publish

FROM mcr.microsoft.com/dotnet/runtime-deps:11.0.0-alpine3.24@sha256:5597d4a0c9ea3fb84fc210333013d761fc350d5925fc9042f62992675e15b58b AS runtime
RUN apk add --no-cache icu-libs
WORKDIR /app

COPY --chmod=0755 --from=build /publish .
COPY --chmod=0755 installers/docker/entrypoint.sh .
RUN mkdir /output
# Add globalization support to the OS so .Net can use cultures
ENV DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=false

# Expand environment variables into the response file, then run grate
ENTRYPOINT ["./entrypoint.sh"]
