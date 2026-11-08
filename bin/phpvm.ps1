# phpvm - PHP version + extension manager for Windows (PowerShell 5.1+)
# Usage: phpvm help
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root       = if ($env:PHPVM_HOME) { $env:PHPVM_HOME } else { Join-Path $env:USERPROFILE '.php' }
$Bin        = Join-Path $Root 'bin'
$Versions   = Join-Path $Root 'versions'
$Current    = Join-Path $Root 'current'
$Cache      = Join-Path $Root 'cache'
$ConfigFile = Join-Path $Root 'config.json'

$ReleasesBase = 'https://windows.php.net/downloads/releases'
$PeclBase     = 'https://downloads.php.net/~windows/pecl/releases'
$ZendExts     = @('opcache', 'xdebug')
$DefaultExts  = @('curl', 'fileinfo', 'mbstring', 'openssl', 'pdo_mysql', 'pdo_sqlite', 'mysqli', 'sqlite3', 'zip', 'intl', 'gd', 'exif')

Add-Type -AssemblyName System.IO.Compression.FileSystem

# ---------------------------------------------------------------- helpers
function Say($m)  { Write-Host $m }
function Ok($m)   { Write-Host $m -ForegroundColor Green }
function Warn($m) { Write-Host "warning: $m" -ForegroundColor Yellow }

function Ensure-Dirs { foreach ($d in $Root, $Bin, $Versions, $Cache) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d | Out-Null } } }

function Read-Config {
    if (Test-Path -LiteralPath $ConfigFile) { return (Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json) }
    return [pscustomobject]@{ last = $null }
}
function Save-Config($cfg) { Ensure-Dirs; ($cfg | ConvertTo-Json) | Set-Content -LiteralPath $ConfigFile -Encoding UTF8 }

function Get-ActiveName {
    $item = Get-Item -LiteralPath $Current -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $null }
    $t = $item.Target
    if ($t -is [array]) { $t = $t[0] }
    if ($t) { return (Split-Path $t -Leaf) }
    return $null
}

function Remove-Junction {
    $item = Get-Item -LiteralPath $Current -Force -ErrorAction SilentlyContinue
    if ($item) { [IO.Directory]::Delete($Current, $false) }
}
function Set-Junction($name) {
    Remove-Junction
    New-Item -ItemType Junction -Path $Current -Target (Join-Path $Versions $name) | Out-Null
}

function Get-InstalledNames {
    if (-not (Test-Path -LiteralPath $Versions)) { return @() }
    $names = Get-ChildItem -LiteralPath $Versions -Directory | Where-Object { $_.Name -match '^\d+\.\d+\.\d+' -and $_.Name -notlike '.tmp*' } | ForEach-Object { $_.Name }
    return @($names | Sort-Object { [version]($_ -replace '^(\d+\.\d+\.\d+).*', '$1') }, { if ($_ -like '*-nts-x64') { 1 } else { 0 } } -Descending)
}

function Resolve-Installed($spec) {
    $all = Get-InstalledNames
    $m = @($all | Where-Object { $_ -eq $spec -or $_ -like "$spec.*" -or $_ -like "$spec-*" })
    if ($m.Count -eq 0) { throw "version '$spec' not installed (see: phpvm list)" }
    return $m[0]
}

function Get-Target {
    if ($Opt['version']) { return (Resolve-Installed $Opt['version']) }
    $a = Get-ActiveName
    if (-not $a) { throw 'no active PHP version; run: phpvm use <version> (or pass --version <v>)' }
    return $a
}

function Get-Meta($name) {
    $f = Join-Path (Join-Path $Versions $name) '.phpvm.json'
    if (Test-Path -LiteralPath $f) { return (Get-Content -LiteralPath $f -Raw | ConvertFrom-Json) }
    $v = $name -replace '^(\d+\.\d+\.\d+).*', '$1'
    return [pscustomobject]@{ version = $v; ts = ($name -notlike '*-nts-*'); arch = $(if ($name -like '*x86') { 'x86' } else { 'x64' }); vs = 'vs16' }
}

