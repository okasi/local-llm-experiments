<#
Generates a self-signed TLS cert/key pair for Serve-Qwen-AEON.ps1 -Tls, covering
localhost, 127.0.0.1, and every private IPv4 address currently on this machine.

Clients will see a trust warning (browsers) or need -k/--insecure (curl) since
nothing signed this cert but itself -- that's expected for a self-hosted box. It
still encrypts the connection, which is what actually matters once the API key is
travelling over the open internet instead of localhost/LAN.

Re-run this if your LAN/public IP changes and you want it covered by the cert's
SAN list; the old cert keeps working for whatever IPs it already has, this just
regenerates it with the current set.
#>
$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot
$TlsDir = Join-Path $Root "tls"
New-Item -ItemType Directory -Force -Path $TlsDir | Out-Null
$Key = Join-Path $TlsDir "server.key"
$Cert = Join-Path $TlsDir "server.crt"

if (-not (Get-Command openssl -ErrorAction SilentlyContinue)) {
    throw "openssl not found on PATH. It ships with Git for Windows (C:\Program Files\Git\mingw64\bin) -- install Git for Windows, or point PATH at another openssl build."
}

$ips = @("127.0.0.1") + (
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" -and $_.AddressState -eq "Preferred" } |
        Select-Object -ExpandProperty IPAddress
) | Select-Object -Unique
$san = "DNS:localhost," + (($ips | ForEach-Object { "IP:$_" }) -join ",")

Write-Host "Generating self-signed cert for: $san"
$env:MSYS_NO_PATHCONV = "1"
& openssl req -x509 -newkey rsa:2048 -nodes `
    -keyout $Key -out $Cert -days 365 `
    -subj "/CN=qwen-aeon-server" `
    -addext "subjectAltName=$san" 2>&1 | Out-Null
Remove-Item Env:MSYS_NO_PATHCONV -ErrorAction SilentlyContinue

if (-not (Test-Path -LiteralPath $Cert) -or -not (Test-Path -LiteralPath $Key)) {
    throw "Cert generation failed -- check that openssl ran without errors above."
}
Write-Host "Wrote $Cert and $Key"
Write-Host "Run Serve-Qwen-AEON.ps1 -Tls to use it."
