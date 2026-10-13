# Auto Cleaner - optimizations: startup apps, hibernation, DISM/SFC, disks, restore point.
# ASCII-only, like Engine.ps1. Depends on Engine.ps1 being dot-sourced first.

function Test-ACAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-ACHibernation {
    return [IO.File]::Exists((Join-Path $env:SystemDrive 'hiberfil.sys'))
}

function Get-ACDriveLetters {
    param([string]$MediaType)
    $letters = @()
    try {
        foreach ($pd in @(Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.MediaType -eq $MediaType })) {
            $letters += @(Get-Partition -DiskNumber $pd.DeviceId -ErrorAction SilentlyContinue |
                Where-Object { $_.DriveLetter } | ForEach-Object { [string]$_.DriveLetter })
        }
    } catch { }
    return @($letters | Where-Object { $_ -match '^[A-Za-z]$' })
}

# Runs a console tool in its own visible window so the user sees native progress.
# The window stays 20 s after finishing; the tool's exit code is preserved.
function Invoke-ACConsole {
    param([string]$Title, [string]$CommandLine)
    Write-ACLog "  executando: $CommandLine"
    $inner = 'title Auto Cleaner - {0} & {1} & set "EC=!errorlevel!" & echo. & echo Codigo de saida: !EC! & timeout /t 20 & exit !EC!' -f $Title, $CommandLine
    $p = Start-Process -FilePath $env:ComSpec -ArgumentList ('/v:on /c "' + $inner + '"') -Wait -PassThru
    Write-ACLog "  codigo de saida: $($p.ExitCode)"
    return $p.ExitCode
}

# Only the fixed actions below can run; catalog.json cannot inject commands.
function Invoke-ACCommand {
    param([string]$Action)
    $r = New-ACResult
    if ($script:AC.DryRun) { $r.NoteKey = 'simulado'; return $r }
    $before = Get-ACFreeBytes
    try {
        switch ($Action) {
            'dns' {
                & ipconfig.exe /flushdns | Out-Null
                if ($LASTEXITCODE -ne 0) { $r.NoteKey = 'codigoSaida'; $r.NoteArg = $LASTEXITCODE } else { $r.NoteKey = 'feito' }
            }
            'trim' {
                $letters = @(Get-ACDriveLetters 'SSD')
                if ($letters.Count -eq 0) { $r.NoteKey = 'semDisco' }
                foreach ($l in $letters) { Optimize-Volume -DriveLetter $l -ReTrim -ErrorAction Stop; Write-ACLog "  TRIM em ${l}:"; $r.NoteKey = 'feito' }
            }
            'defrag' {
                $letters = @(Get-ACDriveLetters 'HDD')
                if ($letters.Count -eq 0) { $r.NoteKey = 'semDisco' }
                # /O picks the right method per media type, so an SSD is never defragmented.
                foreach ($l in $letters) {
                    $code = Invoke-ACConsole -Title "Desfragmentar ${l}:" -CommandLine "defrag.exe ${l}: /O /U /V"
                    if ($code -ne 0) { $r.NoteKey = 'codigoSaida'; $r.NoteArg = $code } else { $r.NoteKey = 'feito' }
                }
            }
            'dism' {
                $code = Invoke-ACConsole -Title 'DISM' -CommandLine 'dism.exe /Online /Cleanup-Image /StartComponentCleanup'
                if ($code -eq 3010) { $r.NoteKey = 'reiniciar' } elseif ($code -ne 0) { $r.NoteKey = 'codigoSaida'; $r.NoteArg = $code } else { $r.NoteKey = 'feito' }
            }
            'dism-resetbase' {
                $code = Invoke-ACConsole -Title 'DISM ResetBase' -CommandLine 'dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase'
                if ($code -eq 3010) { $r.NoteKey = 'reiniciar' } elseif ($code -ne 0) { $r.NoteKey = 'codigoSaida'; $r.NoteArg = $code } else { $r.NoteKey = 'feito' }
            }
            'sfc' {
                $code = Invoke-ACConsole -Title 'SFC' -CommandLine 'sfc.exe /scannow'
                if ($code -ne 0) { $r.NoteKey = 'codigoSaida'; $r.NoteArg = $code } else { $r.NoteKey = 'feito' }
            }
            'hibernacao' {
                $arg = if (Test-ACHibernation) { 'off' } else { 'on' }
                & powercfg.exe /hibernate $arg | Out-Null
                Write-ACLog "  powercfg /hibernate $arg (codigo $LASTEXITCODE)"
                if ($LASTEXITCODE -ne 0) { $r.NoteKey = 'codigoSaida'; $r.NoteArg = $LASTEXITCODE } else { $r.NoteKey = 'feito' }
            }
            'otimizacao-entrega' {
                Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
                $r.NoteKey = 'feito'
            }
            default { $r.Error = "acao desconhecida: $Action" }
        }
    } catch { $r.Error = $_.Exception.Message }
    $after = Get-ACFreeBytes
    if ($after -gt $before) { $r.Freed = $after - $before }
    return $r
}