function Download-File($url, $out) {
    $part = "$out.part"
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $part
    Move-Item -LiteralPath $part -Destination $out -Force
}

function Expand-ZipSafe($zipFile, $dest) {
    $destFull = [IO.Path]::GetFullPath($dest).TrimEnd('\')
    New-Item -ItemType Directory -Path $destFull -Force | Out-Null
    $zip = [IO.Compression.ZipFile]::OpenRead($zipFile)
    try {
        foreach ($e in $zip.Entries) {
            $target = [IO.Path]::GetFullPath((Join-Path $destFull $e.FullName))
            if (-not $target.StartsWith($destFull + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "unsafe path in zip: $($e.FullName)" }
            if ($e.FullName.EndsWith('/')) { New-Item -ItemType Directory -Path $target -Force | Out-Null; continue }
            $parent = Split-Path $target -Parent
            if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
        }
    } finally { $zip.Dispose() }
}

function Test-Sha256($file, $expected) {
    if (-not $expected) { return $true }
    return ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -eq $expected.ToUpper())
}

# ---------------------------------------------------------------- PATH (registry)
function Add-UserPath([string[]]$dirs) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    try {
        $cur = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $parts = New-Object 'System.Collections.Generic.List[string]'
        foreach ($p in ($cur -split ';')) { if ($p) { $parts.Add($p) } }
        $changed = $false
        [array]::Reverse($dirs)
        foreach ($d in $dirs) {
            $exists = $parts | Where-Object { $_.TrimEnd('\') -ieq $d.TrimEnd('\') }
            if (-not $exists) { $parts.Insert(0, $d); $changed = $true }
        }
        if ($changed) {
            $key.SetValue('Path', ($parts -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
            Add-Type -Namespace PhpvmWin -Name Native -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true, CharSet=System.Runtime.InteropServices.CharSet.Auto)] public static extern System.IntPtr SendMessageTimeout(System.IntPtr h, uint m, System.UIntPtr w, string l, uint f, uint t, out System.UIntPtr r);'
            $r = [UIntPtr]::Zero
            [void][PhpvmWin.Native]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$r)
        }
        return $changed
    } finally { $key.Close() }
}

# ---------------------------------------------------------------- php.ini editing
function Read-Ini($path) {
    $text = [IO.File]::ReadAllText($path)
    $eol = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $list = New-Object 'System.Collections.Generic.List[string]'
    $list.AddRange([string[]]($text -split "\r?\n"))
    return @{ Lines = $list; Eol = $eol }
}
function Write-Ini($path, $ini, [bool]$backup = $true) {
    if ($backup -and (Test-Path -LiteralPath $path)) { Copy-Item -LiteralPath $path -Destination "$path.bak" -Force }
    [IO.File]::WriteAllText($path, ($ini.Lines -join $ini.Eol), (New-Object Text.UTF8Encoding $false))
}

function Set-IniLine($lines, $key, $value) {
    $k = [regex]::Escape($key)
    $act = -1; $com = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($act -lt 0 -and $l -match "^\s*$k\s*=") { $act = $i }
        elseif ($com -lt 0 -and $l -match "^;\s*$k\s*=") { $com = $i }
    }
    $new = "$key = $value"
    if ($act -ge 0) { $lines[$act] = $new }
    elseif ($com -ge 0) { $lines[$com] = $new }
    elseif ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines.Insert($lines.Count - 1, $new) }
    else { $lines.Add($new) }
}
function Get-IniLine($lines, $key) {
    $k = [regex]::Escape($key)
    foreach ($l in $lines) { if ($l -match "^\s*$k\s*=\s*(.*)$") { return $Matches[1].Trim() } }
    return $null
}
function Unset-IniLine($lines, $key) {
    $k = [regex]::Escape($key); $n = 0
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match "^\s*$k\s*=") { $lines[$i] = ';' + $lines[$i]; $n++ } }
    return $n
}

