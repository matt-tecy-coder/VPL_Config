$ErrorActionPreference = 'Stop'
$repo = 'E:\OpenCode\VPL_Config'
$log = 'E:\OpenCode\VPL_Config\tunnel-keeper.log'
$lock = 'E:\OpenCode\VPL_Config\tunnel-keeper.lock'
$config = 'E:\OpenCode\VPL_Config\api_base_url.txt'
$tunnelLog = 'C:\Users\SUJITH\AppData\Local\Temp\opencode\vpl_tunnel.log'
$tunnelErr = 'C:\Users\SUJITH\AppData\Local\Temp\opencode\vpl_tunnel.err.log'
$cloudflared = 'C:\Program Files (x86)\cloudflared\cloudflared.exe'

function Write-Log([string]$message) {
    Add-Content -LiteralPath $log -Value ("{0} {1}" -f (Get-Date -Format 'o'), $message)
}

if (Test-Path -LiteralPath $lock) {
    $age = (Get-Date) - (Get-Item -LiteralPath $lock).LastWriteTime
    if ($age.TotalMinutes -lt 10) { exit 0 }
}
Set-Content -LiteralPath $lock -Value ([string]$PID)

try {
    $url = (Get-Content -LiteralPath $config -Raw -ErrorAction SilentlyContinue).Trim()
    $working = $false
    if ($url -match '^https://') {
        try {
            $response = Invoke-WebRequest -UseBasicParsing "$url/api/marketplace/listings" -TimeoutSec 12
            if ($response.StatusCode -eq 200 -and ($response.Content | ConvertFrom-Json).Count -gt 0) {
                $working = $true
            }
        } catch {
            Write-Log "Check failed: $($_.Exception.Message)"
        }
    }
    if ($working) {
        Write-Log "OK $url"
        exit 0
    }

    Write-Log 'Refreshing tunnel'
    Get-Process cloudflared -ErrorAction SilentlyContinue | Stop-Process -Force
    Remove-Item -LiteralPath $tunnelLog, $tunnelErr -Force -ErrorAction SilentlyContinue
    Start-Process -FilePath $cloudflared -ArgumentList @('tunnel', '--url', 'http://127.0.0.1:5080', '--protocol', 'http2', '--no-autoupdate') -RedirectStandardOutput $tunnelLog -RedirectStandardError $tunnelErr -WindowStyle Hidden

    $newUrl = $null
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 1
        foreach ($file in @($tunnelLog, $tunnelErr)) {
            if (Test-Path -LiteralPath $file) {
                $match = Select-String -Path $file -Pattern 'https://[a-z0-9-]+\.trycloudflare\.com' -AllMatches | Select-Object -First 1
                if ($match) {
                    $newUrl = $match.Matches[0].Value
                    break
                }
            }
        }
        if ($newUrl) { break }
    }
    if (-not $newUrl) { throw 'Tunnel URL was not created' }

    $serving = $false
    for ($i = 0; $i -lt 15; $i++) {
        try {
            $response = Invoke-WebRequest -UseBasicParsing "$newUrl/api/marketplace/listings" -TimeoutSec 20
            if ($response.StatusCode -eq 200 -and ($response.Content | ConvertFrom-Json).Count -gt 0) {
                $serving = $true
                break
            }
        } catch {
            Start-Sleep -Seconds 3
        }
    }
    if (-not $serving) { throw "Tunnel $newUrl is not serving the API" }

    Set-Content -LiteralPath $config -Value $newUrl -NoNewline
    git -C $repo add api_base_url.txt
    $staged = git -C $repo diff --cached --name-only
    if ($staged) {
        git -C $repo -c user.name='Matt Tecy' -c user.email='matt-tecy-coder@users.noreply.github.com' commit -m 'Update API tunnel URL' | Out-Null
        git -C $repo push origin main | Out-Null
    }
    Write-Log "Updated $newUrl"
} catch {
    Write-Log "ERROR $($_.Exception.Message)"
} finally {
    Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
}