# Returns $null on success, or the error message.
function New-ACRestorePoint {
    if ($script:AC.DryRun) { return $null }
    try {
        Checkpoint-Computer -Description 'Auto Cleaner' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop -WarningVariable w -WarningAction SilentlyContinue
        if ($w) { Write-ACLog "  ponto de restauracao: $w"; return [string]$w }
        Write-ACLog '  ponto de restauracao criado'
        return $null
    } catch {
        Write-ACLog "  ponto de restauracao falhou: $($_.Exception.Message)"
        return $_.Exception.Message
    }
}

# --- Startup apps -----------------------------------------------------------
# Uses Explorer\StartupApproved, the same switch Task Manager flips, so every
# change is reversible here or in Task Manager. Nothing is ever deleted.

$script:ACApprovedBase = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'

function Get-ACStartupEnabled {
    param([string]$ApprovedKey, [string]$Name)
    $k = Get-Item -LiteralPath $ApprovedKey -ErrorAction SilentlyContinue
    if (-not $k) { return $true }
    $v = $k.GetValue($Name)
    if ($null -eq $v -or $v.Length -eq 0) { return $true }
    return (($v[0] -band 1) -eq 0)
}

function Get-ACStartupEntries {
    $list = New-Object System.Collections.Generic.List[object]
    $run = 'Software\Microsoft\Windows\CurrentVersion\Run'
    $sources = @(
        @{ Key = "HKCU:\$run"; Approved = "HKCU:\$($script:ACApprovedBase)\Run"; Admin = $false },
        @{ Key = "HKLM:\$run"; Approved = "HKLM:\$($script:ACApprovedBase)\Run"; Admin = $true },
        @{ Key = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = "HKLM:\$($script:ACApprovedBase)\Run32"; Admin = $true }
    )
    foreach ($s in $sources) {
        $k = Get-Item -LiteralPath $s.Key -ErrorAction SilentlyContinue
        if (-not $k) { continue }
        foreach ($name in $k.GetValueNames()) {
            if (-not $name) { continue }
            $list.Add([pscustomobject]@{
                Name = $name; Command = [string]$k.GetValue($name); Approved = $s.Approved; Admin = $s.Admin
                Enabled = (Get-ACStartupEnabled $s.Approved $name)
            })
        }
    }
    $folders = @(
        @{ Dir = [Environment]::GetFolderPath('Startup'); Approved = "HKCU:\$($script:ACApprovedBase)\StartupFolder"; Admin = $false },
        @{ Dir = [Environment]::GetFolderPath('CommonStartup'); Approved = "HKLM:\$($script:ACApprovedBase)\StartupFolder"; Admin = $true }
    )
    foreach ($f in $folders) {
        if (-not $f.Dir -or -not [IO.Directory]::Exists($f.Dir)) { continue }
        foreach ($file in (New-Object IO.DirectoryInfo $f.Dir).GetFiles()) {
            if ($file.Name -ieq 'desktop.ini') { continue }
            $list.Add([pscustomobject]@{
                Name = $file.Name; Command = $file.FullName; Approved = $f.Approved; Admin = $f.Admin
                Enabled = (Get-ACStartupEnabled $f.Approved $file.Name)
            })
        }
    }
    return $list.ToArray()
}

function Set-ACStartupEntry {
    param($Entry, [bool]$Enabled)
    $state = if ($Enabled) { 'ativado' } else { 'desativado' }
    if ($script:AC.DryRun) { Write-ACLog "simulacao: inicializacao '$($Entry.Name)' seria $state"; return }
    if (-not (Test-Path -LiteralPath $Entry.Approved)) { New-Item -Path $Entry.Approved -Force | Out-Null }
    $bytes = New-Object byte[] 12
    if ($Enabled) { $bytes[0] = 2 }
    else {
        $bytes[0] = 3
        [BitConverter]::GetBytes([DateTime]::UtcNow.ToFileTimeUtc()).CopyTo($bytes, 4)
    }
    Set-ItemProperty -LiteralPath $Entry.Approved -Name $Entry.Name -Value $bytes -Type Binary -ErrorAction Stop
    Write-ACLog "inicializacao: '$($Entry.Name)' $state"
}
