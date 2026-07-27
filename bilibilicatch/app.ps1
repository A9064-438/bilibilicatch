Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ("BiliCatchProcessRunner" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;

public sealed class BiliCatchProcessRunner : IDisposable
{
    private readonly ConcurrentQueue<string> lines = new ConcurrentQueue<string>();
    private Process process;

    public void Start(string fileName, string arguments)
    {
        process = new Process();
        process.StartInfo.FileName = fileName;
        process.StartInfo.Arguments = arguments;
        process.StartInfo.UseShellExecute = false;
        process.StartInfo.CreateNoWindow = true;
        process.StartInfo.RedirectStandardOutput = true;
        process.StartInfo.RedirectStandardError = true;
        process.StartInfo.StandardOutputEncoding = Encoding.UTF8;
        process.StartInfo.StandardErrorEncoding = Encoding.UTF8;
        process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs args) {
            if (args.Data != null) lines.Enqueue(args.Data);
        };
        process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs args) {
            if (args.Data != null) lines.Enqueue(args.Data);
        };
        process.Start();
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
    }

    public string Drain()
    {
        StringBuilder output = new StringBuilder();
        string line;
        while (lines.TryDequeue(out line)) output.AppendLine(line);
        return output.ToString();
    }

    public bool HasExited
    {
        get {
            try { return process != null && process.HasExited; }
            catch { return true; }
        }
    }

    public int Id { get { return process.Id; } }

    public int Complete()
    {
        process.WaitForExit();
        return process.ExitCode;
    }

    public void Dispose()
    {
        if (process != null) process.Dispose();
    }
}
"@
}

[System.Windows.Forms.Application]::EnableVisualStyles()
$ErrorActionPreference = "Stop"

$script:base = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ytDlp = Join-Path $script:base "tools\yt-dlp.exe"
$script:ffmpeg = Join-Path $script:base "tools\ffmpeg.exe"
$script:configFile = Join-Path $script:base "config.json"
$script:defaultCookieFile = Join-Path (Join-Path $env:USERPROFILE "Downloads") "bilibili-cookies.txt"
$script:cookieExtensionUrl = "https://chromewebstore.google.com/detail/get-cookiestxt-locally/cclelndahbckbenkjhflpdbgdldlbecc"
$script:formatMap = @{}
$script:downloadRunner = $null
$script:userCancelled = $false

function Quote-Argument([string]$Value) {
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Get-CookieArguments {
    if ($radioFile.Checked) { return @("--cookies", $cookieBox.Text.Trim()) }
    return @()
}

function Invoke-YtDlp([string[]]$Arguments) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $script:ytDlp
    $info.Arguments = (($Arguments | ForEach-Object { Quote-Argument $_ }) -join " ")
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return [pscustomobject]@{ ExitCode = $process.ExitCode; StdOut = $stdout; StdErr = $stderr }
}

