# Auto Cleaner - engine: scan, removal, safety guards, log.
# Keep this file ASCII-only: PowerShell 5.1 reads BOM-less scripts as ANSI.
# Every user-facing text lives in catalog.json; results carry note KEYS, not text.

$script:AC = @{
    DryRun     = $false
    LogPath    = $null
    Sync       = $null
    Inside     = @()   # targets must be strictly beneath one of these
    Exact      = @()   # targets may be equal to or beneath one of these
    Protected  = @()   # targets may not be equal to, above or below these
    KeepWhole  = @()   # targets may not be equal to or above these
}

function Write-ACLog {
    param([string]$Message)
    if (-not $script:AC.LogPath) { return }
    $line = '{0}  {1}{2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message, [Environment]::NewLine
    try { [IO.File]::AppendAllText($script:AC.LogPath, $line, [Text.Encoding]::UTF8) } catch { }
}

function Get-ACDownloadsPath {
    $v = $null
    try {
        $k = Get-Item -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction Stop
        $v = $k.GetValue('{374DE290-123F-4565-9164-39C4925E467F}')
    } catch { }
    if ($v) { return ([Environment]::ExpandEnvironmentVariables([string]$v)).TrimEnd('\') }
    return (Join-Path $env:USERPROFILE 'Downloads')
}

# Expands %VARS%. Returns $null when a variable is unknown or the result is not
# an absolute drive path, so a broken entry can never resolve relative to the cwd.
function Expand-ACPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $p = $Path.Replace('%DOWNLOADS%', (Get-ACDownloadsPath))
    $p = [Environment]::ExpandEnvironmentVariables($p)
    if ($p.Contains('%')) { return $null }
    if ($p -notmatch '^[A-Za-z]:\\') { return $null }
    return $p.TrimEnd('\')
}

function Initialize-ACEngine {
    param($Config, [string]$LogPath, [bool]$DryRun, $Sync)
    $script:AC.DryRun = $DryRun
    $script:AC.LogPath = $LogPath
    $script:AC.Sync = $Sync
    $script:AC.Inside    = @($Config.raizesDentro    | ForEach-Object { Expand-ACPath $_ } | Where-Object { $_ })
    $script:AC.Exact     = @($Config.raizesExatas    | ForEach-Object { Expand-ACPath $_ } | Where-Object { $_ })
    $script:AC.Protected = @($Config.protegidos      | ForEach-Object { Expand-ACPath $_ } | Where-Object { $_ })
    $script:AC.KeepWhole = @($Config.naoApagarInteiro | ForEach-Object { Expand-ACPath $_ } | Where-Object { $_ })
}

function Test-ACUnder {
    param([string]$Path, [string]$Root)
    return $Path.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Test-ACSame {
    param([string]$A, [string]$B)
    return [string]::Equals($A, $B, [StringComparison]::OrdinalIgnoreCase)
}

# The single gate every deletion target goes through.
function Test-ACSafePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Contains('%')) { return $false }
    if ($Path -notmatch '^[A-Za-z]:\\') { return $false }
    try { $full = [IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return $false }

    $allowed = $false
    foreach ($r in $script:AC.Inside) { if (Test-ACUnder $full $r) { $allowed = $true } }
    foreach ($r in $script:AC.Exact)  { if ((Test-ACSame $full $r) -or (Test-ACUnder $full $r)) { $allowed = $true } }
    if (-not $allowed) { return $false }

    foreach ($p in $script:AC.Protected) {
        if ((Test-ACSame $full $p) -or (Test-ACUnder $p $full) -or (Test-ACUnder $full $p)) { return $false }
    }
    foreach ($p in $script:AC.KeepWhole) {
        if ((Test-ACSame $full $p) -or (Test-ACUnder $p $full)) { return $false }
    }

    try {
        $attr = [IO.File]::GetAttributes($full)
        if (($attr -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    } catch { return $false }
    return $true
}

function Resolve-ACTargets {
    param($Item)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($raw in @($Item.caminhos)) {
        $p = Expand-ACPath $raw
        if (-not $p) { Write-ACLog "RECUSADO (caminho invalido): $raw"; continue }
        $found = @()
        if ($p.IndexOfAny([char[]]'*?') -ge 0) {
            $found = @(Get-Item -Path $p -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.PSIsContainer } | ForEach-Object { $_.FullName })
        } elseif ([IO.Directory]::Exists($p)) {
            $found = @($p)
        }
        foreach ($f in $found) {
            if (Test-ACSafePath $f) { $out.Add($f) } else { Write-ACLog "RECUSADO (fora das raizes permitidas ou protegido): $f" }
        }
    }
    return $out.ToArray()
}

function New-ACAcc {
    return @{ Bytes = [long]0; Files = 0; Skipped = 0; Freed = [long]0; Links = 0; SkipLog = 0 }
}

function Test-ACFilter {
    param([string]$Name, $Filters)
    if (-not $Filters) { return $true }
    foreach ($f in $Filters) { if ($Name -like $f) { return $true } }
    return $false
}

# Walks a folder without ever following junctions/symlinks (Remove-Item -Recurse
# in PS 5.1 can delete a link's target). Counts eligible files, and deletes them
# when $Delete is set. Returns $true when the folder ended up empty.
function Invoke-ACWalk {
    param([string]$Path, [datetime]$Cutoff, $Filters, [bool]$Delete, [hashtable]$Acc)
    if ($script:AC.Sync -and $script:AC.Sync.Cancel) { return $false }
    try { $entries = @((New-Object IO.DirectoryInfo $Path).GetFileSystemInfos()) }
    catch { $Acc.Skipped++; return $false }

    $empty = $true
    foreach ($e in $entries) {
        if (($e.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $Acc.Links++; $empty = $false; continue }

        if ($e -is [IO.DirectoryInfo]) {
            $subEmpty = Invoke-ACWalk -Path $e.FullName -Cutoff $Cutoff -Filters $Filters -Delete $Delete -Acc $Acc
            $old = ($e.LastWriteTime -le $Cutoff) -and ($e.CreationTime -le $Cutoff)
            if ($Delete -and $subEmpty -and $old -and (-not $Filters) -and (-not $script:AC.DryRun)) {
                try { $e.Delete($false) } catch { $empty = $false }
            } else { $empty = $false }
            continue
        }

        if (-not (Test-ACFilter $e.Name $Filters)) { $empty = $false; continue }
        if (($e.LastWriteTime -gt $Cutoff) -or ($e.CreationTime -gt $Cutoff)) { $empty = $false; continue }

        $len = $e.Length
        $Acc.Bytes += $len
        $Acc.Files++
        if (-not $Delete) { $empty = $false; continue }
        if ($script:AC.DryRun) { $Acc.Freed += $len; $empty = $false; continue }
        try {
            if (($e.Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0) { $e.Attributes = [IO.FileAttributes]::Normal }
            $e.Delete()
            $Acc.Freed += $len
        } catch {
            $Acc.Skipped++
            $empty = $false
            if ($Acc.SkipLog -lt 40) { $Acc.SkipLog++; Write-ACLog "  pulado (em uso/sem acesso): $($e.FullName)" }
        }
    }
    return $empty
}

function Get-ACCutoff {
    param($Item)
    if ($Item.idadeMinHoras) { return (Get-Date).AddHours(-[double]$Item.idadeMinHoras) }
    return [datetime]::MaxValue
}

function Get-ACRunning {
    param($Names)
    if (-not $Names) { return @() }
    return @(Get-Process -Name @($Names) -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName } | Select-Object -Unique)
}

function Get-ACFreeBytes {
    try { return (New-Object IO.DriveInfo $env:SystemDrive).AvailableFreeSpace } catch { return [long]0 }
}

function Get-ACRecycleBytes {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $acc = New-ACAcc
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        if ($d.DriveType -ne [IO.DriveType]::Fixed -or -not $d.IsReady) { continue }
        $p = Join-Path $d.Name ('$Recycle.Bin\' + $sid)
        if ([IO.Directory]::Exists($p)) { [void](Invoke-ACWalk -Path $p -Cutoff ([datetime]::MaxValue) -Filters $null -Delete $false -Acc $acc) }
    }
    return $acc.Bytes
}

# Top-level entries of Downloads untouched for $Days days.
function Get-ACOldDownloads {
    param([int]$Days)
    $root = Get-ACDownloadsPath
    $list = New-Object System.Collections.Generic.List[object]
    if (-not [IO.Directory]::Exists($root)) { return $list.ToArray() }
    $cut = (Get-Date).AddDays(-$Days)
    foreach ($e in (New-Object IO.DirectoryInfo $root).GetFileSystemInfos()) {
        if ($e.Name -ieq 'desktop.ini') { continue }
        if (($e.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        if (($e.LastWriteTime -gt $cut) -or ($e.CreationTime -gt $cut)) { continue }
        $isDir = $e -is [IO.DirectoryInfo]
        if ($isDir) {
            $acc = New-ACAcc
            [void](Invoke-ACWalk -Path $e.FullName -Cutoff ([datetime]::MaxValue) -Filters $null -Delete $false -Acc $acc)
            $bytes = $acc.Bytes
        } else { $bytes = $e.Length }
        $list.Add([pscustomobject]@{ Path = $e.FullName; Name = $e.Name; Bytes = [long]$bytes; Date = $e.LastWriteTime; IsDir = $isDir })
    }
    return $list.ToArray()
}

# Only ever accepts direct children of the Downloads folder.
function Send-ACToRecycleBin {
    param([string]$Path)
    $root = Get-ACDownloadsPath
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    if (-not (Test-ACSame $parent $root)) { Write-ACLog "RECUSADO (fora de Downloads): $Path"; return $false }
    if ($script:AC.DryRun) { Write-ACLog "simulacao: iria para a Lixeira: $Path"; return $true }
    try {
        if ([IO.Directory]::Exists($Path)) {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Path, 'OnlyErrorDialogs', 'SendToRecycleBin')
        } else {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path, 'OnlyErrorDialogs', 'SendToRecycleBin')
        }
        Write-ACLog "enviado para a Lixeira: $Path"
        return $true
    } catch {
        Write-ACLog "ERRO ao enviar para a Lixeira: $Path - $($_.Exception.Message)"
        return $false
    }
}

function New-ACResult {
    # Bytes = -1 means "size not applicable / unknown".
    return @{ Bytes = [long]-1; Freed = [long]0; Skipped = 0; NoteKey = $null; NoteArg = $null; Error = $null }
}

function Measure-ACItem {
    param($Item)
    $r = New-ACResult
    switch ($Item.tipo) {
        'pasta' {
            $acc = New-ACAcc
            $cut = Get-ACCutoff $Item
            foreach ($t in @(Resolve-ACTargets $Item)) {
                [void](Invoke-ACWalk -Path $t -Cutoff $cut -Filters $Item.filtros -Delete $false -Acc $acc)
            }
            $r.Bytes = $acc.Bytes
            $running = @(Get-ACRunning $Item.processos)
            if ($running.Count -gt 0) { $r.NoteKey = 'fecharApp'; $r.NoteArg = ($running -join ', ') }
        }
        'lixeira' { $r.Bytes = Get-ACRecycleBytes }
        'comando' {
            if ($Item.acao -eq 'hibernacao') {
                $f = Join-Path $env:SystemDrive 'hiberfil.sys'
                if ([IO.File]::Exists($f)) { try { $r.Bytes = (New-Object IO.FileInfo $f).Length } catch { } }
            }
        }
        'interativo' {
            if ($Item.acao -eq 'downloads') {
                $sum = [long]0
                foreach ($d in @(Get-ACOldDownloads -Days ([int]$Item.dias))) { $sum += $d.Bytes }
                $r.Bytes = $sum
            }
        }
    }
    return $r
}

function Invoke-ACItem {
    param($Item)
    $r = New-ACResult
    Write-ACLog "== $($Item.id) ($($Item.nome))"
    switch ($Item.tipo) {
        'pasta' {
            $running = @(Get-ACRunning $Item.processos)
            if ($running.Count -gt 0) {
                $r.NoteKey = 'fecharApp'; $r.NoteArg = ($running -join ', ')
                Write-ACLog "  pulado: aplicativo aberto ($($r.NoteArg))"
                return $r
            }
            $stopped = @()
            if ($Item.servicos -and -not $script:AC.DryRun) {
                foreach ($s in @($Item.servicos)) {
                    $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
                    if ($svc -and $svc.Status -eq 'Running') {
                        try { Stop-Service -Name $s -Force -ErrorAction Stop; $stopped += $s; Write-ACLog "  servico parado: $s" }
                        catch { Write-ACLog "  nao foi possivel parar o servico $s" }
                    }
                }
            }
            $acc = New-ACAcc
            $cut = Get-ACCutoff $Item
            try {
                foreach ($t in @(Resolve-ACTargets $Item)) {
                    $before = $acc.Freed
                    [void](Invoke-ACWalk -Path $t -Cutoff $cut -Filters $Item.filtros -Delete $true -Acc $acc)
                    Write-ACLog ("  {0}: {1:N1} MB" -f $t, (($acc.Freed - $before) / 1MB))
                }
            } finally {
                foreach ($s in $stopped) {
                    try { Start-Service -Name $s -ErrorAction Stop; Write-ACLog "  servico reiniciado: $s" }
                    catch { Write-ACLog "  ERRO ao reiniciar o servico $s" }
                }
            }
            $r.Bytes = $acc.Bytes; $r.Freed = $acc.Freed; $r.Skipped = $acc.Skipped
            if ($acc.Links -gt 0) { Write-ACLog "  links/juncoes ignorados: $($acc.Links)" }
        }
        'lixeira' {
            $before = Get-ACRecycleBytes
            if ($script:AC.DryRun) { $r.Freed = $before }
            else {
                try { Clear-RecycleBin -Force -ErrorAction Stop } catch { Write-ACLog "  aviso Clear-RecycleBin: $($_.Exception.Message)" }
                $after = Get-ACRecycleBytes
                if ($before -gt $after) { $r.Freed = $before - $after }
            }
        }
        'comando' { $r = Invoke-ACCommand -Action $Item.acao }
    }
    if ($script:AC.DryRun) { Write-ACLog ("  simulacao: liberaria {0:N1} MB" -f ($r.Freed / 1MB)) }
    else { Write-ACLog ("  liberado: {0:N1} MB, pulados: {1}{2}" -f ($r.Freed / 1MB), $r.Skipped, $(if ($r.Error) { ", erro: $($r.Error)" } else { '' })) }
    return $r
}
