[CmdletBinding()]
param(
	[string]$Manifest = "B:\ComfyUI\_manifests\comfyui_model_manifest.csv",
	[string]$ModelsRoot = "B:\ComfyUI\models",
	[string]$StagingRoot = "B:\ComfyUI\_staging\models",
	[switch]$VerifyHashes,
	[switch]$ContinueOnError,
	[switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Dir([string]$Path) {
	if (-not (Test-Path -LiteralPath $Path)) {
		New-Item -ItemType Directory -Force -Path $Path | Out-Null
	}
}

function Write-Log([string]$Message) {
	$Message | Tee-Object -FilePath $script:LogPath -Append | Out-Null
}

function Get-AuthHeader([Uri]$Uri) {
	$urlHost = $Uri.Host.ToLowerInvariant()
	if ($urlHost -like "*huggingface.co" -and -not [string]::IsNullOrWhiteSpace($env:HF_TOKEN)) {
		return "Authorization: Bearer $($env:HF_TOKEN)"
	}
	if ($urlHost -like "*civitai.com" -and -not [string]::IsNullOrWhiteSpace($env:CIVITAI_TOKEN)) {
		return "Authorization: Bearer $($env:CIVITAI_TOKEN)"
	}
	if (($urlHost -like "*github.com" -or $urlHost -like "*api.github.com" -or $urlHost -like "*objects.githubusercontent.com") -and -not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
		return "Authorization: Bearer $($env:GITHUB_TOKEN)"
	}
	return $null
}

if (-not (Test-Path -LiteralPath $Manifest)) { throw "Manifest not found: $Manifest" }
Ensure-Dir $StagingRoot
Ensure-Dir "B:\ComfyUI\_logs"

$rows = Import-Csv -LiteralPath $Manifest
$script:LogPath = "B:\ComfyUI\_logs\download_models_{0}.log" -f (Get-Date -Format "yyyy-MM-dd_HH-mm-ss")

$total = 0
$installed = 0
$skippedExists = 0
$wouldDownload = 0
$failed = 0

Write-Log "Manifest: $Manifest"
Write-Log "ModelsRoot: $ModelsRoot"
Write-Log "StagingRoot: $StagingRoot"
if ($DryRun) { Write-Log "Mode: DRY RUN (no downloads, no file writes)" }

foreach ($row in $rows) {
	if (-not $row.url -or -not $row.dest_relative) { continue }
	$total++

	$destFinal = Join-Path $ModelsRoot $row.dest_relative
	$destStage = Join-Path $StagingRoot $row.dest_relative

	if (-not $DryRun) {
		Ensure-Dir (Split-Path -Parent $destStage)
		Ensure-Dir (Split-Path -Parent $destFinal)
	}

	if (Test-Path -LiteralPath $destFinal) {
		$skippedExists++
		Write-Log "SKIP (exists): $destFinal"
		continue
	}

	if ($DryRun) {
		$wouldDownload++
		Write-Log "DRYRUN WOULD DOWNLOAD: $($row.url) -> $destFinal"
		continue
	}

	try {
		if (Test-Path -LiteralPath $destStage) { Remove-Item -LiteralPath $destStage -Force }
		$uri = [Uri]$row.url
		$header = Get-AuthHeader -Uri $uri
		$curlArgs = @("-L", "--fail", "--retry", "3", "--retry-delay", "2", "-o", $destStage)
		if ($header) { $curlArgs += @("-H", $header) }
		$curlArgs += $row.url

		Write-Log "DOWNLOADING: $($row.url) -> $destStage"
		& curl.exe @curlArgs

		if (-not (Test-Path -LiteralPath $destStage)) { throw "Download failed: $destStage" }

		if ($VerifyHashes -and $row.sha256) {
			$actual = (Get-FileHash -LiteralPath $destStage -Algorithm SHA256).Hash.ToLowerInvariant()
			$expected = $row.sha256.ToLowerInvariant().Trim()
			if ($actual -ne $expected) {
				throw "HASH MISMATCH: $destStage`nExpected: $expected`nActual:   $actual"
			}
		}

		Move-Item -LiteralPath $destStage -Destination $destFinal -Force
		$installed++
		Write-Log "INSTALLED: $destFinal"
	}
	catch {
		if (Test-Path -LiteralPath $destStage) { Remove-Item -LiteralPath $destStage -Force }
		$failed++
		Write-Log "FAILED: $destFinal`n$($_.Exception.Message)"
		if (-not $ContinueOnError) { throw }
	}
}

Write-Log "SUMMARY total=$total installed=$installed would_download=$wouldDownload skipped_exists=$skippedExists failed=$failed"
