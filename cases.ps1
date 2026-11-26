[CmdletBinding()]
param(
    [ValidateSet('setup', 'start', 'start-models', 'start-backend', 'start-gui', 'install-dashboard', 'status', 'branches', 'stop')]
    [string]$Action = 'start',
    [string]$ProjectRoot = 'D:\projects',
    [string]$GodotPath = 'D:\tools\Godot-4.7.2\Godot_v4.7.2-stable_win64.exe',
    [ValidateRange(1, 65535)]
    [int]$BackendPort = 18082,
    [Alias('Ref')]
    [string]$Branch = '',
    [string]$AIRef = '',
    [string]$BackendRef = '',
    [string]$GUIRef = '',
    [switch]$Locked
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:StartupRoot = $PSScriptRoot
$script:ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
$script:Lock = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'repos.lock.json') -Raw | ConvertFrom-Json
$script:SelectedBranches = @{}
$script:AI = Join-Path $script:ProjectRoot 'Cases-AI'
$script:Backend = Join-Path $script:ProjectRoot 'Cases-Backend'
$script:GUI = Join-Path $script:ProjectRoot 'Cases-GUI'
if ($env:LOCALAPPDATA) {
    $script:StateRoot = Join-Path $env:LOCALAPPDATA 'Cases-Startup'
} else {
    $script:StateRoot = Join-Path $env:TEMP 'Cases-Startup'
}
$script:BridgeState = Join-Path $script:StateRoot 'codex-bridge.json'
$script:GUIState = Join-Path $script:StateRoot 'godot-gui.json'
$script:DashboardUrl = 'http://127.0.0.1:8765'
$script:BackendUrl = "http://127.0.0.1:$BackendPort"

function Invoke-Git {
    param([string]$Repository, [string[]]$GitArguments)
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & git -C $Repository @GitArguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) { throw "Git failed in $Repository. Arguments: $($GitArguments -join ' ')" }
    return @($output | ForEach-Object { $_.ToString() })
}

function Ensure-PinnedRepository {
    param($RepositoryLock)
    $path = Join-Path $script:ProjectRoot $RepositoryLock.name
    if (-not (Test-Path -LiteralPath (Join-Path $path '.git'))) {
        if (Test-Path -LiteralPath $path) {
            $entries = @(Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue)
            if ($entries.Count -gt 0) { throw "$path exists and is not a Git checkout. Choose another -ProjectRoot; existing files were left untouched." }
        } else {
            New-Item -ItemType Directory -Path $script:ProjectRoot -Force | Out-Null
        }
        Write-Host "Cloning $($RepositoryLock.name) at its locked revision..."
        $clone = & git clone --no-checkout $RepositoryLock.url $path 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Could not clone $($RepositoryLock.name): $($clone -join ' ')" }
        $null = Invoke-Git $path @('fetch', 'origin', $RepositoryLock.ref)
        $null = Invoke-Git $path @('checkout', '--detach', $RepositoryLock.commit)
    }
    $top = (Invoke-Git $path @('rev-parse', '--show-toplevel') | Select-Object -Last 1).Trim()
    if ([System.IO.Path]::GetFullPath($top) -ne [System.IO.Path]::GetFullPath($path)) { throw "$path is not the expected repository root." }
    $origin = (Invoke-Git $path @('remote', 'get-url', 'origin') | Select-Object -Last 1).Trim()
    if (-not [string]::Equals($origin, $RepositoryLock.url, [System.StringComparison]::OrdinalIgnoreCase)) { throw "$path has an unexpected origin. It was left unchanged." }
    $head = (Invoke-Git $path @('rev-parse', 'HEAD') | Select-Object -Last 1).Trim().ToLowerInvariant()
    if ($head -ne $RepositoryLock.commit.ToLowerInvariant()) { throw "$($RepositoryLock.name) is at $head; Cases-Startup locks $($RepositoryLock.commit). No reset or checkout was performed." }
    $dirty = @(Invoke-Git $path @('status', '--porcelain', '--untracked-files=normal'))
    if ($dirty.Count -gt 0) { throw "$path has uncommitted or untracked files. Preserve them and use another -ProjectRoot for the pinned startup checkout." }
}

function Get-SelectedBranch {
    param($RepositoryLock)
    $selected = $script:Branch
    switch ($RepositoryLock.name) {
        'Cases-AI' { if ($script:AIRef) { $selected = $script:AIRef } }
        'Cases-Backend' { if ($script:BackendRef) { $selected = $script:BackendRef } }
        'Cases-GUI' { if ($script:GUIRef) { $selected = $script:GUIRef } }
    }
    if (-not $selected) { $selected = $script:Lock.defaultBranch }
    $selected = $selected.Trim()
    if ($selected.StartsWith('refs/heads/')) { $selected = $selected.Substring('refs/heads/'.Length) }
    $valid = & git check-ref-format --branch $selected 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Invalid branch name '$selected' for $($RepositoryLock.name)." }
    return $selected
}

