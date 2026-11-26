param(
    [ValidateSet("start", "install", "status", "stop")]
    [string]$Action = "start"
)

$ErrorActionPreference = "Stop"
$StartupRoot = $PSScriptRoot
$PreviewRoot = "D:\projects\Cases-Web-Preview"
$PublicRoot = Join-Path $PreviewRoot "public"
$RuntimeRoot = Join-Path $PreviewRoot "runtime"
$SettingsPath = Join-Path $StartupRoot ".env.web-preview"
$ServerScript = Join-Path $StartupRoot "web_preview_server.py"
$GuiProject = "D:\projects\Cases-GUI\godot"
$GodotPath = "D:\tools\Godot-4.7.2\Godot_v4.7.2-stable_win64.exe"
$TaskName = "CASES Web Preview"
$PreviewPort = 8767

New-Item -ItemType Directory -Force -Path $RuntimeRoot | Out-Null

function Write-PreviewLog([string]$Message) {
    Add-Content -LiteralPath (Join-Path $RuntimeRoot "startup.log") -Value "$(Get-Date -Format o) $Message"
}

function Read-PreviewPassword {
    if (-not (Test-Path -LiteralPath $SettingsPath)) {
        throw "Missing local preview password file: $SettingsPath"
    }
    $match = Select-String -LiteralPath $SettingsPath -Pattern '^CASES_PREVIEW_PASSWORD=(.+)$' | Select-Object -First 1
    if (-not $match) { throw "Preview password is not configured." }
    return $match.Matches[0].Groups[1].Value
}

function Test-TcpPort([int]$Port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $result = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
        if (-not $result.AsyncWaitHandle.WaitOne(350)) { return $false }
        $client.EndConnect($result)
        return $true
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function Start-Preview {
    $password = Read-PreviewPassword
    $python = (Get-Command python -ErrorAction Stop).Source
    $tailscale = (Get-Command tailscale -ErrorAction Stop).Source
    if (-not (Test-Path -LiteralPath $GodotPath)) { throw "Godot was not found at $GodotPath" }
    if (-not (Test-Path -LiteralPath $ServerScript)) { throw "Web preview server is missing: $ServerScript" }

    Write-PreviewLog "Starting pinned CASES model, backend, and web preview services."
    & (Join-Path $StartupRoot "cases.ps1") start-models
    & (Join-Path $StartupRoot "cases.ps1") start-backend

    $ready = $false
    for ($attempt = 0; $attempt -lt 45; $attempt++) {
        try {
            $health = Invoke-RestMethod -Uri "http://127.0.0.1:18082/readyz" -TimeoutSec 2
            if ($health) { $ready = $true; break }
        } catch {}
        Start-Sleep -Seconds 2
    }
    if (-not $ready) { throw "Cases-Backend did not become ready on 127.0.0.1:18082." }

    New-Item -ItemType Directory -Force -Path $PublicRoot | Out-Null
    & $GodotPath --headless --path $GuiProject --export-release "Web" (Join-Path $PublicRoot "index.html")
    if ($LASTEXITCODE -ne 0) { throw "Godot web export failed with exit code $LASTEXITCODE." }

    if (Test-TcpPort $PreviewPort) {
        $pidFile = Join-Path $RuntimeRoot "web-preview.pid"
        $existingPid = 0
        if (Test-Path $pidFile) { [int]::TryParse((Get-Content $pidFile -Raw).Trim(), [ref]$existingPid) | Out-Null }
        if ($existingPid -gt 0 -and (Get-Process -Id $existingPid -ErrorAction SilentlyContinue)) {
            Write-PreviewLog "Web preview process $existingPid is already listening."
        } else {
            throw "Port $PreviewPort is already in use by an untracked process; no process was stopped."
        }
    } else {
        $env:CASES_PREVIEW_PASSWORD = $password
        $env:CASES_PREVIEW_PUBLIC = $PublicRoot
        $env:CASES_BACKEND_URL = "http://127.0.0.1:18082"
        $env:CASES_PREVIEW_PORT = "$PreviewPort"
        $stdoutLog = Join-Path $RuntimeRoot "web-preview.log"
        $stderrLog = Join-Path $RuntimeRoot "web-preview-error.log"
        $process = Start-Process -FilePath $python -ArgumentList @($ServerScript) -WorkingDirectory $StartupRoot -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog
        Set-Content -LiteralPath (Join-Path $RuntimeRoot "web-preview.pid") -Value $process.Id
        Write-PreviewLog "Started password-gated local server process $($process.Id)."
        Start-Sleep -Seconds 2
        if (-not (Test-TcpPort $PreviewPort)) { throw "Password-gated web server failed to listen; inspect $stderrLog." }
    }

    & $tailscale funnel --yes --bg --https=443 "http://127.0.0.1:$PreviewPort"
    if ($LASTEXITCODE -ne 0) { throw "Tailscale Funnel could not be enabled. The site remains local and password-protected." }
    & $tailscale funnel status
    Write-PreviewLog "HTTPS Funnel enabled for the password-gated preview."
}

function Install-LogonTask {
    $identity = "$env:USERDOMAIN\$env:USERNAME"
    $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Action start'
    $taskAction = New-ScheduledTaskAction -Execute $powershell -Argument $arguments
    $taskTrigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
    $taskSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 20)
    Register-ScheduledTask -TaskName $TaskName -Action $taskAction -Trigger $taskTrigger -Principal $taskPrincipal -Settings $taskSettings -Description "Starts the private CASES web preview and local inference stack after Marcus signs in." -Force | Out-Null
    Write-PreviewLog "Registered logon task for the current Windows user."
}

function Stop-Preview {
    $tailscale = Get-Command tailscale -ErrorAction SilentlyContinue
    if ($tailscale) { & $tailscale.Source funnel reset }
    $pidFile = Join-Path $RuntimeRoot "web-preview.pid"
    if (Test-Path $pidFile) {
        $serverPid = 0
        [int]::TryParse((Get-Content $pidFile -Raw).Trim(), [ref]$serverPid) | Out-Null
        if ($serverPid -gt 0) {
            $process = Get-Process -Id $serverPid -ErrorAction SilentlyContinue
            if ($process -and $process.ProcessName -eq "python") { Stop-Process -Id $serverPid }
        }
        Remove-Item -LiteralPath $pidFile -Force
    }
    Write-PreviewLog "Stopped the public Funnel route and web preview process. Backend services remain running."
}

switch ($Action) {
    "install" {
        Install-LogonTask
        Start-Preview
    }
    "start" { Start-Preview }
    "stop" { Stop-Preview }
    "status" {
        & (Join-Path $StartupRoot "cases.ps1") status
        & ((Get-Command tailscale -ErrorAction Stop).Source) funnel status
        if (Test-TcpPort $PreviewPort) { "Web preview: listening on 127.0.0.1:$PreviewPort" } else { "Web preview: stopped" }
    }
}
