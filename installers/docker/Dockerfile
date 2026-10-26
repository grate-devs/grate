FROM --platform=$BUILDPLATFORM mcr.microsoft.com/dotnet/sdk:10.0.403-alpine3.24@sha256:cc02b814237a76c4735fb6eeee87181597b5e56f2ce458a435e527674d91f4d7 AS build

ARG TARGETARCH
ARG TARGETFRAMEWORK=net10.0
ARG RUNTIME=linux-musl-$TARGETARCH
ARG VERSION=1.0.0
WORKDIR /app
COPY global.json *.props ./
COPY *.ruleset ./
COPY src/ ./src/
COPY docs/skills/use-grate/ ./docs/skills/use-grate/
RUN dotnet publish --framework "$TARGETFRAMEWORK" --runtime "$RUNTIME" ./src/grate/grate.csproj \
    -c release --self-contained -p:SelfContained=true /p:Version="$VERSION" /p:RuntimeIdentifiers="" \
    -o /publish

FROM alpine:3.24.3@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a AS runtime
RUN apk add --no-cache icu-libs
WORKDIR /app

COPY --chmod=0755 --from=build /publish .
COPY --chmod=0755 installers/docker/entrypoint.sh .
RUN mkdir /output
# Add globalization support to the OS so .Net can use cultures
ENV DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=false

# Expand environment variables into the response file, then run grate
ENTRYPOINT ["./entrypoint.sh"]
