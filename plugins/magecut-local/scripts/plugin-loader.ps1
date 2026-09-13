$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$pluginRoot = Split-Path $PSScriptRoot -Parent
$release = Get-Content -LiteralPath (Join-Path $pluginRoot 'release.json') -Raw | ConvertFrom-Json
$catalog = Get-Content -LiteralPath (Join-Path $pluginRoot 'catalog.json') -Raw | ConvertFrom-Json
$cache = if ($env:MAGECUT_CACHE) { [IO.Path]::GetFullPath($env:MAGECUT_CACHE) } else { Join-Path $env:LOCALAPPDATA 'MagecutLocal\marketplace' }
$destination = Join-Path $cache $release.sha256
$stateFile = Join-Path $cache ($release.sha256 + '.status.json')
$backend = $null
function Write-Reply($id, $result) {
    [Console]::WriteLine((@{jsonrpc='2.0';id=$id;result=$result} | ConvertTo-Json -Depth 100 -Compress))
}
function Read-BackendReply($id) {
    while ($true) {
        $pending = $script:backend.StandardOutput.ReadLineAsync()
        if (-not $pending.Wait(185000)) { throw 'Editor response timed out' }
        $line = $pending.Result
        if ($null -eq $line) { throw 'Editor disconnected' }
        $reply = $line | ConvertFrom-Json
        if ($reply.PSObject.Properties['id'] -and $reply.id -eq $id) { return $reply }
    }
}
function Connect-Editor {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $destination 'bin\node.exe'
    $entry = Join-Path $destination 'scripts\start.cjs'
    $info.Arguments = '"' + $entry + '"'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $info.EnvironmentVariables['MAGECUT_PORT'] = $(if ($env:MAGECUT_PORT) { $env:MAGECUT_PORT } else { '14340' })
    $script:backend = [Diagnostics.Process]::Start($info)
    $script:backend.StandardInput.WriteLine('{"jsonrpc":"2.0","id":"loader-init","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"magecut-loader","version":"0.3.0"}}}')
    $response = Read-BackendReply 'loader-init'
    if ($response.error) { throw 'Editor initialization failed' }
    $script:backend.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}')
}
New-Item -ItemType Directory -Path $cache -Force | Out-Null
$workerArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot 'plugin-install.ps1') + '" -PluginRoot "' + $pluginRoot + '" -Cache "' + $cache + '"'
$worker = Start-Process -FilePath powershell.exe -ArgumentList $workerArgs -WindowStyle Hidden -PassThru
try {
    while ($null -ne ($line = [Console]::ReadLine())) {
        try {
            $request = $line | ConvertFrom-Json
            if (-not $request.PSObject.Properties['id']) { continue }
            $method = $request.method
            if ($method -eq 'initialize') {
                Write-Reply $request.id @{protocolVersion=$request.params.protocolVersion;serverInfo=@{name='magecut-local';version='0.3.0'};capabilities=@{tools=@{};resources=@{}};instructions='Call magecut_status. Installation downloads the editor with automatic retries and resume. Poll status every 10 seconds until editorUrl appears, then open it in the browser and keep the tab open. Read the skill and use current project revisions.'}
                continue
            }
            if ($method -eq 'ping') { Write-Reply $request.id @{}; continue }
            if ($method -eq 'tools/list') { Write-Reply $request.id @{tools=$catalog.tools}; continue }
            if ($method -eq 'resources/templates/list') { Write-Reply $request.id @{resourceTemplates=@()}; continue }
            $marker = Join-Path $destination '.verified'
            $installed = (Test-Path -LiteralPath $marker) -and ((Get-Content -LiteralPath $marker -Raw) -eq $release.sha256)
            if ($installed -and -not $backend) { Connect-Editor }
            if ($backend) {
                $backend.StandardInput.WriteLine($line)
                $reply = Read-BackendReply $request.id
                [Console]::WriteLine(($reply | ConvertTo-Json -Depth 100 -Compress))
            } elseif ($method -eq 'resources/list') { Write-Reply $request.id @{resources=@()} }
            elseif ($method -eq 'tools/call') {
                $state = @{phase='starting';ready=$false;totalBytes=$release.bytes}
                try { $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json } catch {}
                $partial = Join-Path $cache ($release.sha256 + '.zip.part')
                if (Test-Path -LiteralPath $partial) { $state | Add-Member -NotePropertyName downloadedBytes -NotePropertyValue (Get-Item -LiteralPath $partial).Length -Force }
                $result = @{content=@(@{type='text';text=($state | ConvertTo-Json -Depth 15 -Compress)})}
                if ($request.params.name -ne 'magecut_status') { $result.isError = $true }
                Write-Reply $request.id $result
            } else { [Console]::WriteLine((@{jsonrpc='2.0';id=$request.id;error=@{code=-32601;message='Method not available during setup'}} | ConvertTo-Json -Compress)) }
        } catch {
            [Console]::WriteLine((@{jsonrpc='2.0';id=$request.id;error=@{code=-32603;message=$_.Exception.Message}} | ConvertTo-Json -Compress))
        }
    }
} finally {
    if ($backend) { $backend.StandardInput.Close(); if (-not $backend.WaitForExit(5000)) { $backend.Kill() }; $backend.Dispose() }
    # The independent installer can finish a verified download after the task closes.
}