function Ensure-BranchRepository {
    param($RepositoryLock, [string]$Branch, [switch]$Preflight)
    $path = Join-Path $script:ProjectRoot $RepositoryLock.name
    if (-not (Test-Path -LiteralPath (Join-Path $path '.git'))) {
        if (Test-Path -LiteralPath $path) {
            $entries = @(Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue)
            if ($entries.Count -gt 0) { throw "$path exists and is not a Git checkout. Choose another -ProjectRoot; existing files were left untouched." }
        } else {
            New-Item -ItemType Directory -Path $script:ProjectRoot -Force | Out-Null
        }
        Write-Host "Cloning $($RepositoryLock.name) for branch $Branch..."
        $clone = & git clone --no-checkout $RepositoryLock.url $path 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Could not clone $($RepositoryLock.name): $($clone -join ' ')" }
    }
    $top = (Invoke-Git $path @('rev-parse', '--show-toplevel') | Select-Object -Last 1).Trim()
    if ([System.IO.Path]::GetFullPath($top) -ne [System.IO.Path]::GetFullPath($path)) { throw "$path is not the expected repository root." }
    $origin = (Invoke-Git $path @('remote', 'get-url', 'origin') | Select-Object -Last 1).Trim()
    if (-not [string]::Equals($origin, $RepositoryLock.url, [System.StringComparison]::OrdinalIgnoreCase)) { throw "$path has an unexpected origin. It was left unchanged." }

    $dirty = @(Invoke-Git $path @('status', '--porcelain', '--untracked-files=normal'))
    if ($dirty.Count -gt 0) { throw "$path has local edits. They were preserved; commit them or use another -ProjectRoot before switching branches." }

    $localRef = "refs/heads/$Branch"
    $remoteRef = "refs/remotes/origin/$Branch"
    $fetchSpec = '+refs/heads/{0}:{1}' -f $Branch, $remoteRef
    $fetchOutput = & git -C $path fetch origin $fetchSpec 2>&1
    $hasRemoteBranch = $LASTEXITCODE -eq 0
    $null = & git -C $path show-ref --verify --quiet $localRef
    $hasLocalBranch = $LASTEXITCODE -eq 0
    if (-not $hasRemoteBranch -and -not $hasLocalBranch) {
        throw "Branch '$Branch' does not exist locally or on origin for $($RepositoryLock.name). $($fetchOutput -join ' ')"
    }
    if ($hasRemoteBranch -and $hasLocalBranch) {
        $counts = (Invoke-Git $path @('rev-list', '--left-right', '--count', "origin/$Branch...$Branch") | Select-Object -Last 1).Trim() -split '\s+'
        if ([int]$counts[1] -gt 0) { throw "$($RepositoryLock.name) branch '$Branch' has local commits not on origin. Push or preserve them before startup can follow origin." }
    }
    if ($Preflight) {
        if ($hasLocalBranch) {
            $expectedPath = [System.IO.Path]::GetFullPath($path).TrimEnd('\')
            $activePath = ''
            foreach ($line in (Invoke-Git $path @('worktree', 'list', '--porcelain'))) {
                if ($line.StartsWith('worktree ')) { $activePath = $line.Substring(9) }
                elseif ($line -eq "branch refs/heads/$Branch" -and $activePath) {
                    $actualPath = [System.IO.Path]::GetFullPath($activePath).TrimEnd('\')
                    if (-not [string]::Equals($actualPath, $expectedPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                        throw "$($RepositoryLock.name) branch '$Branch' is already checked out in $actualPath. No repository branches were changed."
                    }
                }
            }
        }
        return
    }

    if ($hasLocalBranch) {
        $null = Invoke-Git $path @('switch', $Branch)
    } else {
        $null = Invoke-Git $path @('switch', '--track', '--create', $Branch, "origin/$Branch")
    }
    if ($hasRemoteBranch) {
        $upstreamOption = "--set-upstream-to=origin/$Branch"
        $null = Invoke-Git $path @('branch', $upstreamOption, $Branch)
        $null = Invoke-Git $path @('merge', '--ff-only', "origin/$Branch")
        Write-Host "$($RepositoryLock.name): following origin/$Branch at $((Invoke-Git $path @('rev-parse', '--short', 'HEAD') | Select-Object -Last 1).Trim())."
    } else {
        Write-Host "$($RepositoryLock.name): using local-only branch $Branch; origin has no matching branch to update from."
    }
}

function Get-EnvValue {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $pattern = '^\s*' + [regex]::Escape($Name) + '\s*='
    $line = Get-Content -LiteralPath $Path | Where-Object { $_ -match $pattern } | Select-Object -Last 1
    if ($null -eq $line) { return $null }
    return $line.Substring($line.IndexOf('=') + 1).Trim().Trim('"').Trim("'")
}

function Set-EnvValue {
    param([string]$Path, [string]$Name, [string]$Value)
    $lines = @()
    if (Test-Path -LiteralPath $Path) { $lines = @(Get-Content -LiteralPath $Path) }
    $pattern = '^\s*' + [regex]::Escape($Name) + '\s*='
    $found = $false
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match $pattern) { $lines[$index] = "$Name=$Value"; $found = $true }
    }
    if (-not $found) { $lines += "$Name=$Value" }
    [System.IO.File]::WriteAllLines($Path, [string[]]$lines, [System.Text.UTF8Encoding]::new($false))
}

function Test-RealSecret {
    param([string]$Value)
    return [bool]($Value -and $Value.Length -ge 24 -and $Value -notmatch '^(?i:replace|changeme|your-|todo|<)')
}

function New-RandomToken {
    $bytes = New-Object byte[] 32
    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $generator.GetBytes($bytes)
        return ([System.BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
    } finally { $generator.Dispose() }
}

function Initialize-PrivateConfiguration {
    $gatewayEnv = Join-Path $script:AI 'deploy\inference-gateway\.env'
    $gatewayExample = Join-Path $script:AI 'deploy\inference-gateway\.env.example'
    $backendEnv = Join-Path $script:Backend 'deployment\backend\.env'
    $backendExample = Join-Path $script:Backend 'deployment\backend\.env.example'
    & git -C $script:AI check-ignore -q 'deploy/inference-gateway/.env'
    if ($LASTEXITCODE -ne 0) { throw 'Cases-AI does not ignore its gateway .env; refusing to write secrets.' }
    & git -C $script:Backend check-ignore -q 'deployment/backend/.env'
    if ($LASTEXITCODE -ne 0) { throw 'Cases-Backend does not ignore its backend .env; refusing to write secrets.' }
    if (-not (Test-Path $gatewayEnv)) { Copy-Item $gatewayExample $gatewayEnv }
    if (-not (Test-Path $backendEnv)) { Copy-Item $backendExample $backendEnv }

    $aiClient = Get-EnvValue $gatewayEnv 'GATEWAY_CLIENT_TOKEN'
    $backendClient = Get-EnvValue $backendEnv 'INFERENCE_GATEWAY_TOKEN'
    $aiValid = Test-RealSecret $aiClient
    $backendValid = Test-RealSecret $backendClient
    if ($aiValid -and $backendValid -and $aiClient -ne $backendClient) {
        throw 'Cases-AI and Cases-Backend have different client tokens. Both were preserved; align them manually, then rerun setup.'
    }
    if ($aiValid) { $clientToken = $aiClient }
    elseif ($backendValid) { $clientToken = $backendClient }
    else { $clientToken = New-RandomToken }

    $adminToken = Get-EnvValue $gatewayEnv 'GATEWAY_ADMIN_TOKEN'
    if (-not (Test-RealSecret $adminToken)) { $adminToken = New-RandomToken }
    $bridgeToken = Get-EnvValue $gatewayEnv 'BRIDGE_TOKEN'
    if (-not (Test-RealSecret $bridgeToken)) { $bridgeToken = New-RandomToken }
    if ($clientToken -eq $adminToken -or $clientToken -eq $bridgeToken -or $adminToken -eq $bridgeToken) {
        throw 'Gateway client, admin, and bridge tokens must be different. Existing values were preserved.'
    }

    Set-EnvValue $gatewayEnv 'GATEWAY_CLIENT_TOKEN' $clientToken
    Set-EnvValue $gatewayEnv 'GATEWAY_ADMIN_TOKEN' $adminToken
    Set-EnvValue $gatewayEnv 'BRIDGE_TOKEN' $bridgeToken
    if (-not (Get-EnvValue $gatewayEnv 'LUNA_BRIDGE_PORT')) { Set-EnvValue $gatewayEnv 'LUNA_BRIDGE_PORT' '18765' }
    $adminPort = Get-EnvValue $gatewayEnv 'GATEWAY_ADMIN_HOST_PORT'
    if ($adminPort -notmatch '^\d{1,5}$' -or [int]$adminPort -eq 18766) {
        Set-EnvValue $gatewayEnv 'GATEWAY_ADMIN_HOST_PORT' '18768'
    }
    if (-not (Get-EnvValue $gatewayEnv 'LUNA_ENABLED')) { Set-EnvValue $gatewayEnv 'LUNA_ENABLED' 'false' }

    Set-EnvValue $gatewayEnv 'GATEWAY_CONTAINER_NAME' 'cases-startup-gateway'
    Set-EnvValue $gatewayEnv 'GATEWAY_ADMIN_CONTAINER_NAME' 'cases-startup-gateway-admin'
    Set-EnvValue $gatewayEnv 'GATEWAY_NETWORK_ALIAS' 'cases-startup-gateway'
    Set-EnvValue $gatewayEnv 'GATEWAY_UPSTREAM_URL' 'http://cases-startup-gateway:8080'

    $dbPassword = Get-EnvValue $backendEnv 'POSTGRES_PASSWORD'
    if (-not (Test-RealSecret $dbPassword)) { Set-EnvValue $backendEnv 'POSTGRES_PASSWORD' (New-RandomToken) }
    Set-EnvValue $backendEnv 'API_HOST_PORT' "$BackendPort"
    Set-EnvValue $backendEnv 'INFERENCE_GATEWAY_BASE_URL' 'http://cases-startup-gateway:8080'
    Set-EnvValue $backendEnv 'INFERENCE_GATEWAY_TOKEN' $clientToken
    Set-EnvValue $backendEnv 'LUNA_MODEL_ID' 'gpt-6-luna'
}

function Setup-Project {
    New-Item -ItemType Directory -Path $script:ProjectRoot -Force | Out-Null
    if ($Locked) {
        if ($Branch -or $AIRef -or $BackendRef -or $GUIRef) { throw 'Use either -Locked or branch selectors, not both.' }
        foreach ($repositoryLock in $script:Lock.repositories) { Ensure-PinnedRepository $repositoryLock }
        Write-Host 'Using the exact revisions saved in repos.lock.json.'
    } else {
        foreach ($repositoryLock in $script:Lock.repositories) {
            $script:SelectedBranches[$repositoryLock.name] = Get-SelectedBranch $repositoryLock
        }
        foreach ($repositoryLock in $script:Lock.repositories) {
            $selectedBranch = $script:SelectedBranches[$repositoryLock.name]
            Ensure-BranchRepository $repositoryLock $selectedBranch -Preflight
        }
        foreach ($repositoryLock in $script:Lock.repositories) {
            $selectedBranch = $script:SelectedBranches[$repositoryLock.name]
            Ensure-BranchRepository $repositoryLock $selectedBranch
        }
    }
    New-Item -ItemType Directory -Path $script:StateRoot -Force | Out-Null
    Initialize-PrivateConfiguration
    Write-Host "Source checkouts and private local configuration are ready under $script:ProjectRoot."
    Write-Host 'No containers were started and no model completion was sent.'
}

function Invoke-Compose {
    param([string]$ComposeFile, [string]$EnvFile, [string[]]$ComposeArguments, [string]$ProjectName = '')
    $arguments = @('compose')
    if ($ProjectName) { $arguments += @('-p', $ProjectName) }
    $arguments += @('--env-file', $EnvFile, '-f', $ComposeFile) + $ComposeArguments
    & docker @arguments
    if ($LASTEXITCODE -ne 0) { throw "Docker Compose failed for $ComposeFile." }
}

function Test-TcpPort {
    param([int]$Port)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $pending = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne(500)) { return $false }
        $client.EndConnect($pending)
        return $true
    } catch { return $false }
    finally { $client.Close() }
}