# parse an extension/zend_extension line -> @{Name; Active; Directive} or $null
function Parse-ExtLine($line) {
    if ($line -match '^\s*(;?)\s*(zend_extension|extension)\s*=\s*"?([^"\s;]+)"?') {
        $n = ([IO.Path]::GetFileName($Matches[3]) -replace '^php_', '' -replace '\.dll$', '').ToLower()
        return @{ Name = $n; Active = ($Matches[1] -eq ''); Directive = $Matches[2] }
    }
    return $null
}
function Enable-IniExt($lines, $name) {
    $name = $name.ToLower(); $com = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $p = Parse-ExtLine $lines[$i]
        if ($p -and $p.Name -eq $name) {
            if ($p.Active) { return 'already' }
            if ($com -lt 0) { $com = $i }
        }
    }
    if ($com -ge 0) { $lines[$com] = $lines[$com] -replace '^\s*;\s*', ''; return 'enabled' }
    $dir = if ($ZendExts -contains $name) { 'zend_extension' } else { 'extension' }
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines.Insert($lines.Count - 1, "$dir=$name") } else { $lines.Add("$dir=$name") }
    return 'enabled'
}
function Disable-IniExt($lines, $name) {
    $name = $name.ToLower(); $n = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $p = Parse-ExtLine $lines[$i]
        if ($p -and $p.Active -and $p.Name -eq $name) { $lines[$i] = ';' + $lines[$i].TrimStart(); $n++ }
    }
    return $n
}

# ---------------------------------------------------------------- running php
function Invoke-Php($dir, $argString) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $dir 'php.exe'
    $psi.Arguments = $argString
    $psi.WorkingDirectory = $dir
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    $o = $p.StandardOutput.ReadToEnd(); $e = $p.StandardError.ReadToEnd(); $p.WaitForExit()
    return [pscustomobject]@{ Out = $o; Err = $e; Code = $p.ExitCode }
}
function Test-PhpHealthy($dir) {
    $r = Invoke-Php $dir '-r "echo \"ok\";"'
    $text = ($r.Out + $r.Err).Trim()
    if ($r.Code -eq -1073741515) { return @{ Ok = $false; Msg = 'php.exe cannot start: Visual C++ Redistributable missing (run: phpvm doctor)' } }
    if ($r.Code -ne 0 -or $text -ne 'ok') { return @{ Ok = $false; Msg = $text } }
    return @{ Ok = $true; Msg = '' }
}
# write ini, verify php still starts; restore backup on failure
function Commit-Ini($dir, $iniPath, $ini) {
    Write-Ini $iniPath $ini
    $h = Test-PhpHealthy $dir
    if (-not $h.Ok) {
        Copy-Item -LiteralPath "$iniPath.bak" -Destination $iniPath -Force
        $short = (($h.Msg -split "\r?\n") | Where-Object { $_ } | Select-Object -First 3) -join "`n"
        throw "php failed to start with new php.ini (change reverted):`n$short"
    }
}

# ---------------------------------------------------------------- remote versions
function Get-Releases {
    Ensure-Dirs
    $f = Join-Path $Cache 'releases.json'
    $stale = (-not (Test-Path -LiteralPath $f)) -or (((Get-Date) - (Get-Item -LiteralPath $f).LastWriteTime).TotalMinutes -gt 60)
    if ($stale) {
        try { Download-File "$ReleasesBase/releases.json" $f }
        catch { if (-not (Test-Path -LiteralPath $f)) { throw "cannot fetch releases.json: $($_.Exception.Message)" }; Warn 'offline, using cached releases.json' }
    }
    return (Get-Content -LiteralPath $f -Raw | ConvertFrom-Json)
}

