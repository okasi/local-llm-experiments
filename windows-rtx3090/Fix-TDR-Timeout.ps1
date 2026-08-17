<#
Raises the Windows TDR (Timeout Detection and Recovery) timeout for the GPU driver.

Why: WDDM resets the GPU driver if a single GPU operation runs longer than the
default 2-second timeout without yielding. On an RTX 3090 this killed the
llama-server CUDA context mid-benchmark (VRAM usage collapsed to near-zero, the
GPU briefly vanished from Windows' device list) -- triggered by concurrent
requests hitting a single-slot server (-np 1), not by deep context itself.

This must be run as Administrator, and a reboot is required afterward for the new
TdrDelay to take effect.

Usage:
  Right-click PowerShell -> Run as Administrator, then:
  .\Fix-TDR-Timeout.ps1
#>

$ErrorActionPreference = "Stop"

$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script from an elevated (Administrator) PowerShell window."
}

$path = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"

# TdrDelay: seconds the GPU may run a single operation before Windows resets the
# driver (default: 2). 10 gives long prefill/attention passes enough room without
# disabling the safety net entirely.
New-ItemProperty -Path $path -Name "TdrDelay" -PropertyType DWord -Value 10 -Force | Out-Null

# TdrLevel: 3 = recover on timeout (default Windows behavior; a genuinely hung GPU
# still gets recovered, just with more headroom before that kicks in). 0 would
# disable detection entirely -- not used here on purpose.
New-ItemProperty -Path $path -Name "TdrLevel" -PropertyType DWord -Value 3 -Force | Out-Null

Write-Host "TdrDelay set to 10s, TdrLevel set to 3 (recover on timeout)."
Write-Host "Reboot for this to take effect."