function Test-BridgeAtPort {
    param([int]$Port, [string]$Token)
    try {
        $health = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 3
        if ($health.status -ne 'ok') { return $false }
        $models = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/models" -Headers @{ Authorization = "Bearer $Token" } -TimeoutSec 3
        foreach ($model in @($models.data)) { if ($model.id -eq 'gpt-6-luna') { return $true } }
        return $false
    } catch { return $false }
}

function Get-ProcessRecord {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try { return Get-Content $Path -Raw | ConvertFrom-Json } catch { return $null }
}

function Save-ProcessRecord {
    param([string]$Path, [System.Diagnostics.Process]$Process, [string]$ExecutablePath, [string]$CommandPath)
    $Process.Refresh()
    $record = @{
        pid = $Process.Id
        startedUtc = $Process.StartTime.ToUniversalTime().ToString('o')
        executablePath = [System.IO.Path]::GetFullPath($ExecutablePath)
        commandPath = [System.IO.Path]::GetFullPath($CommandPath)
    }
    [System.IO.File]::WriteAllText($Path, ($record | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
}

function Start-LunaBridge {
    $gatewayEnv = Join-Path $script:AI 'deploy\inference-gateway\.env'
    $bridgeScript = Join-Path $script:AI 'integrations\codex-bridge\codex_bridge.py'
    $token = Get-EnvValue $gatewayEnv 'BRIDGE_TOKEN'
    $port = [int](Get-EnvValue $gatewayEnv 'LUNA_BRIDGE_PORT')
    if (Test-BridgeAtPort $port $token) { Write-Host "Codex bridge already ready on 127.0.0.1:$port."; return }
    if (Test-TcpPort $port) {
        $alternate = if ($port -eq 18765) { 18767 } else { 18765 }
        if (Test-TcpPort $alternate) { throw "Bridge ports $port and $alternate are occupied. No listener was stopped." }
        $port = $alternate
        Set-EnvValue $gatewayEnv 'LUNA_BRIDGE_PORT' "$port"
        Write-Host "Using loopback bridge port $port because the configured port was occupied."
    }
    $python = Get-Command python -ErrorAction Stop
    $codexCommand = Get-Command codex -ErrorAction SilentlyContinue
    if (-not $codexCommand) {
        $npmCommand = Get-Command npm -ErrorAction SilentlyContinue
        if ($npmCommand) {
            $npmPrefixOutput = & $npmCommand.Source prefix -g 2>$null
            if ($LASTEXITCODE -eq 0 -and $npmPrefixOutput) {
                $npmPrefix = [string]($npmPrefixOutput | Select-Object -Last 1)
                $npmPrefix = $npmPrefix.Trim()
                if ($npmPrefix -and (Test-Path -LiteralPath (Join-Path $npmPrefix 'codex.cmd'))) {
                    $env:PATH = "$npmPrefix;$env:PATH"
                    $codexCommand = Get-Command codex -ErrorAction SilentlyContinue
                }
            }
        }
    }
    if (-not $codexCommand) {
        throw "Codex CLI not found on PATH or in npm's global prefix. Install it with 'npm install -g @openai/codex' and sign in with ChatGPT."
    }
    $logs = Join-Path $script:StateRoot 'logs'
    New-Item -ItemType Directory -Path $logs -Force | Out-Null
    $oldHost = $env:LOCALAI_CODEX_BRIDGE_HOST
    $oldPort = $env:LOCALAI_CODEX_BRIDGE_PORT
    $oldToken = $env:LOCALAI_CODEX_BRIDGE_TOKEN
    try {
        $env:LOCALAI_CODEX_BRIDGE_HOST = '127.0.0.1'
        $env:LOCALAI_CODEX_BRIDGE_PORT = "$port"
        $env:LOCALAI_CODEX_BRIDGE_TOKEN = $token
        $process = Start-Process -FilePath $python.Source -ArgumentList ('"' + $bridgeScript + '"') -WorkingDirectory $script:AI -WindowStyle Hidden -RedirectStandardOutput (Join-Path $logs 'codex-bridge.stdout.log') -RedirectStandardError (Join-Path $logs 'codex-bridge.stderr.log') -PassThru
    } finally {
        $env:LOCALAI_CODEX_BRIDGE_HOST = $oldHost
        $env:LOCALAI_CODEX_BRIDGE_PORT = $oldPort
        $env:LOCALAI_CODEX_BRIDGE_TOKEN = $oldToken
    }
    Save-ProcessRecord $script:BridgeState $process $python.Source $bridgeScript
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        if (Test-BridgeAtPort $port $token) { Write-Host "Codex bridge ready on 127.0.0.1:$port (PID $($process.Id))."; return }
        Start-Sleep -Seconds 1
    }
    throw "Bridge did not become ready. Review logs under $logs."
}

function Get-GatewayStatus {
    $gatewayEnv = Join-Path $script:AI 'deploy\inference-gateway\.env'
    $adminToken = Get-EnvValue $gatewayEnv 'GATEWAY_ADMIN_TOKEN'
    $port = Get-EnvValue $gatewayEnv 'GATEWAY_ADMIN_HOST_PORT'
    if ($port -notmatch '^\d{1,5}$' -or [int]$port -lt 1 -or [int]$port -gt 65535) { return $null }
    try { return Invoke-RestMethod -Uri "http://127.0.0.1:$port/admin/v1/providers" -Headers @{ Authorization = "Bearer $adminToken" } -TimeoutSec 4 }
    catch { return $null }
}

function Ensure-GatewayAdminPort {
    $gatewayEnv = Join-Path $script:AI 'deploy\inference-gateway\.env'
    $portValue = Get-EnvValue $gatewayEnv 'GATEWAY_ADMIN_HOST_PORT'
    $portValid = $portValue -match '^\d{1,5}$' -and [int]$portValue -ge 1 -and [int]$portValue -le 65535
    if ($portValid) {
        if (-not (Test-TcpPort ([int]$portValue))) { return }
        $containerIds = & docker ps -q --filter 'name=^/cases-startup-gateway-admin$' 2>$null
        if ($LASTEXITCODE -eq 0 -and $containerIds) {
            $labelsJson = & docker inspect ($containerIds | Select-Object -First 1) --format '{{json .Config.Labels}}' 2>$null
            if ($LASTEXITCODE -eq 0 -and $labelsJson) {
                try {
                    $labels = ($labelsJson | Select-Object -Last 1) | ConvertFrom-Json
                    $project = $labels.'com.docker.compose.project'
                }
                catch { $project = $null }
                if ($project -eq 'cases-startup-inference-gateway' -and (Get-GatewayStatus)) {
                    return
                }
            }
        }
    }
    for ($candidate = 18768; $candidate -le 18820; $candidate++) {
        if (-not (Test-TcpPort $candidate)) {
            Set-EnvValue $gatewayEnv 'GATEWAY_ADMIN_HOST_PORT' "$candidate"
            Write-Host "Using loopback gateway admin port $candidate."
            return
        }
    }
    throw 'No free loopback admin port was found between 18768 and 18820. No listener was stopped.'
}

function Ensure-DockerNetwork {
    $null = & docker network inspect ddu_inference_bus 2>$null
    if ($LASTEXITCODE -ne 0) {
        & docker network create ddu_inference_bus | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not create ddu_inference_bus.' }
    }
}

function Start-Models {
    $gatewayEnv = Join-Path $script:AI 'deploy\inference-gateway\.env'
    $gatewayCompose = Join-Path $script:AI 'deploy\inference-gateway\compose.yaml'
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'Docker Desktop CLI is required.' }
    $null = & docker info --format '{{.ServerVersion}}' 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Docker Desktop is not running for this Windows user.' }
    Ensure-DockerNetwork
    Start-LunaBridge
    Ensure-GatewayAdminPort
    Invoke-Compose -ComposeFile $gatewayCompose -EnvFile $gatewayEnv -ComposeArguments @('up', '-d', '--build', 'inference-gateway', 'admin-proxy') -ProjectName 'cases-startup-inference-gateway'
    $luna = $null
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $status = Get-GatewayStatus
        $luna = if ($status -and $status.providers) { $status.providers | Where-Object { $_.id -eq 'codex_cli' } | Select-Object -First 1 } else { $null }
        if ($luna -and $luna.configured -and $luna.ready) { break }
        Start-Sleep -Seconds 2
    }
    if (-not $luna -or -not $luna.configured -or -not $luna.ready) { throw 'Gateway started, but the Luna bridge is not ready. No completion was sent.' }
    Write-Host "Cases-AI gateway and Luna bridge are ready. Luna enabled state is $($luna.enabled); startup did not change it."
}