function Resolve-Remote($spec, [bool]$ts, $arch) {
    if ($spec -notmatch '^(\d+\.\d+)(\.\d+)?$') { throw "invalid version '$spec' (expected e.g. 8.3 or 8.3.36)" }
    $branch = $Matches[1]; $full = ($Matches[2] -ne $null -and $Matches[2] -ne '')
    $kind = if ($ts) { 'ts' } else { 'nts' }
    $rel = Get-Releases
    $prop = $rel.PSObject.Properties[$branch]
    if ($prop) {
        $entry = $prop.Value
        $base = $entry.version -replace '-\d+$', ''
        if ((-not $full) -or $spec -eq $base) {
            $k = $entry.PSObject.Properties | Where-Object { $_.Name -match "^$kind-(v[sc]\d+)-$arch$" } | Select-Object -First 1
            if (-not $k) { throw "no $kind/$arch build for PHP $base" }
            $null = $k.Name -match "^$kind-(v[sc]\d+)-$arch$"
            return [pscustomobject]@{ Version = $base; Vs = $Matches[1]; Url = "$ReleasesBase/$($k.Value.zip.path)"; Sha = $k.Value.zip.sha256; File = $k.Value.zip.path }
        }
    }
    if (-not $full) { throw "PHP branch $branch not found (see: phpvm list --remote)" }
    # archived release: probe known toolset names
    foreach ($vs in 'vs17', 'vs16', 'vc15', 'vc14', 'vc11') {
        $file = if ($ts) { "php-$spec-Win32-$vs-$arch.zip" } else { "php-$spec-nts-Win32-$vs-$arch.zip" }
        $url = "$ReleasesBase/archives/$file"
        try { $null = Invoke-WebRequest -UseBasicParsing -Method Head -Uri $url; return [pscustomobject]@{ Version = $spec; Vs = $vs; Url = $url; Sha = $null; File = $file } } catch { }
    }
    throw "PHP $spec not found on windows.php.net (releases or archives)"
}

# ---------------------------------------------------------------- commands
function Cmd-Init {
    Ensure-Dirs
    Say "root: $Root"
    if ($Opt['no-path']) { Say 'PATH untouched (--no-path)'; return }
    $changed = Add-UserPath @($Bin, $Current)
    if ($changed) { Ok 'user PATH updated (open a NEW terminal to pick it up)' } else { Say 'user PATH already configured' }
}

function Cmd-List {
    if ($Opt['remote']) {
        $rel = Get-Releases
        foreach ($p in $rel.PSObject.Properties) {
            $v = $p.Value.version -replace '-\d+$', ''
            $keys = @($p.Value.PSObject.Properties | Where-Object { $_.Name -match '^(nts|ts)-v[sc]\d+-(x64|x86)$' } | ForEach-Object { $_.Name })
            $nts = $keys -match '^nts-.*x64$'; $ts = $keys -match '^ts-.*x64$'
            Say ('{0,-5} {1,-9} {2}' -f $p.Name, $v, (@($(if ($nts) { 'nts' }), $(if ($ts) { 'ts' })) -join ',') + ' x64/x86')
        }
        if ($Opt['all']) {
            Say ''; Say 'archives:'
            $html = (Invoke-WebRequest -UseBasicParsing -Uri "$ReleasesBase/archives/").Content
            $vers = [regex]::Matches($html, 'php-(\d+\.\d+\.\d+)-(?:nts-)?Win32-') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique { [version]$_ } -Descending
            Say (($vers) -join '  ')
        }
        return
    }
    $act = Get-ActiveName
    $names = Get-InstalledNames
    if ($names.Count -eq 0) { Say 'no versions installed (try: phpvm install 8.3)'; return }
    foreach ($n in $names) { if ($n -eq $act) { Ok "* $n" } else { Say "  $n" } }
}