function Add-Log([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    $logBox.AppendText($Text.TrimEnd() + [Environment]::NewLine)
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.ScrollToCaret()
}

function Set-Busy([bool]$Busy, [string]$Status, [bool]$Downloading = $false) {
    $statusLabel.Text = $Status
    $fetchButton.Enabled = -not $Busy
    $downloadButton.Enabled = -not $Busy
    $cancelButton.Enabled = $Downloading
    $form.UseWaitCursor = $Busy -and -not $Downloading
}

function Show-FriendlyError([string]$Text) {
    $message = $Text.Trim()
    $lower = $message.ToLowerInvariant()
    if ($lower.Contains("could not copy chrome cookie database") -or $lower.Contains("database is locked")) {
        $message = '新版 Edge 不允许稳定读取 Cookie 数据库。请使用“Get cookies.txt LOCALLY”扩展主动导出 Cookie。'
    } elseif ($lower.Contains("failed to decrypt") -or ($lower.Contains("cookie") -and $lower.Contains("decrypt"))) {
        $message = '新版 Edge 使用应用绑定加密，无法由下载器直接解密。请使用“Get cookies.txt LOCALLY”扩展主动导出 Cookie。'
    } elseif ($lower.Contains("unsupported url")) {
        $message = "该网址不是 yt-dlp 可识别的 B 站视频页面。"
    }
    Add-Log ("错误：" + $message)
    [System.Windows.Forms.MessageBox]::Show($form, $message, "B站会员画质下载器", "OK", "Error") | Out-Null
}

function Test-Inputs([bool]$NeedQuality = $false) {
    $url = $urlBox.Text.Trim()
    if ($url -notmatch '^https?://(?:[^/]+\.)?(?:bilibili\.com|b23\.tv)/') {
        [System.Windows.Forms.MessageBox]::Show($form, "请输入有效的 B 站或 b23.tv 视频网址。", "提示", "OK", "Warning") | Out-Null
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($outputBox.Text)) {
        [System.Windows.Forms.MessageBox]::Show($form, "请选择保存目录。", "提示", "OK", "Warning") | Out-Null
        return $false
    }
    if ($radioFile.Checked -and -not (Test-Path -LiteralPath $cookieBox.Text.Trim() -PathType Leaf)) {
        [System.Windows.Forms.MessageBox]::Show($form, "未找到 Cookie 文件。请先安装 Get cookies.txt LOCALLY，在 B 站页面导出后选择生成的 cookies.txt。", "提示", "OK", "Warning") | Out-Null
        return $false
    }
    if ($radioFile.Checked) {
        $cookieText = Get-Content -LiteralPath $cookieBox.Text.Trim() -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($cookieText -notmatch '(?m)\tSESSDATA\t') {
            [System.Windows.Forms.MessageBox]::Show($form, "Cookie 文件中没有检测到 SESSDATA。请确认在当前 Edge 配置中登录 B 站后重新导出。", "登录状态无效", "OK", "Warning") | Out-Null
            return $false
        }
    }
    if ($NeedQuality -and (-not $script:formatMap.ContainsKey($qualityBox.Text))) {
        [System.Windows.Forms.MessageBox]::Show($form, "请先获取并选择画质。", "提示", "OK", "Warning") | Out-Null
        return $false
    }
    try { New-Item -ItemType Directory -Path $outputBox.Text.Trim() -Force | Out-Null } catch {
        [System.Windows.Forms.MessageBox]::Show($form, "无法创建保存目录：`r`n$($_.Exception.Message)", "错误", "OK", "Error") | Out-Null
        return $false
    }
    return $true
}

function Get-HumanSize($Value) {
    if (-not $Value) { return "" }
    $size = [double]$Value
    foreach ($unit in @("B", "KB", "MB", "GB", "TB")) {
        if ($size -lt 1024 -or $unit -eq "TB") { return ("{0:N1}{1}" -f $size, $unit) }
        $size /= 1024
    }
}

function Get-CodecName([string]$Value) {
    if ($Value -match '^(av01|av1)') { return "AV1" }
    if ($Value -match '^(hev|hvc)') { return "HEVC" }
    if ($Value -match '^(avc|h264)') { return "AVC" }
    if ($Value) { return $Value.Split('.')[0].ToUpperInvariant() }
    return "未知编码"
}

function Set-PreferredQualitySelection {
    if ($qualityBox.Items.Count -eq 0) { return }
    $preference = $defaultQualityBox.Text
    $codecPattern = switch -Regex ($defaultCodecBox.Text) {
        '^AVC'  { '\bAVC\b'; break }
        '^HEVC' { '\bHEVC\b'; break }
        '^AV1'  { '\bAV1\b'; break }
        default { $null; break }
    }

    if ($preference -eq "最高可用画质") {
        if (-not $codecPattern) {
            $qualityBox.SelectedIndex = 0
            return
        }
        for ($index = 1; $index -lt $qualityBox.Items.Count; $index++) {
            if ([string]$qualityBox.Items[$index] -match $codecPattern) {
                $qualityBox.SelectedIndex = $index
                return
            }
        }
        $qualityBox.SelectedIndex = 0
        return
    }

    $resolutionPattern = switch -Regex ($preference) {
        '^2160p' { '(2160|4K)'; break }
        '^1440p' { '1440'; break }
        '^1080p' { '1080'; break }
        '^720p'  { '720'; break }
        default  { '1080'; break }
    }
    $needs60Fps = $preference -match '60fps'
    $searchModes = @(
        @{ RequireFps = $needs60Fps; RequireCodec = $true },
        @{ RequireFps = $false; RequireCodec = $true },
        @{ RequireFps = $needs60Fps; RequireCodec = $false },
        @{ RequireFps = $false; RequireCodec = $false }
    )
    foreach ($mode in $searchModes) {
        for ($index = 1; $index -lt $qualityBox.Items.Count; $index++) {
            $label = [string]$qualityBox.Items[$index]
            $fpsMatches = -not $mode.RequireFps -or $label -match '(60|59\.94)fps'
            $codecMatches = -not $mode.RequireCodec -or -not $codecPattern -or $label -match $codecPattern
            if ($label -match $resolutionPattern -and $fpsMatches -and $codecMatches) {
                $qualityBox.SelectedIndex = $index
                return
            }
        }
    }
    $qualityBox.SelectedIndex = 0
}

function Save-Config {
    $data = @{
        output = $outputBox.Text
        cookieMode = $(if ($radioEdge.Checked) { "edge" } elseif ($radioFile.Checked) { "file" } else { "none" })
        cookieFile = $cookieBox.Text
        defaultQuality = $defaultQualityBox.Text
        defaultCodec = $defaultCodecBox.Text
    }
    $data | ConvertTo-Json | Set-Content -LiteralPath $script:configFile -Encoding UTF8
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "B站会员画质下载器"
$form.ClientSize = New-Object System.Drawing.Size(850, 775)
$form.MinimumSize = New-Object System.Drawing.Size(780, 735)
$form.StartPosition = "CenterScreen"
$form.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
$form.BackColor = [System.Drawing.Color]::FromArgb(247, 249, 252)

$title = New-Object System.Windows.Forms.Label
$title.Text = "B站会员画质下载器"
$title.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 18, [Drawing.FontStyle]::Bold)
$title.Location = New-Object Drawing.Point(24, 18)
$title.AutoSize = $true
$form.Controls.Add($title)

$authorLabel = New-Object Windows.Forms.Label
$authorLabel.Text = "蘑菇 2026-07-27"
$authorLabel.Font = New-Object Drawing.Font("Microsoft YaHei UI", 10, [Drawing.FontStyle]::Bold)
$authorLabel.ForeColor = [Drawing.Color]::DimGray
$authorLabel.Location = New-Object Drawing.Point(690, 25)
$authorLabel.Size = New-Object Drawing.Size(136, 25)
$authorLabel.TextAlign = "MiddleRight"
$authorLabel.Anchor = "Top,Right"
$form.Controls.Add($authorLabel)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = "读取 Edge 大会员登录态，动态选择真实可用画质，并合并输出 MP4。"
$subtitle.ForeColor = [Drawing.Color]::DimGray
$subtitle.Location = New-Object Drawing.Point(27, 58)
$subtitle.AutoSize = $true
$form.Controls.Add($subtitle)

$sourceGroup = New-Object Windows.Forms.GroupBox
$sourceGroup.Text = "1. 视频来源"
$sourceGroup.Location = New-Object Drawing.Point(24, 88)
$sourceGroup.Size = New-Object Drawing.Size(802, 100)
$sourceGroup.Anchor = "Top,Left,Right"
$form.Controls.Add($sourceGroup)

$urlBox = New-Object Windows.Forms.TextBox
$urlBox.Location = New-Object Drawing.Point(16, 27)
$urlBox.Size = New-Object Drawing.Size(540, 27)
$urlBox.Anchor = "Top,Left,Right"
$sourceGroup.Controls.Add($urlBox)

$pasteButton = New-Object Windows.Forms.Button
$pasteButton.Text = "粘贴"
$pasteButton.Location = New-Object Drawing.Point(566, 25)
$pasteButton.Size = New-Object Drawing.Size(80, 30)
$pasteButton.Anchor = "Top,Right"
$sourceGroup.Controls.Add($pasteButton)

$edgeUrlButton = New-Object Windows.Forms.Button
$edgeUrlButton.Text = "读取 Edge 当前页"
$edgeUrlButton.Location = New-Object Drawing.Point(654, 25)
$edgeUrlButton.Size = New-Object Drawing.Size(132, 30)
$edgeUrlButton.Anchor = "Top,Right"
$sourceGroup.Controls.Add($edgeUrlButton)

$sourceHint = New-Object Windows.Forms.Label
$sourceHint.Text = '先在 Edge 打开视频页，再回到本程序点击“读取 Edge 当前页”；也可以直接粘贴网址。'
$sourceHint.ForeColor = [Drawing.Color]::DimGray
$sourceHint.Location = New-Object Drawing.Point(16, 66)
$sourceHint.AutoSize = $true
$sourceGroup.Controls.Add($sourceHint)

$loginGroup = New-Object Windows.Forms.GroupBox
$loginGroup.Text = "2. 登录状态"
$loginGroup.Location = New-Object Drawing.Point(24, 198)
$loginGroup.Size = New-Object Drawing.Size(802, 105)
$loginGroup.Anchor = "Top,Left,Right"
$form.Controls.Add($loginGroup)

$radioEdge = New-Object Windows.Forms.RadioButton
$radioEdge.Text = "直接读取 Edge（新版不可用）"
$radioEdge.Location = New-Object Drawing.Point(16, 25)
$radioEdge.Size = New-Object Drawing.Size(230, 25)
$radioEdge.Enabled = $false
$loginGroup.Controls.Add($radioEdge)

$radioNone = New-Object Windows.Forms.RadioButton
$radioNone.Text = "不使用登录态"
$radioNone.Location = New-Object Drawing.Point(258, 25)
$radioNone.Size = New-Object Drawing.Size(120, 25)
$loginGroup.Controls.Add($radioNone)

$radioFile = New-Object Windows.Forms.RadioButton
$radioFile.Text = "Edge 扩展 Cookie（推荐）"
$radioFile.Location = New-Object Drawing.Point(390, 25)
$radioFile.Size = New-Object Drawing.Size(180, 25)
$radioFile.Checked = $true
$loginGroup.Controls.Add($radioFile)

$extensionButton = New-Object Windows.Forms.Button
$extensionButton.Text = "打开 Cookie 扩展商店"
$extensionButton.Location = New-Object Drawing.Point(590, 21)
$extensionButton.Size = New-Object Drawing.Size(196, 32)
$extensionButton.Anchor = "Top,Right"
$loginGroup.Controls.Add($extensionButton)

$cookieBox = New-Object Windows.Forms.TextBox
$cookieBox.Location = New-Object Drawing.Point(16, 61)
$cookieBox.Size = New-Object Drawing.Size(630, 27)
$cookieBox.Text = $script:defaultCookieFile
$cookieBox.Anchor = "Top,Left,Right"
$loginGroup.Controls.Add($cookieBox)

$cookieButton = New-Object Windows.Forms.Button
$cookieButton.Text = "读取导出文件"
$cookieButton.Location = New-Object Drawing.Point(654, 59)
$cookieButton.Size = New-Object Drawing.Size(132, 30)
$cookieButton.Anchor = "Top,Right"
$loginGroup.Controls.Add($cookieButton)

$optionGroup = New-Object Windows.Forms.GroupBox
$optionGroup.Text = "3. 画质与保存位置"
$optionGroup.Location = New-Object Drawing.Point(24, 313)
$optionGroup.Size = New-Object Drawing.Size(802, 187)
$optionGroup.Anchor = "Top,Left,Right"
$form.Controls.Add($optionGroup)

$qualityLabel = New-Object Windows.Forms.Label
$qualityLabel.Text = "画质："
$qualityLabel.Location = New-Object Drawing.Point(16, 29)
$qualityLabel.AutoSize = $true
$optionGroup.Controls.Add($qualityLabel)

$qualityBox = New-Object Windows.Forms.ComboBox
$qualityBox.DropDownStyle = "DropDownList"
$qualityBox.Location = New-Object Drawing.Point(72, 25)
$qualityBox.Size = New-Object Drawing.Size(574, 28)
$qualityBox.Anchor = "Top,Left,Right"
[void]$qualityBox.Items.Add("请先获取可用画质")
$qualityBox.SelectedIndex = 0
$optionGroup.Controls.Add($qualityBox)

$fetchButton = New-Object Windows.Forms.Button
$fetchButton.Text = "获取可用画质"
$fetchButton.Location = New-Object Drawing.Point(654, 23)
$fetchButton.Size = New-Object Drawing.Size(132, 31)
$fetchButton.Anchor = "Top,Right"
$optionGroup.Controls.Add($fetchButton)

$defaultQualityLabel = New-Object Windows.Forms.Label
$defaultQualityLabel.Text = "默认画质："
$defaultQualityLabel.Location = New-Object Drawing.Point(16, 70)
$defaultQualityLabel.AutoSize = $true
$optionGroup.Controls.Add($defaultQualityLabel)

$defaultQualityBox = New-Object Windows.Forms.ComboBox
$defaultQualityBox.DropDownStyle = "DropDownList"
$defaultQualityBox.Location = New-Object Drawing.Point(88, 66)
$defaultQualityBox.Size = New-Object Drawing.Size(245, 28)
[void]$defaultQualityBox.Items.AddRange(@(
    "最高可用画质",
    "2160p 60fps",
    "2160p",
    "1440p 60fps",
    "1440p",
    "1080p 60fps（默认）",
    "1080p",
    "720p 60fps",
    "720p"
))
$defaultQualityBox.SelectedItem = "1080p 60fps（默认）"
$optionGroup.Controls.Add($defaultQualityBox)

$defaultQualityHint = New-Object Windows.Forms.Label
$defaultQualityHint.Text = "获取画质后自动选择；仍可在上方手动更改"
$defaultQualityHint.ForeColor = [Drawing.Color]::DimGray
$defaultQualityHint.Location = New-Object Drawing.Point(345, 70)
$defaultQualityHint.AutoSize = $true
$optionGroup.Controls.Add($defaultQualityHint)

$defaultCodecLabel = New-Object Windows.Forms.Label
$defaultCodecLabel.Text = "默认编码："
$defaultCodecLabel.Location = New-Object Drawing.Point(16, 109)
$defaultCodecLabel.AutoSize = $true
$optionGroup.Controls.Add($defaultCodecLabel)

$defaultCodecBox = New-Object Windows.Forms.ComboBox
$defaultCodecBox.DropDownStyle = "DropDownList"
$defaultCodecBox.Location = New-Object Drawing.Point(88, 105)
$defaultCodecBox.Size = New-Object Drawing.Size(245, 28)
[void]$defaultCodecBox.Items.AddRange(@(
    "自动（按 yt-dlp 排序）",
    "AVC（兼容性最好，默认）",
    "HEVC（更小体积）",
    "AV1（更高压缩率）"
))
$defaultCodecBox.SelectedItem = "AVC（兼容性最好，默认）"
$optionGroup.Controls.Add($defaultCodecBox)

$defaultCodecHint = New-Object Windows.Forms.Label
$defaultCodecHint.Text = "编码不可用时自动回退到同画质的其他编码"
$defaultCodecHint.ForeColor = [Drawing.Color]::DimGray
$defaultCodecHint.Location = New-Object Drawing.Point(345, 109)
$defaultCodecHint.AutoSize = $true
$optionGroup.Controls.Add($defaultCodecHint)

$outputLabel = New-Object Windows.Forms.Label
$outputLabel.Text = "保存到："
$outputLabel.Location = New-Object Drawing.Point(16, 148)
$outputLabel.AutoSize = $true
$optionGroup.Controls.Add($outputLabel)

$outputBox = New-Object Windows.Forms.TextBox
$outputBox.Location = New-Object Drawing.Point(72, 144)
$outputBox.Size = New-Object Drawing.Size(424, 27)
$outputBox.Anchor = "Top,Left,Right"
$outputBox.Text = Join-Path $env:USERPROFILE "Downloads"
$optionGroup.Controls.Add($outputBox)

$outputButton = New-Object Windows.Forms.Button
$outputButton.Text = "选择文件夹"
$outputButton.Location = New-Object Drawing.Point(504, 142)
$outputButton.Size = New-Object Drawing.Size(132, 31)
$outputButton.Anchor = "Top,Right"
$optionGroup.Controls.Add($outputButton)

$openOutputButton = New-Object Windows.Forms.Button
$openOutputButton.Text = "打开下载文件路径"
$openOutputButton.Location = New-Object Drawing.Point(644, 142)
$openOutputButton.Size = New-Object Drawing.Size(142, 31)
$openOutputButton.Anchor = "Top,Right"
$optionGroup.Controls.Add($openOutputButton)

$downloadButton = New-Object Windows.Forms.Button
$downloadButton.Text = "开始下载"
$downloadButton.Font = New-Object Drawing.Font("Microsoft YaHei UI", 10, [Drawing.FontStyle]::Bold)
$downloadButton.Location = New-Object Drawing.Point(24, 517)
$downloadButton.Size = New-Object Drawing.Size(130, 40)
$form.Controls.Add($downloadButton)

$cancelButton = New-Object Windows.Forms.Button
$cancelButton.Text = "取消"
$cancelButton.Location = New-Object Drawing.Point(164, 517)
$cancelButton.Size = New-Object Drawing.Size(82, 40)
$cancelButton.Enabled = $false
$form.Controls.Add($cancelButton)

$statusLabel = New-Object Windows.Forms.Label
$statusLabel.Text = "就绪"
$statusLabel.TextAlign = "MiddleRight"
$statusLabel.Location = New-Object Drawing.Point(610, 522)
$statusLabel.Size = New-Object Drawing.Size(216, 30)
$statusLabel.Anchor = "Top,Right"
$form.Controls.Add($statusLabel)

$progress = New-Object Windows.Forms.ProgressBar
$progress.Location = New-Object Drawing.Point(24, 567)
$progress.Size = New-Object Drawing.Size(802, 20)
$progress.Anchor = "Top,Left,Right"
$form.Controls.Add($progress)

$logGroup = New-Object Windows.Forms.GroupBox
$logGroup.Text = "运行日志"
$logGroup.Location = New-Object Drawing.Point(24, 597)
$logGroup.Size = New-Object Drawing.Size(802, 151)
$logGroup.Anchor = "Top,Bottom,Left,Right"
$form.Controls.Add($logGroup)

$logBox = New-Object Windows.Forms.RichTextBox
$logBox.ReadOnly = $true
$logBox.BorderStyle = "None"
$logBox.BackColor = [Drawing.Color]::White
$logBox.Font = New-Object Drawing.Font("Consolas", 9)
$logBox.Dock = "Fill"
$logGroup.Controls.Add($logBox)

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 400

if (Test-Path -LiteralPath $script:configFile) {
    try {
        $config = Get-Content -LiteralPath $script:configFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($config.output) { $outputBox.Text = $config.output }
        if ($config.cookieFile) { $cookieBox.Text = $config.cookieFile }
        if ($config.defaultQuality -and $defaultQualityBox.Items.Contains([string]$config.defaultQuality)) {
            $defaultQualityBox.SelectedItem = [string]$config.defaultQuality
        }
        if ($config.defaultCodec -and $defaultCodecBox.Items.Contains([string]$config.defaultCodec)) {
            $defaultCodecBox.SelectedItem = [string]$config.defaultCodec
        }
        if ($config.cookieMode -eq "none") { $radioNone.Checked = $true }
        if ($config.cookieMode -eq "file") { $radioFile.Checked = $true }
    } catch { }
}

$updateCookieUi = {
    $enabled = $radioFile.Checked
    $cookieBox.Enabled = $enabled
    $cookieButton.Enabled = $enabled
}
$radioEdge.Add_CheckedChanged($updateCookieUi)
$radioNone.Add_CheckedChanged($updateCookieUi)
$radioFile.Add_CheckedChanged($updateCookieUi)
& $updateCookieUi

$pasteButton.Add_Click({
    if ([Windows.Forms.Clipboard]::ContainsText()) { $urlBox.Text = [Windows.Forms.Clipboard]::GetText().Trim() }
})

$edgeUrlButton.Add_Click({
    try {
        $edge = Get-Process msedge -ErrorAction Stop | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
        if (-not $edge) { throw "没有找到已打开的 Edge 窗口。" }
        $shell = New-Object -ComObject WScript.Shell
        [void]$shell.AppActivate($edge.Id)
        Start-Sleep -Milliseconds 250
        $shell.SendKeys("^l")
        Start-Sleep -Milliseconds 120
        $shell.SendKeys("^c")
        Start-Sleep -Milliseconds 250
        $shell.SendKeys("{ESC}")
        $url = [Windows.Forms.Clipboard]::GetText().Trim()
        $form.Activate()
        if ($url -notmatch '^https?://(?:[^/]+\.)?(?:bilibili\.com|b23\.tv)/') { throw "Edge 当前页面似乎不是 B 站视频页。" }
        $urlBox.Text = $url
        Add-Log "已读取 Edge 当前页：$url"
    } catch {
        $form.Activate()
        [Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, "读取失败", "OK", "Warning") | Out-Null
    }
})

$extensionButton.Add_Click({
    try {
        Start-Process -FilePath "msedge.exe" -ArgumentList $script:cookieExtensionUrl
        $instructions = @'
已打开 Get cookies.txt LOCALLY 扩展商店页面。

1. 如果 Edge 提示，请允许安装其他商店的扩展
2. 点击“获取”或“添加至 Edge”
3. 打开 B 站视频页并确认账号已登录
4. 点击扩展图标，导出当前站点的 Netscape cookies.txt
5. 回到程序点击“读取导出文件”并选择该文件
'@
        [Windows.Forms.MessageBox]::Show(
            $form,
            $instructions,
            "安装 Get cookies.txt LOCALLY",
            "OK",
            "Information"
        ) | Out-Null
    } catch {
        [Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, "无法打开扩展商店", "OK", "Error") | Out-Null
    }
})

$cookieButton.Add_Click({
    if (Test-Path -LiteralPath $script:defaultCookieFile -PathType Leaf) {
        $cookieBox.Text = $script:defaultCookieFile
        $radioFile.Checked = $true
        Add-Log "已读取扩展导出的 Cookie：$script:defaultCookieFile"
        [Windows.Forms.MessageBox]::Show($form, "已找到扩展导出的 Cookie 文件。现在可以获取可用画质。", "Cookie 已载入", "OK", "Information") | Out-Null
        return
    }
    $dialog = New-Object Windows.Forms.OpenFileDialog
    $dialog.Filter = "Cookie text (*.txt)|*.txt|All files (*.*)|*.*"
    $dialog.InitialDirectory = Join-Path $env:USERPROFILE "Downloads"
    if ($dialog.ShowDialog($form) -eq "OK") {
        $cookieBox.Text = $dialog.FileName
        $radioFile.Checked = $true
    }
})

$outputButton.Add_Click({
    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    $dialog.SelectedPath = $outputBox.Text
    if ($dialog.ShowDialog($form) -eq "OK") { $outputBox.Text = $dialog.SelectedPath }
})

$openOutputButton.Add_Click({
    try {
        $path = $outputBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($path)) { throw "请先选择下载保存目录。" }
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        Start-Process -FilePath "explorer.exe" -ArgumentList (Quote-Argument $path)
    } catch {
        [Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, "无法打开下载路径", "OK", "Error") | Out-Null
    }
})