function Start-Backend {
    $backendEnv = Join-Path $script:Backend 'deployment\backend\.env'
    $backendCompose = Join-Path $script:Backend 'deployment\backend\compose.yaml'
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'Docker Desktop CLI is required.' }
    $null = & docker info --format '{{.ServerVersion}}' 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Docker Desktop is not running for this Windows user.' }
    Ensure-DockerNetwork
    Invoke-Compose -ComposeFile $backendCompose -EnvFile $backendEnv -ComposeArguments @('up', '-d', '--build') -ProjectName 'cases-startup-backend'
    $deadline = [DateTime]::UtcNow.AddSeconds(120)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $health = Invoke-RestMethod -Uri "$script:BackendUrl/healthz" -TimeoutSec 3
            $ready = Invoke-RestMethod -Uri "$script:BackendUrl/readyz" -TimeoutSec 3
            if ($health.status -eq 'alive' -and $ready.status -eq 'ready') { Write-Host "Backend and database ready at $script:BackendUrl."; return }
        } catch { }
        Start-Sleep -Seconds 2
    }
    throw "Backend containers started, but API/database readiness at $script:BackendUrl did not succeed within 120 seconds."
}

function Test-LunaNarratorReady {
    try {
        $narrators = Invoke-RestMethod -Uri "$script:BackendUrl/api/v1/narrators" -TimeoutSec 20
        foreach ($narrator in @($narrators)) { if ($narrator.id -eq 'gpt6_luna_high') { return [bool]$narrator.ready } }
    } catch { }
    return $false
}