function Cmd-Install {
    if ($Pos.Count -lt 1) { throw 'usage: phpvm install <version> [--ts] [--x86] [--production]' }
    Ensure-Dirs
    $ts = [bool]$Opt['ts']; $arch = if ($Opt['x86']) { 'x86' } else { 'x64' }
    $r = Resolve-Remote $Pos[0] $ts $arch
    $kind = if ($ts) { 'ts' } else { 'nts' }
    $name = "$($r.Version)-$kind-$arch"
    $dest = Join-Path $Versions $name
    if (Test-Path -LiteralPath $dest) { Say "$name already installed"; return }

    $zip = Join-Path $Cache $r.File
    if (-not ((Test-Path -LiteralPath $zip) -and (Test-Sha256 $zip $r.Sha))) {
        Say "downloading $($r.File) ..."
        Download-File $r.Url $zip
    }
    if (-not (Test-Sha256 $zip $r.Sha)) { Remove-Item -LiteralPath $zip -Force; throw 'SHA-256 mismatch, download discarded' }
    if ($r.Sha) { Say 'sha256 ok' } else { Warn 'no checksum published for archived releases; not verified' }

    $tmp = Join-Path $Versions ('.tmp-' + [guid]::NewGuid().ToString('N'))
    try {
        Say 'extracting ...'
        Expand-ZipSafe $zip $tmp
        [pscustomobject]@{ version = $r.Version; ts = $ts; arch = $arch; vs = $r.Vs } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $tmp '.phpvm.json') -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $dest
    } catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
        throw
    }

    # php.ini
    $src = if ($Opt['production']) { 'php.ini-production' } else { 'php.ini-development' }
    $iniPath = Join-Path $dest 'php.ini'
    Copy-Item -LiteralPath (Join-Path $dest $src) -Destination $iniPath
    $ini = Read-Ini $iniPath
    Set-IniLine $ini.Lines 'extension_dir' ('"' + (Join-Path $dest 'ext') + '"')
    foreach ($e in $DefaultExts) { if (Test-Path -LiteralPath (Join-Path $dest "ext\php_$e.dll")) { [void](Enable-IniExt $ini.Lines $e) } }
    Write-Ini $iniPath $ini $false

    $h = Test-PhpHealthy $dest
    if (-not $h.Ok) { Warn "php.exe does not run cleanly: $($h.Msg)" }
    Ok "installed $name"
    if (-not (Get-ActiveName)) { Say "run: phpvm use $($r.Version)" }
}

function Cmd-Uninstall {
    if ($Pos.Count -lt 1) { throw 'usage: phpvm uninstall <version> [--force]' }
    $name = Resolve-Installed $Pos[0]
    if ((Get-ActiveName) -eq $name) {
        if (-not $Opt['force']) { throw "$name is active; run 'phpvm off' first or use --force" }
        Remove-Junction
    }
    Remove-Item -LiteralPath (Join-Path $Versions $name) -Recurse -Force
    Ok "removed $name"
}

