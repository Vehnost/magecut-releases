param([Parameter(Mandatory=$true)][string]$Archive,[Parameter(Mandatory=$true)][string]$Destination)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$targetRoot = [IO.Path]::GetFullPath($Destination)
$archiveFile = [IO.Compression.ZipFile]::OpenRead($Archive)
try {
    foreach ($entry in $archiveFile.Entries) {
        $entryPath = [IO.Path]::GetFullPath((Join-Path $targetRoot $entry.FullName))
        if (-not $entryPath.StartsWith($targetRoot + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Archive path escapes destination' }
    }
} finally { $archiveFile.Dispose() }
[IO.Compression.ZipFile]::ExtractToDirectory($Archive,$targetRoot)