function Wait-ForLunaNarrator {
    param([int]$TimeoutSeconds = 180)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-LunaNarratorReady) { return $true }
        Start-Sleep -Seconds 3
    }
    return $false
}

function Test-Dashboard {
    try { $null = Invoke-RestMethod -Uri "$script:DashboardUrl/api/control/v1/controller/health" -TimeoutSec 3; return $true }
    catch { return $false }
}

function Ensure-DashboardForConsent {
    if (Test-Dashboard) { return }
    $task = Get-ScheduledTask -TaskName 'Local-AI-API-LITE Dashboard Controller' -ErrorAction SilentlyContinue
    if (-not $task) { throw 'Dashboard is not installed. Run .\cases.ps1 install-dashboard once, create its local admin, then rerun start. No GUI was launched.' }
    if ($task.State -ne 'Running') { Start-ScheduledTask -TaskName 'Local-AI-API-LITE Dashboard Controller' }
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        if (Test-Dashboard) { return }
        Start-Sleep -Seconds 1
    }
    throw 'Dashboard did not become ready on 127.0.0.1:8765.'
}

function Start-GUI {
    if (-not (Test-Path -LiteralPath $GodotPath -PathType Leaf)) { throw "Godot was not found at $GodotPath. Pass -GodotPath with the Godot 4.7.2 executable." }
    try {
        $ready = Invoke-RestMethod -Uri "$script:BackendUrl/readyz" -TimeoutSec 4
        if ($ready.status -ne 'ready') { throw 'database unavailable' }
    } catch { throw "Cases-Backend is not ready at $script:BackendUrl. Run start-backend first." }
    if (-not (Test-LunaNarratorReady)) { throw 'ChatGPT 6 Luna is not ready. Enable it through the dashboard after reviewing cloud-data disclosure. No Qwen fallback is used.' }
    $existing = Get-ProcessRecord $script:GUIState
    if ($existing) {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $($existing.pid)" -ErrorAction SilentlyContinue
        if ($proc -and [string]::Equals($proc.ExecutablePath, [System.IO.Path]::GetFullPath($GodotPath), [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Host "Godot GUI already running (PID $($existing.pid))."
            return
        }
    }
    $guiProject = Join-Path $script:GUI 'godot'
    $oldApiUrl = $env:CASES_API_BASE_URL
    try {
        $env:CASES_API_BASE_URL = $script:BackendUrl
        $process = Start-Process -FilePath $GodotPath -ArgumentList @('--path', $guiProject) -WorkingDirectory $script:GUI -PassThru
    } finally {
        $env:CASES_API_BASE_URL = $oldApiUrl
    }
    Save-ProcessRecord $script:GUIState $process $GodotPath $guiProject
    Write-Host "Cases-GUI opened in Godot (PID $($process.Id)); new sessions use ChatGPT 6 Luna."
}

function Install-Dashboard {
    $installer = Join-Path $script:AI 'dashboard\scripts\install_dashboard.ps1'
    if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) { throw 'Pinned Cases-AI dashboard installer was not found.' }
    & $installer
    Write-Host 'Dashboard installed. On first visit, open http://127.0.0.1:8765 and create the local administrator account.'
}

function Start-FullStack {
    Start-Models
    Start-Backend
    if (-not (Test-LunaNarratorReady)) {
        Ensure-DashboardForConsent
        Start-Process $script:DashboardUrl
        Write-Host 'In Dashboard > Providers, review the cloud-data disclosure, check the consent box, and enable ChatGPT 6 Luna.'
        $null = Read-Host 'After enabling Luna, return here and press Enter'
        if (-not (Wait-ForLunaNarrator 180)) { throw 'Luna did not become ready in 180 seconds. Services remain running; no fallback or GUI launch occurred.' }
    }
    Start-GUI
}

function Stop-TrackedProcess {
    param([string]$RecordPath, [string]$ExpectedCommandPath, [string]$ExpectedExecutable)
    $record = Get-ProcessRecord $RecordPath
    if (-not $record) { return }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $($record.pid)" -ErrorAction SilentlyContinue
    if (-not $process) { Remove-Item $RecordPath -Force -ErrorAction SilentlyContinue; return }
    if (-not [string]::Equals($process.ExecutablePath, [System.IO.Path]::GetFullPath($ExpectedExecutable), [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Host "PID $($record.pid) did not match its saved executable and was left running."; return
    }
    if ($process.CommandLine -notlike "*$ExpectedCommandPath*") {
        Write-Host "PID $($record.pid) did not match its saved command and was left running."; return
    }
    try {
        $actual = (Get-Process -Id $record.pid -ErrorAction Stop).StartTime.ToUniversalTime()
        $saved = [DateTime]::Parse($record.startedUtc).ToUniversalTime()
        if ([Math]::Abs(($actual - $saved).TotalSeconds) -gt 3) { Write-Host "PID $($record.pid) start time changed and it was left running."; return }
        Stop-Process -Id $record.pid -ErrorAction Stop
        Remove-Item $RecordPath -Force -ErrorAction SilentlyContinue
        Write-Host "Stopped managed process PID $($record.pid)."
    } catch { Write-Host "Could not stop managed PID $($record.pid)." }
}

function Stop-Project {
    $guiRecord = Get-ProcessRecord $script:GUIState
    if ($guiRecord) { Stop-TrackedProcess $script:GUIState $guiRecord.commandPath $guiRecord.executablePath }
    $backendEnv = Join-Path $script:Backend 'deployment\backend\.env'
    $backendCompose = Join-Path $script:Backend 'deployment\backend\compose.yaml'
    if ((Test-Path $backendCompose) -and (Test-Path $backendEnv)) { Invoke-Compose -ComposeFile $backendCompose -EnvFile $backendEnv -ComposeArguments @('down') -ProjectName 'cases-startup-backend' }
    $gatewayEnv = Join-Path $script:AI 'deploy\inference-gateway\.env'
    $gatewayCompose = Join-Path $script:AI 'deploy\inference-gateway\compose.yaml'
    if ((Test-Path $gatewayCompose) -and (Test-Path $gatewayEnv)) { Invoke-Compose -ComposeFile $gatewayCompose -EnvFile $gatewayEnv -ComposeArguments @('down') -ProjectName 'cases-startup-inference-gateway' }
    $bridgeRecord = Get-ProcessRecord $script:BridgeState
    if ($bridgeRecord) { Stop-TrackedProcess $script:BridgeState $bridgeRecord.commandPath $bridgeRecord.executablePath }
    Write-Host 'Cases services stopped. PostgreSQL and gateway state volumes were preserved; no volume-removal flag was used.'
}

function Show-Status {
    foreach ($item in $script:Lock.repositories) {
        $path = Join-Path $script:ProjectRoot $item.name
        if (Test-Path -LiteralPath (Join-Path $path '.git')) {
            $head = (Invoke-Git $path @('rev-parse', '--short', 'HEAD') | Select-Object -Last 1).Trim()
            $current = (Invoke-Git $path @('branch', '--show-current') | Select-Object -Last 1).Trim()
            $dirty = @(Invoke-Git $path @('status', '--porcelain', '--untracked-files=normal')).Count
            if ($Locked) {
                Write-Host "$($item.name): branch=$current, commit=$head, dirty=$dirty, locked=$($item.commit.Substring(0, 7))"
            } else {
                $selected = Get-SelectedBranch $item
                $remoteRef = "refs/remotes/origin/$selected"
                $null = & git -C $path rev-parse --verify --quiet $remoteRef 2>$null
                if ($LASTEXITCODE -eq 0) {
                    $counts = (Invoke-Git $path @('rev-list', '--left-right', '--count', "origin/$selected...HEAD") | Select-Object -Last 1).Trim() -split '\s+'
                    Write-Host "$($item.name): branch=$current, target=$selected, commit=$head, ahead=$($counts[1]), behind=$($counts[0]), dirty=$dirty"
                } else {
                    Write-Host "$($item.name): branch=$current, target=$selected, commit=$head, dirty=$dirty (origin ref not fetched)"
                }
            }
        } else { Write-Host "$($item.name): not cloned" }
    }
    $gateway = Get-GatewayStatus
    if ($gateway) {
        foreach ($provider in $gateway.providers) { Write-Host "Gateway $($provider.id): configured=$($provider.configured), enabled=$($provider.enabled), ready=$($provider.ready)" }
    } else { Write-Host 'Cases-AI gateway: unavailable' }
    $gatewayEnv = Join-Path $script:AI 'deploy\inference-gateway\.env'
    $portValue = Get-EnvValue $gatewayEnv 'LUNA_BRIDGE_PORT'
    $bridgeToken = Get-EnvValue $gatewayEnv 'BRIDGE_TOKEN'
    if ($portValue -and (Test-BridgeAtPort ([int]$portValue) $bridgeToken)) { Write-Host 'Codex CLI bridge: ready' }
    else { Write-Host 'Codex CLI bridge: unavailable' }
    try {
        $health = Invoke-RestMethod -Uri "$script:BackendUrl/healthz" -TimeoutSec 3
        $ready = Invoke-RestMethod -Uri "$script:BackendUrl/readyz" -TimeoutSec 3
        Write-Host "Cases-Backend: health=$($health.status), database=$($ready.status)"
        $narrators = Invoke-RestMethod -Uri "$script:BackendUrl/api/v1/narrators" -TimeoutSec 20
        foreach ($narrator in @($narrators)) { Write-Host "Narrator $($narrator.id): ready=$($narrator.ready), default=$($narrator.default)" }
    } catch { Write-Host 'Cases-Backend: unavailable' }
    if (Test-Path -LiteralPath $GodotPath -PathType Leaf) { Write-Host "Godot: $GodotPath" }
    else { Write-Host "Godot: missing at $GodotPath (override with -GodotPath)" }
}

function Show-Branches {
    foreach ($item in $script:Lock.repositories) {
        $path = Join-Path $script:ProjectRoot $item.name
        if (-not (Test-Path -LiteralPath (Join-Path $path '.git'))) {
            Write-Host "$($item.name): not cloned"
            continue
        }
        Write-Host "=== $($item.name)"
        $null = Invoke-Git $path @('fetch', 'origin')
        $worktrees = @()
        $currentWorktree = $null
        foreach ($line in (Invoke-Git $path @('worktree', 'list', '--porcelain'))) {
            if ($line.StartsWith('worktree ')) {
                if ($currentWorktree) { $worktrees += $currentWorktree }
                $currentWorktree = [ordered]@{ path = $line.Substring(9); branch = '' }
            } elseif ($line.StartsWith('branch ') -and $currentWorktree) {
                $currentWorktree.branch = $line.Substring(7).Replace('refs/heads/', '')
            }
        }
        if ($currentWorktree) { $worktrees += $currentWorktree }
        foreach ($tree in $worktrees) {
            $head = (Invoke-Git $tree.path @('rev-parse', '--short', 'HEAD') | Select-Object -Last 1).Trim()
            $dirtyFiles = @(Invoke-Git $tree.path @('status', '--porcelain', '--untracked-files=normal'))
            $branchLabel = if ($tree.branch) { $tree.branch } else { 'detached' }
            Write-Host "  worktree $($tree.path): $branchLabel @ $head; dirty=$($dirtyFiles.Count)"
            foreach ($dirtyFile in $dirtyFiles) { Write-Host "    $dirtyFile" }
        }

        $null = & git -C $path rev-parse --verify --quiet refs/remotes/origin/main 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Host '  origin/main is unavailable; ahead/behind scan skipped.'; continue }
        $localBranches = @(Invoke-Git $path @('for-each-ref', '--format=%(refname:short)', 'refs/heads'))
        foreach ($branch in $localBranches) {
            $counts = (Invoke-Git $path @('rev-list', '--left-right', '--count', "origin/main...$branch") | Select-Object -Last 1).Trim() -split '\s+'
            $uniqueChanges = @(Invoke-Git $path @('cherry', '-v', 'origin/main', $branch) | Where-Object { $_.StartsWith('+') })
            if ($uniqueChanges.Count -gt 0) {
                Write-Host "  local candidate ${branch}: unique=$($uniqueChanges.Count), behind=$($counts[0])"
                foreach ($change in $uniqueChanges) { Write-Host "    $change" }
            }
        }
        $remoteBranches = @(Invoke-Git $path @('for-each-ref', '--format=%(refname:short)', 'refs/remotes/origin'))
        foreach ($branch in $remoteBranches) {
            if ($branch -eq 'origin/main' -or $branch -eq 'origin/HEAD') { continue }
            $counts = (Invoke-Git $path @('rev-list', '--left-right', '--count', "origin/main...$branch") | Select-Object -Last 1).Trim() -split '\s+'
            $uniqueChanges = @(Invoke-Git $path @('cherry', '-v', 'origin/main', $branch) | Where-Object { $_.StartsWith('+') })
            if ($uniqueChanges.Count -gt 0) {
                Write-Host "  remote candidate ${branch}: unique=$($uniqueChanges.Count), behind=$($counts[0])"
                foreach ($change in $uniqueChanges) { Write-Host "    $change" }
            }
        }
    }
    Write-Host 'Dirty worktrees were only inspected. Startup did not alter or delete them.'
}

switch ($Action) {
    'setup' { Setup-Project }
    'start' { Setup-Project; Start-FullStack }
    'start-models' { Setup-Project; Start-Models }
    'start-backend' { Setup-Project; Start-Backend }
    'start-gui' { Setup-Project; Start-GUI }
    'install-dashboard' { Setup-Project; Install-Dashboard }
    'status' { Show-Status }
    'branches' { Show-Branches }
    'stop' { Stop-Project }
}
