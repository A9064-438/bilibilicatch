$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$base = Split-Path -Parent $MyInvocation.MyCommand.Path
$tools = Join-Path $base "tools"
$ytDlp = Join-Path $tools "yt-dlp.exe"
$ffmpeg = Join-Path $tools "ffmpeg.exe"
$appScript = Join-Path $base "app.ps1"
New-Item -ItemType Directory -Path $tools -Force | Out-Null

function Download-File([string[]]$Urls, [string]$Target) {
    $temp = "$Target.download"
    foreach ($url in $Urls) {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        Write-Host "Downloading $([IO.Path]::GetFileName($Target))..."
        & curl.exe -L --fail --connect-timeout 15 --max-time 300 --retry 1 --output $temp $url
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $temp) -and (Get-Item -LiteralPath $temp).Length -gt 1MB) {
            Move-Item -LiteralPath $temp -Destination $Target -Force
            Unblock-File -LiteralPath $Target -ErrorAction SilentlyContinue
            return
        }
    }
    throw "All download sources failed for $([IO.Path]::GetFileName($Target))."
}

try {
    $appText = [IO.File]::ReadAllText($appScript, [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText($appScript, $appText, (New-Object Text.UTF8Encoding($true)))

    if (-not (Test-Path -LiteralPath $ytDlp)) {
        Download-File @(
            "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe",
            "https://sourceforge.net/projects/yt-dlp.mirror/files/2026.07.04/yt-dlp.exe/download"
        ) $ytDlp
    }

    if (-not (Test-Path -LiteralPath $ffmpeg)) {
        Write-Host "Locating a Windows FFmpeg build..."
        $headers = @{ "User-Agent" = "BiliCatch-Windows" }
        $assets = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/imageio/imageio-binaries/contents/ffmpeg"
        $asset = $assets |
            Where-Object { $_.name -match '^ffmpeg-win-x86_64.*\.exe$' } |
            Sort-Object name -Descending |
            Select-Object -First 1
        if (-not $asset) { throw "No compatible FFmpeg build was found." }
        Download-File @($asset.download_url) $ffmpeg
    }

    & $appScript
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw "The application exited with code $LASTEXITCODE."
    }
} catch {
    $message = "下载器启动失败：`r`n`r`n$($_.Exception.Message)"
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show($message, "B站会员画质下载器", "OK", "Error") | Out-Null
    } catch { }
    exit 1
}
