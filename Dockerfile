FROM mcr.microsoft.com/powershell:latest
WORKDIR /app
COPY . .
CMD ["pwsh", "-NoLogo", "-NoProfile", "-File", "./server.ps1"]