function Cmd-Use {
    $spec = if ($Pos.Count -ge 1) { $Pos[0] } elseif (Test-Path '.php-version') { (Get-Content '.php-version' -TotalCount 1).Trim() } else { throw 'usage: phpvm use <version>' }
    $name = Resolve-Installed $spec
    Set-Junction $name
    $cfg = Read-Config; $cfg | Add-Member -NotePropertyName last -NotePropertyValue $name -Force; Save-Config $cfg
    Ok "now using $name"
    if (-not (($env:Path -split ';') | Where-Object { $_.TrimEnd('\') -ieq $Current.TrimEnd('\') })) { Warn "$Current is not in this shell's PATH (run 'phpvm init', then open a new terminal)" }
}
function Cmd-Off {
    if (-not (Get-ActiveName)) { Say 'PHP already off'; return }
    Remove-Junction
    Ok 'PHP deactivated (phpvm on to restore)'
}
function Cmd-On {
    $cfg = Read-Config
    if (-not $cfg.last) { throw 'no previous version; use: phpvm use <version>' }
    $name = Resolve-Installed $cfg.last
    Set-Junction $name
    Ok "now using $name"
}
function Cmd-Current {
    $a = Get-ActiveName
    if ($a) { Say $a } else { Say 'none'; exit 1 }
}

function Cmd-Config {
    $sub = if ($Pos.Count) { $Pos[0] } else { 'help' }
    $name = Get-Target
    $dir = Join-Path $Versions $name
    $iniPath = Join-Path $dir 'php.ini'
    switch ($sub) {
        'path' { Say $iniPath }
        'edit' { Start-Process notepad.exe $iniPath }
        'get' {
            if ($Pos.Count -lt 2) { throw 'usage: phpvm config get <key>' }
            $v = Get-IniLine (Read-Ini $iniPath).Lines $Pos[1]
            if ($null -eq $v) { Say '(not set)'; exit 1 } else { Say $v }
        }
        'set' {
            if ($Pos.Count -lt 3) { throw 'usage: phpvm config set <key> <value>' }
            $ini = Read-Ini $iniPath
            Set-IniLine $ini.Lines $Pos[1] $Pos[2]
            Commit-Ini $dir $iniPath $ini
            Ok "$($Pos[1]) = $($Pos[2])"
        }
        'unset' {
            if ($Pos.Count -lt 2) { throw 'usage: phpvm config unset <key>' }
            $ini = Read-Ini $iniPath
            $n = Unset-IniLine $ini.Lines $Pos[1]
            if ($n -eq 0) { Say 'nothing to unset'; return }
            Commit-Ini $dir $iniPath $ini
            Ok "$($Pos[1]) commented out"
        }
        'reset' {
            $src = if ($Opt['production']) { 'php.ini-production' } else { 'php.ini-development' }
            Copy-Item -LiteralPath $iniPath -Destination "$iniPath.bak" -Force
            Copy-Item -LiteralPath (Join-Path $dir $src) -Destination $iniPath -Force
            $ini = Read-Ini $iniPath
            Set-IniLine $ini.Lines 'extension_dir' ('"' + (Join-Path $dir 'ext') + '"')
            foreach ($e in $DefaultExts) { if (Test-Path -LiteralPath (Join-Path $dir "ext\php_$e.dll")) { [void](Enable-IniExt $ini.Lines $e) } }
            Write-Ini $iniPath $ini $false
            Ok "php.ini reset from $src (old one: php.ini.bak)"
        }
        default { throw 'usage: phpvm config get|set|unset|edit|reset|path' }
    }
}

function Cmd-Ext {
    $sub = if ($Pos.Count) { $Pos[0] } else { 'help' }
    $name = Get-Target
    $dir = Join-Path $Versions $name
    $iniPath = Join-Path $dir 'php.ini'
    $extDir = Join-Path $dir 'ext'
    switch ($sub) {
        'list' {
            $ini = Read-Ini $iniPath
            $active = @{}
            foreach ($l in $ini.Lines) { $p = Parse-ExtLine $l; if ($p -and $p.Active) { $active[$p.Name] = $true } }
            Say "extensions for $name"
            Get-ChildItem -LiteralPath $extDir -Filter 'php_*.dll' | Sort-Object Name | ForEach-Object {
                $n = ($_.BaseName -replace '^php_', '').ToLower()
                $z = if ($ZendExts -contains $n) { ' (zend)' } else { '' }
                if ($active[$n]) { Ok "  [x] $n$z" } else { Say "  [ ] $n$z" }
            }
        }
        'enable' {
            if ($Pos.Count -lt 2) { throw 'usage: phpvm ext enable <name>' }
            foreach ($e in $Pos[1..($Pos.Count - 1)]) {
                $e = $e.ToLower()
                if (-not (Test-Path -LiteralPath (Join-Path $extDir "php_$e.dll"))) { throw "php_$e.dll not found in ext\ (try: phpvm ext install $e)" }
                $ini = Read-Ini $iniPath
                $st = Enable-IniExt $ini.Lines $e
                if ($st -eq 'already') { Say "$e already enabled"; continue }
                Commit-Ini $dir $iniPath $ini
                Ok "enabled $e"
            }
        }
        'disable' {
            if ($Pos.Count -lt 2) { throw 'usage: phpvm ext disable <name>' }
            foreach ($e in $Pos[1..($Pos.Count - 1)]) {
                $ini = Read-Ini $iniPath
                if ((Disable-IniExt $ini.Lines $e) -eq 0) { Say "$e not enabled"; continue }
                Commit-Ini $dir $iniPath $ini
                Ok "disabled $e"
            }
        }
        'remove' {
            if ($Pos.Count -lt 2) { throw 'usage: phpvm ext remove <name>' }
            $e = $Pos[1].ToLower()
            $ini = Read-Ini $iniPath
            if ((Disable-IniExt $ini.Lines $e) -gt 0) { Commit-Ini $dir $iniPath $ini }
            $dll = Join-Path $extDir "php_$e.dll"
            if (Test-Path -LiteralPath $dll) { Remove-Item -LiteralPath $dll -Force; Ok "removed php_$e.dll" } else { Say 'dll not present' }
        }
        'search' {
            if ($Pos.Count -lt 2) { throw 'usage: phpvm ext search <name>' }
            $b = Find-PeclBuilds $Pos[1] $name $null ([bool]$Opt['pre']) 8
            if ($b.Count -eq 0) { Say "no compatible build for $($Pos[1]) on $name" } else { $b | ForEach-Object { Say "  $($_.Version)  $($_.File)" } }
        }
        'install' {
            if ($Pos.Count -lt 2) { throw 'usage: phpvm ext install <name>[@version]' }
            $spec = $Pos[1]; $want = $null
            if ($spec -match '^([^@]+)@(.+)$') { $spec = $Matches[1]; $want = $Matches[2] }
            $spec = $spec.ToLower()
            $b = Find-PeclBuilds $spec $name $want ([bool]$Opt['pre']) 1
            if ($b.Count -eq 0) { throw "no compatible PECL build of '$spec' for $name" }
            $build = $b[0]
            Say "downloading $($build.File) ..."
            $zip = Join-Path $Cache $build.File
            Download-File $build.Url $zip
            $tmp = Join-Path $Cache ('ext-' + [guid]::NewGuid().ToString('N'))
            try {
                Expand-ZipSafe $zip $tmp
                $main = Join-Path $tmp "php_$spec.dll"
                if (-not (Test-Path -LiteralPath $main)) { throw "php_$spec.dll not found in archive" }
                Copy-Item -LiteralPath $main -Destination $extDir -Force
                Get-ChildItem -LiteralPath $tmp -Filter '*.dll' | Where-Object { $_.Name -ne "php_$spec.dll" } | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $dir -Force }
            } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force } }
            $ini = Read-Ini $iniPath
            [void](Enable-IniExt $ini.Lines $spec)
            Commit-Ini $dir $iniPath $ini
            Ok "installed + enabled $spec $($build.Version)"
        }
        default { throw 'usage: phpvm ext list|enable|disable|install|remove|search' }
    }
}

# returns up to $max builds (newest first) matching installed PHP triplet
function Find-PeclBuilds($ext, $name, $wantVer, [bool]$pre, $max) {
    $m = Get-Meta $name
    $mm = ($m.version -split '\.')[0..1] -join '.'
    $kind = if ($m.ts) { 'ts' } else { 'nts' }
    $listing = try { (Invoke-WebRequest -UseBasicParsing -Uri "$PeclBase/$ext/").Content } catch { throw "extension '$ext' not found on PECL (windows builds)" }
    $vers = [regex]::Matches($listing, 'href="([^"/]+)/"') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -match '^\d' }
    if ($wantVer) { $vers = $vers | Where-Object { $_ -eq $wantVer } }
    elseif (-not $pre) { $vers = $vers | Where-Object { $_ -match '^\d+(\.\d+)*$' } }
    $vers = @($vers | Sort-Object { $v = $_ -replace '^(\d+(\.\d+)*).*', '$1'; if ($v -notmatch '\.') { $v += '.0' }; [version]$v }, { $_ } -Descending)
    $pat = '^php_' + [regex]::Escape($ext) + '-[^-]+-' + [regex]::Escape($mm) + '-' + $kind + '-' + $m.vs + '-' + $m.arch + '\.zip$'
    $out = @()
    $probes = 0
    foreach ($v in $vers) {
        if ($probes++ -ge 25) { break }
        $page = try { (Invoke-WebRequest -UseBasicParsing -Uri "$PeclBase/$ext/$v/").Content } catch { continue }
        $files = [regex]::Matches($page, 'href="([^"/]+\.zip)"') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -match $pat }
        foreach ($f in $files) { $out += [pscustomobject]@{ Version = $v; File = $f; Url = "$PeclBase/$ext/$v/$f" } }
        if ($out.Count -ge $max) { break }
    }
    return $out
}

