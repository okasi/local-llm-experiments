param(
    [int]$DurationSeconds = 60,
    [int]$IntervalSeconds = 2,
    [string]$OutCsv = ""
)
$samples = @()
$end = (Get-Date).AddSeconds($DurationSeconds)
while ((Get-Date) -lt $end) {
    $line = & nvidia-smi --query-gpu=memory.used,utilization.gpu --format=csv,noheader,nounits
    $parts = $line -split ",\s*"
    $samples += [pscustomobject]@{ time = (Get-Date -Format "HH:mm:ss"); mem_mb = [int]$parts[0]; util_pct = [int]$parts[1] }
    Start-Sleep -Seconds $IntervalSeconds
}
$maxMem = ($samples | Measure-Object -Property mem_mb -Maximum).Maximum
$avgMem = ($samples | Measure-Object -Property mem_mb -Average).Average
Write-Host "Peak VRAM: ${maxMem}MB | Avg VRAM: $([math]::Round($avgMem))MB | samples: $($samples.Count)"
if ($OutCsv) { $samples | Export-Csv -Path $OutCsv -NoTypeInformation }
