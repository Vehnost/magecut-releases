param([Parameter(Mandatory=$true)][string]$PluginRoot,[Parameter(Mandatory=$true)][string]$Cache)
$ErrorActionPreference = 'Stop'
$release = Get-Content -LiteralPath (Join-Path $PluginRoot 'release.json') -Raw | ConvertFrom-Json
if ($release.sha256 -notmatch '^[a-f0-9]{64}$' -or $release.version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid release metadata' }
$Cache = [IO.Path]::GetFullPath($Cache)
$destination = Join-Path $Cache $release.sha256
$stateFile = Join-Path $Cache ($release.sha256 + '.status.json')
$archive = Join-Path $Cache ($release.sha256 + '.zip.part')
$lock = $null
function Set-State($phase, $message='', $attempt=0) {
    $value = @{phase=$phase;ready=$false;totalBytes=$release.bytes;attempt=$attempt;message=$message} | ConvertTo-Json -Compress
    $temporary = $stateFile + '.' + $PID + '.tmp'
    [IO.File]::WriteAllText($temporary,$value)
    Move-Item -LiteralPath $temporary -Destination $stateFile -Force
}
try {
    New-Item -ItemType Directory -Path $Cache -Force | Out-Null
    try { $lock = [IO.File]::Open((Join-Path $Cache ($release.sha256 + '.lock')),'OpenOrCreate','ReadWrite','None') } catch { exit 0 }
    $marker = Join-Path $destination '.verified'
    if ((Test-Path -LiteralPath $marker) -and (Get-Content -LiteralPath $marker -Raw) -eq $release.sha256) { Set-State 'installed'; exit 0 }
    $url = [Uri]$release.url
    $testHttp = $env:MAGECUT_TEST_HTTP -eq '1' -and $url.IsLoopback
    if ($url.Scheme -ne 'https' -and -not $testHttp) { throw 'Release requires HTTPS' }
    $downloaded = $false
    for ($attempt=1; $attempt -le 30; $attempt++) {
        if ((Test-Path -LiteralPath $archive) -and (Get-Item -LiteralPath $archive).Length -eq $release.bytes) { $downloaded=$true; break }
        Set-State 'downloading' 'Resuming download; partial data is preserved across restarts.' $attempt
        $curlArgs = @('--location','--fail','--silent','--show-error','--connect-timeout','20','--max-time','120','--speed-time','30','--speed-limit','1024','--continue-at','-','--output',$archive)
        if (-not $testHttp) { $curlArgs += @('--proto','=https','--proto-redir','=https') }
        $ErrorActionPreference = 'Continue'
        & curl.exe @curlArgs $release.url 2>> (Join-Path $Cache 'download.log')
        $downloadExit = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        if ($downloadExit -eq 0 -and (Test-Path -LiteralPath $archive) -and (Get-Item -LiteralPath $archive).Length -eq $release.bytes) { $downloaded=$true; break }
        Set-State 'retrying' 'Connection interrupted. Download will continue from saved bytes.' $attempt
        Start-Sleep -Seconds ([Math]::Min($attempt*2,15))
    }
    if (-not $downloaded) { throw 'Download paused after 30 attempts. Reopen the task to resume saved progress.' }
    Set-State 'verifying'
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($archive)
    try { $actualHash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant() } finally { $stream.Dispose(); $sha.Dispose() }
    if ($actualHash -ne $release.sha256) {
        Move-Item -LiteralPath $archive -Destination ($archive + '.invalid-' + [guid]::NewGuid().ToString('N'))
        throw 'SHA-256 mismatch. Nothing executed. Reopen the task to download a fresh copy.'
    }
    Set-State 'extracting'
    $staging = Join-Path $Cache ('unpack-' + [guid]::NewGuid().ToString('N'))
    & (Join-Path $PluginRoot 'scripts\extract.ps1') -Archive $archive -Destination $staging
    $package = Join-Path $staging ('magecut-local-windows-' + $release.version)
    $metadata = Get-Content -LiteralPath (Join-Path $package 'package-info.json') -Raw | ConvertFrom-Json
    if ($metadata.version -ne $release.version -or $metadata.platform -ne 'win32' -or $metadata.arch -ne 'x64') { throw 'Unexpected editor package' }
    [IO.File]::WriteAllText((Join-Path $package '.verified'),$release.sha256)
    if (Test-Path -LiteralPath $destination) { throw 'Unverified installation already exists; cannot overwrite it.' }
    $resolvedPackage=(Resolve-Path -LiteralPath $package).ProviderPath
    if (-not $resolvedPackage.StartsWith($Cache + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected extraction path' }
    Move-Item -LiteralPath $resolvedPackage -Destination $destination
    if ([IO.Path]::GetDirectoryName($staging) -ne $Cache) { throw 'Unexpected staging path' }
    Remove-Item -LiteralPath $staging -Recurse -Force
    Remove-Item -LiteralPath $archive
    Set-State 'installed'
} catch { Set-State 'failed' $_.Exception.Message; exit 1 }
finally { if ($lock) { $lock.Dispose() } }
