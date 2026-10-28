FROM --platform=$BUILDPLATFORM mcr.microsoft.com/dotnet/sdk:10.0-alpine AS build

ARG TARGETARCH
ARG TARGETFRAMEWORK=net10.0
ARG RUNTIME
ARG VERSION=1.0.0
WORKDIR /app
COPY global.json *.props ./
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
    -c release --self-contained -p:SelfContained=true /p:Version="$VERSION" /p:RuntimeIdentifiers="" \
    -o /publish

FROM alpine:3 AS runtime
RUN apk add --no-cache icu-libs
WORKDIR /app

COPY --chmod=0755 --from=build /publish .
COPY --chmod=0755 installers/docker/entrypoint.sh .
RUN mkdir /output
# Add globalization support to the OS so .Net can use cultures
ENV DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=false

# Expand environment variables into the response file, then run grate
ENTRYPOINT ["./entrypoint.sh"]
