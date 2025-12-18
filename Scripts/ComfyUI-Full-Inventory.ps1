# Outputs:
# - OutDir controls JSON/MD inventory artifacts
# - B:\ComfyUI\_logs contains a deterministic execution log + a separate transcript
[CmdletBinding()]
param(
    [string]$ComfyRoot = "B:\ComfyUI",
    [string]$OutDir = "B:\ComfyUI\_inventory",
    [switch]$IncludeFileHashes,
    [switch]$GitAudit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Dir($p){ if(-not(Test-Path $p)){New-Item -ItemType Directory -Path $p|Out-Null}}

function Write-Log {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )

    $tsUtc = (Get-Date).ToUniversalTime().ToString('o')
    Add-Content -LiteralPath $script:LogFile -Encoding UTF8 -Value "$tsUtc [$Level] $Message"
}

function Invoke-GitAudit {
    param(
        [Parameter(Mandatory=$true)][string]$ComfyRoot,
        [Parameter(Mandatory=$true)][string]$CustomNodesPath
    )

    $excludedRoots = @(
        (Join-Path $ComfyRoot 'models'),
        (Join-Path $ComfyRoot 'venv'),
        (Join-Path $ComfyRoot 'output'),
        (Join-Path $ComfyRoot 'input'),
        (Join-Path $ComfyRoot '_logs'),
        (Join-Path $ComfyRoot '_inventory')
    ) | ForEach-Object { $_.ToLowerInvariant().TrimEnd('\\') + '\\' }

    function Is-Excluded([string]$p) {
        $pl = $p.ToLowerInvariant().TrimEnd('\\') + '\\'
        foreach ($x in $excludedRoots) {
            if ($pl.StartsWith($x, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
        return $false
    }

    $repos = New-Object System.Collections.Generic.List[object]

    # Core repo (ComfyUI root)
    if (-not (Is-Excluded $ComfyRoot) -and (Test-Path (Join-Path $ComfyRoot '.git'))) {
        $repos.Add([pscustomobject]@{ path = $ComfyRoot; expected = $true; source = 'core' })
    }

    # Custom nodes (direct children only)
    if (Test-Path $CustomNodesPath) {
        $nodeDirs = Get-ChildItem -LiteralPath $CustomNodesPath -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne '__pycache__' -and $_.Name -ne '.disabled' -and -not $_.Name.StartsWith('.') }

        foreach ($d in $nodeDirs) {
            if (Is-Excluded $d.FullName) { continue }
            $gitPath = Join-Path $d.FullName '.git'
            if (Test-Path $gitPath) {
                $repos.Add([pscustomobject]@{ path = $d.FullName; expected = $true; source = 'custom_node' })
            }
        }
    }

    $results = foreach ($r in $repos) {
        $repoPath = $r.path
        $expected = [bool]$r.expected
        $health = 'OK'
        $reason = ''

        $gitDir = $null
        $headRef = $null
        $headSha = $null
        $remote = $null
        $layout = 'standard'

        $gitEntry = Join-Path $repoPath '.git'
        if (Test-Path $gitEntry) {
            $gi = Get-Item -LiteralPath $gitEntry -Force -ErrorAction SilentlyContinue
            if ($null -ne $gi -and -not $gi.PSIsContainer) { $layout = 'gitfile' }
        }

        try {
            $gitDir = (git -C $repoPath rev-parse --git-dir 2>$null | Select-Object -First 1)
            if (-not $gitDir) { throw 'rev-parse --git-dir returned empty' }
        } catch {
            $health = 'Broken'
            $reason = 'rev-parse --git-dir failed'
            [pscustomobject]@{ Path=$repoPath; ExpectedGitManaged=$expected; Health=$health; Reason=$reason; HeadRef=$null; HeadSha=$null }
            continue
        }

        try {
            $headRef = (git -C $repoPath symbolic-ref -q HEAD 2>$null | Select-Object -First 1)
            if ($headRef) { $headRef = $headRef.Trim() }
        } catch { $headRef = $null }

        try {
            $headSha = (git -C $repoPath rev-parse --verify HEAD 2>$null | Select-Object -First 1)
            if ($headSha) { $headSha = $headSha.Trim() }
        } catch { $headSha = $null }

        try {
            $remote = (git -C $repoPath remote get-url origin 2>$null | Select-Object -First 1)
            if ($remote) { $remote = $remote.Trim() }
        } catch { $remote = $null }

        # Health classification
        if (-not ($headSha -and ($headSha -match '^[0-9a-f]{40}$'))) {
            $health = 'Broken'
            $reason = if ($headRef) { "HEAD ref '$headRef' does not resolve" } else { 'HEAD does not resolve' }
        } elseif (-not $headRef) {
            $health = 'Warning'
            $reason = 'Detached HEAD'
        }

        if ($layout -ne 'standard' -and $health -eq 'OK') {
            $health = 'Warning'
            $reason = 'Non-standard .git layout (gitfile pointer)'
        }

        if (-not $remote -and $health -eq 'OK') {
            $health = 'Warning'
            $reason = 'Missing origin remote'
        }

        # Corruption detection (read-only): fsck
        try {
            $fsckOut = @(git -C $repoPath fsck --no-progress 2>$null)
            if ($LASTEXITCODE -ne 0 -or ($fsckOut -join "\n") -match '(?i)error|fatal') {
                $health = 'Broken'
                $reason = 'git fsck reported issues'
            }
        } catch {
            $health = 'Broken'
            $reason = 'git fsck failed'
        }

        [pscustomobject]@{ Path=$repoPath; ExpectedGitManaged=$expected; Health=$health; Reason=$reason; HeadRef=$headRef; HeadSha=$headSha }
    }

    $results = @($results)

    $scanned = $results.Count
    $ok = @($results | Where-Object Health -eq 'OK').Count
    $warn = @($results | Where-Object Health -eq 'Warning').Count
    $broken = @($results | Where-Object Health -eq 'Broken').Count

    $lines = @(
        'Git Health Summary:',
        "- Repos scanned: $scanned",
        "- OK: $ok",
        "- Warning: $warn",
        "- Broken: $broken",
        'Notes:',
        '- Non-git custom nodes are expected and not errors.',
        '- Disabled clones are treated as quarantined.'
    )

    foreach ($l in $lines) {
        Write-Log $l 'INFO'
        Write-Host $l
    }

    if ($warn -gt 0 -or $broken -gt 0) {
        $detail = $results | Where-Object { $_.Health -ne 'OK' } | Sort-Object Health, Path
        foreach ($d in $detail) {
            $msg = "- $($d.Health): $($d.Path) ($($d.Reason))"
            Write-Log $msg 'INFO'
            Write-Host $msg
        }
    }
}

# --- Paths ---
$modelsPath = Join-Path $ComfyRoot "models"
$nodesPath  = Join-Path $ComfyRoot "custom_nodes"
$venvPython = Join-Path $ComfyRoot "venv\Scripts\python.exe"
$inputPath  = Join-Path $ComfyRoot "input"
$outputPath = Join-Path $ComfyRoot "output"
$logDir     = Join-Path $ComfyRoot "_logs"

Ensure-Dir $OutDir
Ensure-Dir $logDir
$ts = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$base = "comfyui_full_inventory_$ts"

# Deterministic execution log (explicit logger)
$script:LogFile = Join-Path $logDir "$base.log"
Set-Content -LiteralPath $script:LogFile -Encoding UTF8 -Value ""

# Transcript (PowerShell host diagnostic). Use a different extension so it doesn't
# collide with the deterministic *.log execution log.
$transcriptFile = Join-Path $logDir "$base.transcript.txt"

Write-Log "Script start"
Write-Log "ComfyRoot=$ComfyRoot"
Write-Log "OutDir=$OutDir"
Write-Log "ModelsPath=$modelsPath"
Write-Log "CustomNodesPath=$nodesPath"
Write-Log "VenvPython=$venvPython"
Write-Log "LogFile=$script:LogFile"
Write-Log "TranscriptFile=$transcriptFile"

Start-Transcript -LiteralPath $transcriptFile -Force | Out-Null

try {

if ($GitAudit) {
    Invoke-GitAudit -ComfyRoot $ComfyRoot -CustomNodesPath $nodesPath
}

# --- System info ---
$os = Get-CimInstance Win32_OperatingSystem
$gpus = Get-CimInstance Win32_VideoController | Select-Object Name,DriverVersion
Write-Log "Detected OS=$($os.Caption) Build=$($os.BuildNumber)"
Write-Log ("Detected GPUs=" + (($gpus | ForEach-Object { $_.Name }) -join "; "))

# --- ComfyUI git ---
$comfyGit = $null
if(Test-Path "$ComfyRoot\.git"){
    $head = Get-Content "$ComfyRoot\.git\HEAD" -ErrorAction SilentlyContinue
    $comfyGit = $head
}
Write-Log ("ComfyUI git HEAD=" + ($(if ($comfyGit) { $comfyGit } else { '<none>' })))

# --- Python (venv) version ---
$pythonInfo = [ordered]@{ executable = $venvPython; version = $null }
if (Test-Path $venvPython) {
    try {
        $pythonInfo.version = (& $venvPython -c "import sys; print(sys.version.replace('\\n',' '))" 2>&1 | Select-Object -First 1).ToString().Trim()
        Write-Log "Venv Python version=$($pythonInfo.version)"
    } catch {
        Write-Log "Failed to query venv Python version: $($_.Exception.Message)" 'ERROR'
    }
} else {
    Write-Log "Venv Python not found at $venvPython" 'ERROR'
}

# --- pip freeze ---
$pipFreeze = @()
if (Test-Path $venvPython) {
    try {
        $pipFreeze = & $venvPython -m pip freeze
        Write-Log "pip freeze lines=$($pipFreeze.Count)"
    } catch {
        Write-Log "pip freeze failed: $($_.Exception.Message)" 'ERROR'
        $pipFreeze = @()
    }
}

# --- Models ---
$modelExts = ".safetensors",".ckpt",".pt",".pth",".bin",".onnx",".gguf",".yaml",".yml"
$models = @()
if (Test-Path $modelsPath) {
    try {
        $models = Get-ChildItem $modelsPath -Recurse -File |
            Where-Object { $modelExts -contains $_.Extension.ToLower() } |
            ForEach-Object {
                $cat = $_.FullName.Substring($modelsPath.Length).TrimStart("\").Split("\")[0]
                [pscustomobject]@{
                    name = $_.Name
                    ext  = $_.Extension
                    size_mb = [math]::Round($_.Length/1MB,2)
                    category = $cat
                    modified_utc = $_.LastWriteTimeUtc
                    path = $_.FullName
                }
            }
    } catch {
        Write-Log "Model enumeration failed: $($_.Exception.Message)" 'ERROR'
        $models = @()
    }
}
$models = $models | Sort-Object category, path
Write-Log "Models discovered=$($models.Count)"

# --- Model summaries ---
$modelByCat = $models | Group-Object category | ForEach-Object {
    [pscustomobject]@{
        category = $_.Name
        count = $_.Count
        size_mb = [math]::Round(($_.Group | Measure-Object size_mb -Sum).Sum,2)
    }
}
$modelByCat = $modelByCat | Sort-Object category

# --- Custom nodes ---
function Get-GitMeta($p){
    $remote = $null
    $sha = $null
    $dirty = $false
    $isRepo = $false

    if(Test-Path "$p\.git"){
        $isRepo = $true
        try {
            $remote = (git -C $p remote get-url origin 2>$null | Select-Object -First 1)
            if ($null -ne $remote) { $remote = $remote.ToString().Trim() }
        } catch {
            $remote = $null
        }

        try {
            $sha = (git -C $p rev-parse --verify HEAD 2>$null | Select-Object -First 1)
            if ($null -ne $sha) { $sha = $sha.ToString().Trim() }

            $shaIsLiteralHead = ($sha -and $sha.Trim().ToUpperInvariant() -eq 'HEAD')
            $shaLooksLikeRef = ($sha -and $sha.Trim().StartsWith('ref:', [System.StringComparison]::OrdinalIgnoreCase))
            $shaIsValidHash = ($sha -and ($sha -match '^[0-9a-f]{40}$'))

            if ($shaIsLiteralHead -or $shaLooksLikeRef -or -not $shaIsValidHash) {
                $symRef = $null
                $porcelainCount = 0
                try {
                    $symRef = (git -C $p symbolic-ref -q HEAD 2>$null | Select-Object -First 1)
                    if ($null -ne $symRef) { $symRef = $symRef.ToString().Trim() }
                } catch {
                    $symRef = $null
                }
                try {
                    $porcelainCount = @(git -C $p status --porcelain -uno 2>$null).Count
                } catch {
                    $porcelainCount = 0
                }

                Write-Log "Invalid git SHA for $($p) (sha='$sha'); symbolic-ref='$symRef'; status_porcelain_uno_lines=$porcelainCount" 'WARN'
                $sha = $null
            }
        } catch {
            $symRef = $null
            $porcelainCount = 0
            try {
                $symRef = (git -C $p symbolic-ref -q HEAD 2>$null | Select-Object -First 1)
                if ($null -ne $symRef) { $symRef = $symRef.ToString().Trim() }
            } catch {
                $symRef = $null
            }
            try {
                $porcelainCount = @(git -C $p status --porcelain -uno 2>$null).Count
            } catch {
                $porcelainCount = 0
            }

            Write-Log "Git SHA lookup failed for $($p): $($_.Exception.Message); symbolic-ref='$symRef'; status_porcelain_uno_lines=$porcelainCount" 'WARN'
            $sha = $null
        }

        try {
            $statusLines = @(git -C $p status --porcelain 2>$null)
            $dirty = $statusLines.Count -gt 0
        } catch {
            Write-Log "Git dirty check failed for $($p): $($_.Exception.Message)" 'WARN'
            $dirty = $false
        }
    }

    # Always return an object with the same properties (StrictMode-safe).
    return [pscustomobject]@{ is_git_repo = $isRepo; remote = $remote; sha = $sha; dirty = [bool]$dirty }
}

$nodes = @()
if (Test-Path $nodesPath) {
    try {
        $allNodeDirs = @(Get-ChildItem $nodesPath -Directory)
        $nodesIncluded = @(
            $allNodeDirs | Where-Object {
                $_.Name -ne '__pycache__' -and
                $_.Name -ne '.disabled' -and
                -not ($_.Name.StartsWith('.'))
            }
        )

        $excludedCount = $allNodeDirs.Count - $nodesIncluded.Count
        Write-Log "Custom node directories excluded=$excludedCount (filters: __pycache__, .disabled, dot-prefixed)"

        $nodes = $nodesIncluded | ForEach-Object {
            $git = Get-GitMeta $_.FullName
            if ($git.is_git_repo) {
                Write-Log "Node '$($_.Name)' is git repo; remote=$($git.remote) sha=$($git.sha) dirty=$($git.dirty)"
            } else {
                Write-Log "Node '$($_.Name)' is not a git repo" 'WARN'
            }

            [pscustomobject]@{
                name = $_.Name
                path = $_.FullName
                is_git_repo = [bool]$git.is_git_repo
                git_remote = $git.remote
                git_sha = $git.sha
                git_dirty = [bool]$git.dirty
                modified_utc = $_.LastWriteTimeUtc
            }
        }
    } catch {
        Write-Log "Custom node enumeration failed: $($_.Exception.Message)" 'ERROR'
        $nodes = @()
    }
}
$nodes = $nodes | Sort-Object name
Write-Log "Custom nodes discovered=$($nodes.Count)"

# --- Historical note: repo HEAD recovery ---
# If a prior inventory exists and a repo previously had an invalid/missing SHA but now
# resolves to a valid 40-hex hash, emit a single informational log line.
try {
    $prevJson = Get-ChildItem -LiteralPath $OutDir -Filter "comfyui_full_inventory_*.json" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime |
        Select-Object -Last 1

    if ($null -ne $prevJson) {
        $prev = Get-Content -LiteralPath $prevJson.FullName -ErrorAction SilentlyContinue | ConvertFrom-Json
        if ($null -ne $prev -and $null -ne $prev.custom_nodes) {
            $prevShaByPath = @{}
            foreach ($pn in $prev.custom_nodes) {
                if ($pn.path) { $prevShaByPath[$pn.path] = $pn.git_sha }
            }

            foreach ($n in $nodes) {
                if (-not $n.path) { continue }
                $currentSha = $n.git_sha
                if (-not ($currentSha -and ($currentSha -match '^[0-9a-f]{40}$'))) { continue }

                $priorSha = $null
                if ($prevShaByPath.ContainsKey($n.path)) { $priorSha = $prevShaByPath[$n.path] }

                if (-not $priorSha) {
                    Write-Log "Repo '$($n.name)' now resolves valid HEAD after prior invalid state" 'INFO'
                }
            }
        }
    }
} catch {
    # Intentionally silent: historical note is best-effort only.
}

# --- IO snapshot ---
$inputSnap = if(Test-Path $inputPath){
    Get-ChildItem $inputPath -Recurse -File | Measure-Object
}
$outputSnap = if(Test-Path $outputPath){
    Get-ChildItem $outputPath -Recurse -File | Measure-Object
}
Write-Log "IO snapshot: input_files=$($inputSnap.Count) output_files=$($outputSnap.Count)"

# --- JSON ---
$payload = [ordered]@{
    generated_utc = (Get-Date).ToUniversalTime().ToString("o")
    comfyui = [ordered]@{
        root = $ComfyRoot
        git_head = $comfyGit
    }
    python = $pythonInfo
    system = [ordered]@{
        os = $os.Caption
        build = $os.BuildNumber
        gpus = $gpus
    }
    custom_nodes = $nodes
    models = $models
    model_summary = $modelByCat
    pip_freeze = $pipFreeze
    io_snapshot = [ordered]@{
        input_files = $inputSnap.Count
        output_files = $outputSnap.Count
    }
}

$jsonPath = Join-Path $OutDir "$base.json"
$payload | ConvertTo-Json -Depth 8 | Out-File -LiteralPath $jsonPath -Encoding UTF8
Write-Log "Wrote inventory JSON: $jsonPath"

# --- Markdown ---
# Robust writer; avoids a giant here-string for readability.
$mdPath = Join-Path $OutDir "$base.md"

$lines = New-Object System.Collections.Generic.List[string]

$lines.Add("# ComfyUI Full Environment Inventory")
$lines.Add("")
$lines.Add("Generated (UTC): $($payload.generated_utc)")
$lines.Add("")

$lines.Add("## Environment Summary")
$lines.Add("- ComfyUI root: $ComfyRoot")
$lines.Add("- Venv Python: $($pythonInfo.executable)")
$lines.Add("- Python version: $($pythonInfo.version)")
$lines.Add("- Custom nodes dir: $nodesPath")
$lines.Add("- Models dir: $modelsPath")
$lines.Add("")

$lines.Add("## System")
$lines.Add("- OS: $($os.Caption) (Build $($os.BuildNumber))")
$lines.Add("- GPUs:")
foreach ($gpu in $gpus) {
    $lines.Add("  - $($gpu.Name) (Driver $($gpu.DriverVersion))")
}
$lines.Add("")

$lines.Add("## ComfyUI")
$lines.Add("- Root: $ComfyRoot")
$lines.Add("- Git HEAD: $comfyGit")
$lines.Add("")

$lines.Add("## Models")
$lines.Add("Total models: $($models.Count)")
$lines.Add("")
foreach ($cat in ($modelByCat | Sort-Object category)) {
    $lines.Add("- $($cat.category): $($cat.count) models ($($cat.size_mb) MB)")
}
$lines.Add("")

$lines.Add("### Models Table (grouped by category)")
foreach ($catName in ($modelByCat | Select-Object -ExpandProperty category)) {
    $lines.Add("")
    $lines.Add("#### $catName")
    $lines.Add("| Name | Ext | Size (MB) | Path |")
    $lines.Add("| --- | --- | ---: | --- |")
    foreach ($m in ($models | Where-Object { $_.category -eq $catName })) {
        $lines.Add("| $($m.name) | $($m.ext) | $($m.size_mb) | $($m.path) |")
    }
}
$lines.Add("")

$lines.Add("## Custom Nodes")
$lines.Add("Total custom nodes: $($nodes.Count)")
$lines.Add("")
$lines.Add("| Name | Git Repo | Remote | SHA | Dirty | Path |")
$lines.Add("| --- | --- | --- | --- | --- | --- |")
foreach ($n in $nodes) {
    $remote = if ($n.git_remote) { $n.git_remote } else { "" }
    $sha = if ($n.git_sha) { $n.git_sha } else { "" }
    $dirty = if ($null -ne $n.git_dirty) { $n.git_dirty } else { "" }
    $lines.Add("| $($n.name) | $($n.is_git_repo) | $remote | $sha | $dirty | $($n.path) |")
}
$lines.Add("")

$lines.Add("## pip freeze (ComfyUI venv)")
# Use single-quoted backticks to avoid escape parsing issues.
$lines.Add('```')
foreach ($p in $pipFreeze) { $lines.Add($p) }
$lines.Add('```')
$lines.Add("")

$lines.Add("## IO Snapshot")
$lines.Add("- Input files: $($inputSnap.Count)")
$lines.Add("- Output files: $($outputSnap.Count)")
$lines.Add("")

$lines.Add("## Notes")
$lines.Add("- This report reflects the actual local state of this ComfyUI installation.")
$lines.Add("- No assumptions or guesses were made.")
$lines.Add("- The script is read-only; it only writes output artifacts to OutDir and logs to _logs.")
$lines.Add("")

$lines | Out-File -LiteralPath $mdPath -Encoding UTF8

Write-Log "Wrote inventory Markdown: $mdPath"

# --- ComfyUI Copilot context (ready-to-paste prompt) ---
# Keep existing context output, and add FULL + COMPACT variants for better signal-to-noise.
$contextBase = "comfyui_copilot_context_$ts"
$contextPath = Join-Path $OutDir "$contextBase.md"
$contextFullPath = Join-Path $OutDir "$contextBase.full.md"
$contextCompactPath = Join-Path $OutDir "$contextBase.compact.md"

function New-CopilotContextFullLines {
    $ctx = New-Object System.Collections.Generic.List[string]
    $ctx.Add("# ComfyUI Copilot Context (Actual Local Installation)")
    $ctx.Add("")
    $ctx.Add("The following reflects my actual local ComfyUI installation.")
    $ctx.Add("")
    $ctx.Add("## Environment Constraints")
    $ctx.Add("- ComfyUI root: $ComfyRoot")
    $ctx.Add("- Python (venv only): $($pythonInfo.executable)")
    $ctx.Add("- Do NOT use system Python, conda, or create new venvs")
    $ctx.Add("- Custom nodes directory: $nodesPath")
    $ctx.Add("- Models directory: $modelsPath")
    $ctx.Add("")
    $ctx.Add("## Installed Custom Nodes")
    foreach ($n in $nodes) {
        $remote = if ($n.git_remote) { $n.git_remote } else { "" }
        if ($remote) {
            $ctx.Add("- $($n.name) ($remote)")
        } else {
            $ctx.Add("- $($n.name)")
        }
    }
    $ctx.Add("")
    $ctx.Add("## Installed Models (by category)")
    foreach ($catName in ($modelByCat | Select-Object -ExpandProperty category)) {
        $ctx.Add("- $catName")
        foreach ($m in ($models | Where-Object { $_.category -eq $catName })) {
            $ctx.Add("  - $($m.name)")
        }
    }
    $ctx.Add("")
    $ctx.Add("## Instructions for ComfyUI Copilot")
    $ctx.Add("- Assume the above nodes and models already exist locally.")
    $ctx.Add("- Avoid suggesting installations for any listed items.")
    $ctx.Add("- Tailor workflows to this exact environment and available models.")
    $ctx.Add("")
    return $ctx
}

function New-CopilotContextCompactLines {
    $ctx = New-Object System.Collections.Generic.List[string]
    $ctx.Add("# ComfyUI Copilot Context (Compact)")
    $ctx.Add("")
    $ctx.Add("The following reflects my actual local ComfyUI installation.")
    $ctx.Add("")
    $ctx.Add("## Environment Constraints")
    $ctx.Add("- ComfyUI root: $ComfyRoot")
    $ctx.Add("- Python (venv only): $($pythonInfo.executable)")
    $ctx.Add("- Do NOT use system Python, conda, or create new venvs")
    $ctx.Add("")
    $ctx.Add("## Installed Custom Nodes")
    foreach ($n in $nodes) {
        $remote = if ($n.git_remote) { $n.git_remote } else { "" }
        if ($remote) { $ctx.Add("- $($n.name) ($remote)") } else { $ctx.Add("- $($n.name)") }
    }
    $ctx.Add("")
    $ctx.Add("## Models Summary")
    foreach ($cat in $modelByCat) {
        $ctx.Add("- $($cat.category): $($cat.count) models ($($cat.size_mb) MB)")
    }
    $ctx.Add("")
    $ctx.Add("## Instructions for ComfyUI Copilot")
    $ctx.Add("- Assume the above nodes and models already exist locally.")
    $ctx.Add("- Avoid suggesting installations for any listed items.")
    $ctx.Add("- Tailor workflows to this exact environment.")
    $ctx.Add("")
    return $ctx
}

# Existing Copilot context output: keep as-is (same content as FULL)
$fullLines = New-CopilotContextFullLines
$compactLines = New-CopilotContextCompactLines

$fullLines | Out-File -LiteralPath $contextPath -Encoding UTF8
Write-Log "Wrote Copilot context: $contextPath"

$fullLines | Out-File -LiteralPath $contextFullPath -Encoding UTF8
Write-Log "Wrote Copilot context (FULL): $contextFullPath"

$compactLines | Out-File -LiteralPath $contextCompactPath -Encoding UTF8
Write-Log "Wrote Copilot context (COMPACT): $contextCompactPath"

Write-Log "Script completion"

}
finally {
    Stop-Transcript | Out-Null
}
