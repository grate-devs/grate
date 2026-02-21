FROM mcr.microsoft.com/dotnet/sdk:10.0-alpine AS build
WORKDIR .

COPY sample-service/ ./sample-service/
RUN dotnet publish ./sample-service/*.csproj -c release -o ./publish/app

FROM mcr.microsoft.com/dotnet/aspnet:10.0-alpine AS runtime
WORKDIR /app

COPY --from=build /publish/app .
COPY sql/ /db

# Add globalization support to the OS so .Net can use cultures
RUN apk add icu-libs
ENV DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=false
ENV ASPNETCORE_URLS=http://[::]:80
ENV ASPNETCORE_ENVIRONMENT=Production

ENTRYPOINT ["dotnet", "sample-service.dll"]