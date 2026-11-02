<#
.SYNOPSIS
    Bundles LibNodeGraph (and, for dev zips, its required plugin dependencies) into a zip.

.DESCRIPTION
    Stages the same "core" file set as .vscode/deploy.ps1: plugin.json (if present),
    every file under resources/, and every *.lua file outside
    tests/docs/.git/.vscode/staging/scripts.
    Lua files are naively stripped: drop whole-line -- comments (including simple
    --[[ ... ]] blocks) and inline trailing -- comments; -- inside quoted/long
    strings is preserved. With -Minify, LibNodeGraph Lua is rewritten by scripts/minify.lua instead of the naive stripper.

    Default (dev) layout mirrors the live client: one top-level folder per plugin
    (LibNodeGraph/, …). Required dependencies are an identifier-to-folder
    map; this script stages the folder names and does not invent numeric ids.

    With -Modio: LibNodeGraph files only, no dependency folders, zip entries at the
    archive root (main.lua, plugin.json, …). plugin.modio.json is staged as
    plugin.json. Default filename is
    LibNodeGraph-<version>-modio.zip so it does not collide with the dev zip.

.PARAMETER Output
    Path for the output zip. Defaults to LibNodeGraph-<version>.zip (dev) or
    LibNodeGraph-<version>-modio.zip (-Modio) beside this script, where <version>
    comes from the manifest in use.

.PARAMETER Minify
    Minify staged LibNodeGraph Lua via scripts/minify.lua instead of naive comment stripping.

.PARAMETER Modio
    Produce a mod.io zip: LibNodeGraph-only, flat layout, plugin.modio.json as plugin.json.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File bundle.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File bundle.ps1 -Output dist/LibNodeGraph-custom.zip
    powershell -NoProfile -ExecutionPolicy Bypass -File bundle.ps1 -Minify
    powershell -NoProfile -ExecutionPolicy Bypass -File bundle.ps1 -Modio
#>
param(
    [string]$Output,
    [switch]$Minify,
    [switch]$Modio
)

$ErrorActionPreference = 'Stop'

$pluginDir = $PSScriptRoot
$rs3Root = Split-Path -Parent $pluginDir
$pluginName = 'LibNodeGraph'
$pruneSegments = @('tests', 'docs', '.git', '.vscode', 'staging', 'scripts')
$minifyPlugins = @('LibNodeGraph')

function Test-Pruned {
    param([string]$RelativePath)
    $segments = $RelativePath -split '[\\/]'
    foreach ($seg in $segments) {
        if ($pruneSegments -contains $seg) { return $true }
    }
    return $false
}