function Cmd-Doctor {
    $bad = 0
    Say "root: $Root"
    $userPath = [string][Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment').GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    foreach ($d in $Bin, $Current) {
        if (($userPath -split ';') | Where-Object { $_.TrimEnd('\') -ieq $d.TrimEnd('\') }) { Ok "PATH has $d" } else { Warn "PATH lacks $d (run: phpvm init)"; $bad++ }
    }
    $found = @(Get-Command php -All -ErrorAction SilentlyContinue | Where-Object { $_.CommandType -eq 'Application' } | ForEach-Object { $_.Source })
    if ($found.Count -gt 0) {
        Say "php resolved in PATH:"; $found | ForEach-Object { Say "  $_" }
        $foreign = @($found | Where-Object { $_ -notlike "$Root*" })
        if ($foreign.Count -gt 0) { Warn 'other php.exe found in PATH; may shadow phpvm'; $bad++ }
    } else { Say 'no php in current shell PATH' }
    foreach ($arch in 'x64', 'x86') {
        $k = "HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\$arch"
        $inst = (Get-ItemProperty -Path $k -ErrorAction SilentlyContinue).Installed
        if ($inst -eq 1) { Ok "VC++ runtime $arch present" } else { Warn "VC++ runtime $arch missing (https://aka.ms/vs/17/release/vc_redist.$arch.exe)"; if ($arch -eq 'x64') { $bad++ } }
    }
    $a = Get-ActiveName
    if ($a) { $h = Test-PhpHealthy (Join-Path $Versions $a); if ($h.Ok) { Ok "active $a runs fine" } else { Warn "active $a fails: $($h.Msg)"; $bad++ } }
    else { Say 'no active version' }
    if ($bad -eq 0) { Ok 'all good' } else { exit 1 }
}

function Cmd-Help {
@'
phpvm - PHP version manager for Windows

  phpvm init [--no-path]            create folders, add bin + current to user PATH
  phpvm list [--remote [--all]]     installed / available versions
  phpvm install <ver> [--ts] [--x86] [--production]
  phpvm uninstall <ver> [--force]
  phpvm use <ver>                   activate (also reads .php-version)
  phpvm off | on                    deactivate / reactivate last version
  phpvm current
  phpvm config get|set|unset|edit|reset|path ...   (php.ini of active version)
  phpvm ext list|enable|disable|install|remove|search ...
  phpvm doctor

  <ver> accepts a prefix: 8.3 -> newest 8.3.x installed/available
  --version <v> on config/ext targets a non-active version
'@ | Write-Host
}

# ---------------------------------------------------------------- main
$cmd = if ($args.Count -gt 0) { [string]$args[0] } else { 'help' }
$rest = @(); if ($args.Count -gt 1) { $rest = @($args[1..($args.Count - 1)]) }
$Pos = @(); $Opt = @{}
$valueOpts = @('version')
for ($i = 0; $i -lt $rest.Count; $i++) {
    $a = [string]$rest[$i]
    if ($a -match '^--(.+)$') {
        $n = $Matches[1]
        if ($valueOpts -contains $n) { $Opt[$n] = [string]$rest[$i + 1]; $i++ } else { $Opt[$n] = $true }
    } else { $Pos += $a }
}

try {
    switch ($cmd) {
        'init'      { Cmd-Init }
        { $_ -in 'list', 'ls' } { Cmd-List }
        'install'   { Cmd-Install }
        { $_ -in 'uninstall', 'remove' } { Cmd-Uninstall }
        'use'       { Cmd-Use }
        'off'       { Cmd-Off }
        'on'        { Cmd-On }
        'current'   { Cmd-Current }
        'config'    { Cmd-Config }
        'ext'       { Cmd-Ext }
        'doctor'    { Cmd-Doctor }
        { $_ -in 'help', '-h', '--help' } { Cmd-Help }
        default     { throw "unknown command '$cmd' (see: phpvm help)" }
    }
} catch {
    Write-Host "error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
