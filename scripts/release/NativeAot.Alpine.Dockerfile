# Build toolchain only; released files remain standalone NativeAOT ZIPs.
# .NET 11 RC3 / Alpine 3.24, native amd64 and arm64 manifest.
FROM mcr.microsoft.com/dotnet/sdk@sha256:b2c6b82842a4f0eea6a5fff22c45dabd166bc8e639cbe1706354acb37dc52c04
RUN apk add --no-cache clang
