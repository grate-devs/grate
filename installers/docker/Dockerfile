FROM --platform=$BUILDPLATFORM mcr.microsoft.com/dotnet/sdk:11.0.100-rc.3-alpine3.24@sha256:f2542b156e7c9eda7783e4a5745efa6c133a162a1940fd4175849aa80fccfd23 AS build

ARG TARGETARCH
ARG TARGETFRAMEWORK=net11.0
ARG RUNTIME_VERSION=11.0.0-rc.3.26522.148
ARG RUNTIME
ARG VERSION=1.0.0
WORKDIR /app
COPY global.json *.props ./
COPY *.ruleset ./
COPY src/ ./src/
COPY docs/skills/use-grate/ ./docs/skills/use-grate/
RUN case "$TARGETARCH" in \
      amd64) runtime=linux-musl-x64 ;; \
      arm64) runtime=linux-musl-arm64 ;; \
      *) echo "Unsupported container architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac && \
    dotnet publish --framework "$TARGETFRAMEWORK" --runtime "${RUNTIME:-$runtime}" ./src/grate/grate.csproj \
    -c release --self-contained -p:SelfContained=true -p:TargetFrameworks="$TARGETFRAMEWORK" \
    -p:RuntimeFrameworkVersion="$RUNTIME_VERSION" /p:Version="$VERSION" /p:RuntimeIdentifiers="" \
    -o /publish

FROM mcr.microsoft.com/dotnet/runtime-deps:11.0.0-rc.3-alpine3.24@sha256:f4d3801cac2204e2f961a931dd67a99975a436a8b5ad055898bc7029b712d44d AS runtime
RUN apk add --no-cache icu-libs
WORKDIR /app

COPY --chmod=0755 --from=build /publish .
COPY --chmod=0755 installers/docker/entrypoint.sh .
RUN mkdir /output
# Add globalization support to the OS so .Net can use cultures
ENV DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=false

# Expand environment variables into the response file, then run grate
ENTRYPOINT ["./entrypoint.sh"]