$defaultQualityBox.Add_SelectedIndexChanged({
    if ($script:formatMap.Count -gt 0) { Set-PreferredQualitySelection }
})

$defaultCodecBox.Add_SelectedIndexChanged({
    if ($script:formatMap.Count -gt 0) { Set-PreferredQualitySelection }
})

$fetchButton.Add_Click({
    if (-not (Test-Inputs)) { return }
    Set-Busy $true "正在读取视频与会员画质…"
    Add-Log "正在请求视频信息，请稍候…"
    [Windows.Forms.Application]::DoEvents()
    try {
        $arguments = @("--dump-single-json", "--skip-download", "--no-playlist", "--no-warnings") + (Get-CookieArguments) + @($urlBox.Text.Trim())
        $result = Invoke-YtDlp $arguments
        if ($result.ExitCode -ne 0) { throw ($result.StdErr + "`r`n" + $result.StdOut) }
        $data = $result.StdOut | ConvertFrom-Json
        $script:formatMap = @{}
        $qualityBox.Items.Clear()
        $autoLabel = "自动最佳画质（推荐）"
        [void]$qualityBox.Items.Add($autoLabel)
        $script:formatMap[$autoLabel] = "bv*+ba/b"
        $formats = $data.formats | Where-Object { $_.vcodec -and $_.vcodec -ne "none" -and $_.format_id } | Sort-Object @{Expression={$_.height};Descending=$true}, @{Expression={$_.fps};Descending=$true}, @{Expression={$_.tbr};Descending=$true}
        foreach ($item in $formats) {
            $resolution = if ($item.resolution) { $item.resolution } elseif ($item.height) { "$($item.height)p" } else { "未知分辨率" }
            $note = if ($item.format_note) { "$($item.format_note) · " } else { "" }
            $fps = if ($item.fps) { " $($item.fps)fps" } else { "" }
            $dynamic = if ($item.dynamic_range -and $item.dynamic_range -ne "SDR") { " $($item.dynamic_range)" } else { "" }
            $rawSize = if ($item.filesize) { $item.filesize } else { $item.filesize_approx }
            $size = Get-HumanSize $rawSize
            $sizeText = if ($size) { " 约$size" } else { "" }
            $label = "$note$resolution$fps · $(Get-CodecName $item.vcodec)$dynamic$sizeText"
            if ($script:formatMap.ContainsKey($label)) { $label += " · ID $($item.format_id)" }
            $selector = if ($item.acodec -and $item.acodec -ne "none") { [string]$item.format_id } else { "$($item.format_id)+ba/$($item.format_id)" }
            [void]$qualityBox.Items.Add($label)
            $script:formatMap[$label] = $selector
        }
        Set-PreferredQualitySelection
        Add-Log "视频：$($data.title)"
        Add-Log "已发现 $($formats.Count) 个视频格式。"
        Set-Busy $false "画质读取完成"
    } catch {
        Set-Busy $false "操作失败"
        Show-FriendlyError $_.Exception.Message
    }
})