function Get-PluginDeployFiles {
    param([string]$SrcDir)

    $files = New-Object System.Collections.Generic.List[string]
    $prefix = $SrcDir.TrimEnd('\', '/') + '\'

    $pluginJson = Join-Path $SrcDir 'plugin.json'
    if (Test-Path -LiteralPath $pluginJson -PathType Leaf) { $files.Add('plugin.json') }

    $resources = Join-Path $SrcDir 'resources'
    if (Test-Path -LiteralPath $resources -PathType Container) {
        Get-ChildItem -LiteralPath $resources -Recurse -File | ForEach-Object {
            $rel = $_.FullName.Substring($prefix.Length)
            $files.Add($rel)
        }
    }

    Get-ChildItem -LiteralPath $SrcDir -Recurse -File -Filter *.lua | ForEach-Object {
        $rel = $_.FullName.Substring($prefix.Length)
        if (-not (Test-Pruned $rel)) { $files.Add($rel) }
    }

    return $files
}

function Remove-InlineLuaComment {
    param([string]$Line)

    $len = $Line.Length
    $i = 0
    $sb = New-Object System.Text.StringBuilder

    while ($i -lt $len) {
        $c = $Line[$i]

        if ($c -eq "'" -or $c -eq '"') {
            $quote = $c
            [void]$sb.Append($c)
            $i++
            while ($i -lt $len) {
                $ch = $Line[$i]
                [void]$sb.Append($ch)
                if ($ch -eq '\' -and ($i + 1) -lt $len) {
                    $i++
                    [void]$sb.Append($Line[$i])
                }
                elseif ($ch -eq $quote) {
                    break
                }
                $i++
            }
            $i++
            continue
        }

        if ($c -eq '[' -and ($i + 1) -lt $len) {
            $eq = 0
            $j = $i + 1
            while ($j -lt $len -and $Line[$j] -eq '=') { $eq++; $j++ }
            if ($j -lt $len -and $Line[$j] -eq '[') {
                $open = $Line.Substring($i, $j - $i + 1)
                $close = ']' + ('=' * $eq) + ']'
                $rest = $Line.Substring($j + 1)
                $end = $rest.IndexOf($close)
                if ($end -ge 0) {
                    [void]$sb.Append($open)
                    [void]$sb.Append($rest.Substring(0, $end + $close.Length))
                    $i = $j + 1 + $end + $close.Length
                    continue
                }
            }
        }

        if ($c -eq '-' -and ($i + 1) -lt $len -and $Line[$i + 1] -eq '-') {
            if (($i + 2) -lt $len -and $Line[$i + 2] -eq '[') {
                $eq = 0
                $j = $i + 3
                while ($j -lt $len -and $Line[$j] -eq '=') { $eq++; $j++ }
                if ($j -lt $len -and $Line[$j] -eq '[') {
                    $close = ']' + ('=' * $eq) + ']'
                    $rest = $Line.Substring($j + 1)
                    $end = $rest.IndexOf($close)
                    if ($end -ge 0) {
                        $i = $j + 1 + $end + $close.Length
                        continue
                    }
                }
            }
            break
        }

        [void]$sb.Append($c)
        $i++
    }

    return $sb.ToString().TrimEnd()
}

function Invoke-MinifyLua {
    param(
        [string]$Src,
        [string]$Dst,
        [string]$RelativePath
    )

    $minifyScript = Join-Path $pluginDir 'scripts\minify.lua'
    if (-not (Test-Path -LiteralPath $minifyScript -PathType Leaf)) {
        throw "Missing minify script: $minifyScript"
    }

    $lua = Get-Command lua -ErrorAction SilentlyContinue
    if (-not $lua) {
        throw "lua is not on PATH; required for -Minify"
    }

    $quote = {
        param([string]$Value)
        '"' + ($Value -replace '"', '\"') + '"'
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $lua.Source
    $psi.Arguments = (& $quote $minifyScript) + ' minify ' + (& $quote $Src)
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding $false
    $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding $false

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()

    if ($proc.ExitCode -ne 0) {
        throw "minify.lua failed for $RelativePath (exit $($proc.ExitCode)): $stderr"
    }

    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Dst, $stdout, $utf8)
}

function Copy-BundledFile {
    param(
        [string]$Src,
        [string]$Dst,
        [string]$RelativePath,
        [switch]$Minify
    )

    New-Item -ItemType Directory -Path (Split-Path -Parent $Dst) -Force | Out-Null

    if ($RelativePath -like '*.lua') {
        if ($Minify) {
            Invoke-MinifyLua -Src $Src -Dst $Dst -RelativePath $RelativePath
            return
        }

        $text = [System.IO.File]::ReadAllText($Src)
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($Dst, $text, $utf8)
        return
    }

    Copy-Item -LiteralPath $Src -Destination $Dst -Force
}

function Stage-Plugin {
    param(
        [string]$Name,
        [string]$StageRoot,
        [switch]$Minify,
        [switch]$Flat
    )

    $srcDir = Join-Path $rs3Root $Name
    if (-not (Test-Path -LiteralPath $srcDir -PathType Container)) {
        throw "Dependency folder not found: $srcDir"
    }

    $files = Get-PluginDeployFiles $srcDir
    if ($files.Count -eq 0) {
        throw "No deployable files found for '$Name'."
    }

    foreach ($rel in $files) {
        $src = Join-Path $srcDir $rel
        # mod.io zip uses plugin.modio.json as the on-disk plugin.json
        if ($Flat -and ($rel -eq 'plugin.json')) {
            $modioManifest = Join-Path $srcDir 'plugin.modio.json'
            if (-not (Test-Path -LiteralPath $modioManifest -PathType Leaf)) {
                throw "Missing plugin.modio.json at $modioManifest"
            }
            $src = $modioManifest
        }
        $dstRel = if ($Flat) { $rel } else { Join-Path $Name $rel }
        $dst = Join-Path $StageRoot $dstRel
        Copy-BundledFile -Src $src -Dst $dst -RelativePath $rel -Minify:$Minify
    }

    return $files.Count
}

$manifestName = if ($Modio) { 'plugin.modio.json' } else { 'plugin.json' }
$manifestPath = Join-Path $pluginDir $manifestName
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Missing $manifestName at $manifestPath"
}

# Folder names from requiredDependencies (identifier -> folder). Numeric hub ids are skipped.
function Get-RequiredFolderNames {
    param($Deps)
    $names = @()
    if ($null -eq $Deps) { return $names }
    foreach ($prop in $Deps.PSObject.Properties) {
        if ($prop.Value -is [string] -and $prop.Value -ne '') {
            $names += $prop.Value
        }
    }
    return $names
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$plugins = @()
if (-not $Modio) {
    $plugins += @(Get-RequiredFolderNames $manifest.requiredDependencies)
}
$plugins += $pluginName
$plugins = $plugins | Select-Object -Unique

$stage = Join-Path ([System.IO.Path]::GetTempPath()) ("libnodegraph-bundle-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage -Force | Out-Null

try {
    $totalFiles = 0
    foreach ($name in $plugins) {
        $minifyThis = $Minify -and ($minifyPlugins -contains $name)
        $count = Stage-Plugin -Name $name -StageRoot $stage -Minify:$minifyThis -Flat:$Modio
        $totalFiles += $count
        Write-Host "  $name  ($count files)"
    }

    if (-not $Output) {
        $version = if ($manifest.version) { $manifest.version } else { 'unknown' }
        $suffix = if ($Modio) { '-modio' } else { '' }
        $Output = Join-Path $pluginDir "LibNodeGraph-$version$suffix.zip"
    }
    $Output = [System.IO.Path]::GetFullPath($Output)
    $outDir = Split-Path -Parent $Output
    if ($outDir -and -not (Test-Path -LiteralPath $outDir -PathType Container)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }
    if (Test-Path -LiteralPath $Output -PathType Leaf) {
        $answer = Read-Host "Output file already exists:`n  $Output`nOverwrite? [y/N]"
        if ($answer -notmatch '^[Yy]') {
            Write-Host 'Bundle cancelled.' -ForegroundColor Yellow
            exit 1
        }
        Remove-Item -LiteralPath $Output -Force
    }

    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $Output -CompressionLevel Optimal
    Write-Host "Bundled $($plugins.Count) plugins ($totalFiles files) -> $Output" -ForegroundColor Green
}
finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}

exit 0