$downloadButton.Add_Click({
    if (-not (Test-Inputs $true)) { return }
    Save-Config
    $progress.Value = 0
    $script:userCancelled = $false
    $selector = $script:formatMap[$qualityBox.Text]
    $arguments = @(
        "--newline", "--progress", "--no-playlist", "--windows-filenames",
        "--ffmpeg-location", $script:ffmpeg,
        "--format", $selector,
        "--merge-output-format", "mp4", "--remux-video", "mp4", "--embed-metadata",
        "--paths", $outputBox.Text.Trim(),
        "--output", "%(title).180B [%(id)s].%(ext)s"
    ) + (Get-CookieArguments) + @($urlBox.Text.Trim())
    try {
        $argumentText = (($arguments | ForEach-Object { Quote-Argument $_ }) -join " ")
        $script:downloadRunner = New-Object BiliCatchProcessRunner
        $script:downloadRunner.Start($script:ytDlp, $argumentText)
        Add-Log "开始下载：$($qualityBox.Text)"
        Set-Busy $true "准备下载…" $true
        $timer.Start()
    } catch {
        Set-Busy $false "启动失败"
        Show-FriendlyError $_.Exception.Message
    }
})

$timer.Add_Tick({
    if (-not $script:downloadRunner) { return }
    $newText = $script:downloadRunner.Drain()
    if ($newText) {
        Add-Log $newText
        $matches = [regex]::Matches($newText, '\[download\]\s+([0-9.]+)%')
        if ($matches.Count -gt 0) {
            $value = [Math]::Min(100, [Math]::Max(0, [double]$matches[$matches.Count - 1].Groups[1].Value))
            $progress.Value = [int]$value
            $statusLabel.Text = "下载中 {0:N1}%" -f $value
        }
    }
    if ($script:downloadRunner.HasExited) {
        $timer.Stop()
        $exitCode = $script:downloadRunner.Complete()
        $finalText = $script:downloadRunner.Drain()
        if ($finalText) { Add-Log $finalText }
        $script:downloadRunner.Dispose()
        $script:downloadRunner = $null
        if ($exitCode -eq 0 -and -not $script:userCancelled) {
            $progress.Value = 100
            Set-Busy $false "下载完成"
            Add-Log "下载完成，文件保存在：$($outputBox.Text.Trim())"
            [Windows.Forms.MessageBox]::Show($form, "下载完成！`r`n`r`n保存位置：`r`n$($outputBox.Text.Trim())", "完成", "OK", "Information") | Out-Null
        } elseif ($script:userCancelled) {
            Set-Busy $false "已取消"
            Add-Log "任务已取消；未完成的 .part 文件会保留，便于下次续传。"
        } else {
            Set-Busy $false "下载失败"
            Show-FriendlyError "下载进程退出，错误码 $exitCode。请查看日志；未完成文件已保留。"
        }
    }
})

$cancelButton.Add_Click({
    if ($script:downloadRunner -and -not $script:downloadRunner.HasExited) {
        $script:userCancelled = $true
        $statusLabel.Text = "正在取消…"
        Start-Process -FilePath "taskkill.exe" -ArgumentList "/PID $($script:downloadRunner.Id) /T /F" -WindowStyle Hidden -Wait
    }
})

$form.Add_FormClosing({
    if ($script:downloadRunner -and -not $script:downloadRunner.HasExited) {
        $answer = [Windows.Forms.MessageBox]::Show($form, "下载仍在进行，确定退出并取消吗？", "确认退出", "YesNo", "Question")
        if ($answer -ne "Yes") { $_.Cancel = $true; return }
        Start-Process -FilePath "taskkill.exe" -ArgumentList "/PID $($script:downloadRunner.Id) /T /F" -WindowStyle Hidden -Wait
    }
    try { Save-Config } catch { }
})

[void]$form.ShowDialog()
