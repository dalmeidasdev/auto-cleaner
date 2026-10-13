# Auto Cleaner - entry point: loads the catalog, opens the window, wires events.
# ASCII-only (PS 5.1 reads BOM-less scripts as ANSI). All Portuguese text comes
# from catalog.json ("textos") and the .xaml files, both read as UTF-8.
#
#   -DryRun   simulate: scans and reports, deletes nothing, runs no command.

param([switch]$DryRun)

$ErrorActionPreference = 'Stop'
$script:SelfPath = $MyInvocation.MyCommand.Path
$script:Root = Split-Path -Parent $script:SelfPath
$script:IsDryRun = [bool]$DryRun

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, Microsoft.VisualBasic

if (-not ('ACItem' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;

public class ACBase : INotifyPropertyChanged {
    public event PropertyChangedEventHandler PropertyChanged;
    protected void Notify(string name) {
        PropertyChangedEventHandler h = PropertyChanged;
        if (h != null) h(this, new PropertyChangedEventArgs(name));
    }
}

public class ACItem : ACBase {
    public string Id { get; set; }
    public string Categoria { get; set; }
    public string Consequencia { get; set; }
    public string Risco { get; set; }
    public string RiscoTexto { get; set; }
    public int NivelN { get; set; }
    public int RiscoN { get; set; }
    public bool Admin { get; set; }
    public bool Interativo { get; set; }
    public bool PreMarcar { get; set; }
    public bool Analisado { get; set; }
    public long Bytes { get; set; }
    public object Dados { get; set; }

    private string _nome, _descricao, _tamanho, _status;
    private bool _selecionado, _habilitado;
    public string Nome { get { return _nome; } set { _nome = value; Notify("Nome"); } }
    public string Descricao { get { return _descricao; } set { _descricao = value; Notify("Descricao"); } }
    public string TamanhoTexto { get { return _tamanho; } set { _tamanho = value; Notify("TamanhoTexto"); } }
    public string Status { get { return _status; } set { _status = value; Notify("Status"); } }
    public bool Selecionado { get { return _selecionado; } set { _selecionado = value; Notify("Selecionado"); } }
    public bool Habilitado { get { return _habilitado; } set { _habilitado = value; Notify("Habilitado"); } }
}

public class ACRow : ACBase {
    public string Titulo { get; set; }
    public string Detalhe { get; set; }
    public bool Habilitado { get; set; }
    public object Tag { get; set; }
    private bool _marcado;
    public bool Marcado { get { return _marcado; } set { _marcado = value; Notify("Marcado"); } }
}
'@
}

. (Join-Path $script:Root 'src\Engine.ps1')
. (Join-Path $script:Root 'src\Optimizations.ps1')

$script:Culture = [Globalization.CultureInfo]::GetCultureInfo('pt-BR')
$script:Dash = [string][char]0x2014

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -lt 0) { return $script:Dash }
    if ($Bytes -ge 1GB) { return ('{0} GB' -f ($Bytes / 1GB).ToString('N1', $script:Culture)) }
    if ($Bytes -ge 1MB) { return ('{0} MB' -f ($Bytes / 1MB).ToString('N0', $script:Culture)) }
    if ($Bytes -gt 0) { return ('{0} KB' -f ([math]::Ceiling($Bytes / 1KB)).ToString('N0', $script:Culture)) }
    return '0 MB'
}

function Show-Msg {
    param([string]$Text, [string]$Buttons = 'OK', [string]$Icon = 'Information', [string]$Default = 'OK')
    return [Windows.MessageBox]::Show($script:Window, $Text, 'Auto Cleaner', $Buttons, $Icon, $Default)
}

function Get-Note {
    param($Result)
    if ($Result.Error) { return ($script:T.erro -f $Result.Error) }
    if (-not $Result.NoteKey) { return '' }
    $k = [string]$Result.NoteKey
    $text = $script:T.('nota' + $k.Substring(0, 1).ToUpper() + $k.Substring(1))
    if (-not $text) { return $k }
    return ($text -f $Result.NoteArg)
}

function Test-Visible {
    param($Item)
    return ($Item.NivelN -le $script:Level) -and ($Item.RiscoN -le $script:MaxRisk)
}

function Update-Disks {
    $parts = @()
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        if ($d.DriveType -ne [IO.DriveType]::Fixed -or -not $d.IsReady) { continue }
        $parts += ($script:T.disco -f $d.Name.TrimEnd('\'), (Format-Size $d.AvailableFreeSpace), (Format-Size $d.TotalSize))
    }
    $script:UI.TxtDiscos.Text = $parts -join '        '
}

function Update-Total {
    $sel = @($script:Items | Where-Object { $_.Selecionado })
    if ($sel.Count -eq 0) { $script:UI.TxtTotal.Text = $script:T.totalVazio; return }
    $sum = [long]0
    foreach ($s in $sel) { if ($s.Bytes -gt 0) { $sum += $s.Bytes } }
    $script:UI.TxtTotal.Text = ($script:T.total -f $sel.Count, (Format-Size $sum))
}

# The hibernation item flips between "disable" and "re-enable" with the real state.
function Update-HibernationItem {
    foreach ($it in $script:Items) {
        if ($it.Dados.acao -ne 'hibernacao') { continue }
        if (Test-ACHibernation) {
            $it.Nome = $it.Dados.nome; $it.Descricao = $it.Dados.descricao; $it.PreMarcar = $true
        } else {
            $it.Nome = $it.Dados.nomeAlternativo; $it.Descricao = $it.Dados.descricaoAlternativa; $it.PreMarcar = $false
        }
    }
}

function Set-Busy {
    param([bool]$Busy)
    $script:Busy = $Busy
    foreach ($n in 'RbRapida', 'RbMedia', 'RbCompleta', 'CmbRisco', 'BtnAnalisar', 'BtnExecutar', 'BtnAdmin') {
        $script:UI[$n].IsEnabled = -not $Busy
    }
    $script:UI.BtnCancelar.IsEnabled = $Busy
}

function Set-Level {
    param([int]$Level)
    $script:Level = $Level
    foreach ($it in $script:Items) {
        $it.Selecionado = (Test-Visible $it) -and $it.Habilitado -and $it.PreMarcar -and ($it.RiscoN -lt 3)
    }
    $script:View.Refresh()
    $script:UI.TxtDescNivel.Text = $script:T.("nivel$Level")
    Update-Total
    Start-Scan
}

# --- background job ---------------------------------------------------------
# Scan and clean run in a second runspace so the window stays responsive. The
# worker posts hashtables to a queue; a DispatcherTimer drains it on the UI thread.

$script:Worker = @'
$ErrorActionPreference = 'Stop'
try {
    . $sync.EnginePath
    . $sync.OptPath
    Initialize-ACEngine -Config $sync.Config -LogPath $sync.LogPath -DryRun $sync.DryRun -Sync $sync
    if ($sync.Mode -eq 'clean' -and $sync.RestorePoint) {
        $sync.Queue.Enqueue(@{ Kind = 'restore' })
        $err = New-ACRestorePoint
        if ($err) { $sync.Abort = [string]$err; return }
    }
    foreach ($d in $sync.Data) {
        if ($sync.Cancel) { break }
        $sync.Queue.Enqueue(@{ Kind = 'start'; Id = $d.id })
        try {
            if ($sync.Mode -eq 'scan') { $r = Measure-ACItem $d } else { $r = Invoke-ACItem $d }
        } catch {
            $r = New-ACResult
            $r.Error = $_.Exception.Message
            Write-ACLog "  ERRO em $($d.id): $($r.Error)"
        }
        $sync.Queue.Enqueue(@{ Kind = 'result'; Id = $d.id; R = $r })
    }
} catch {
    $sync.Abort = $_.Exception.Message
} finally {
    $sync.Done = $true
}
'@

function Start-Job2 {
    param([string]$Mode, $JobItems, [bool]$RestorePoint)
    $JobItems = @($JobItems)
    if ($script:Busy -or $JobItems.Count -eq 0) { return }
    Set-Busy $true
    $s = $script:Sync
    $s.Mode = $Mode; $s.Cancel = $false; $s.Done = $false; $s.Abort = $null
    $s.RestorePoint = $RestorePoint
    $s.Data = @($JobItems | ForEach-Object { $_.Dados })
    $script:JobTotal = $JobItems.Count; $script:JobDone = 0
    $script:Freed = [long]0; $script:Skipped = 0
    $script:UI.Barra.Maximum = $JobItems.Count; $script:UI.Barra.Value = 0
    foreach ($it in $JobItems) { $it.Status = $script:T.naFila }
    $script:PS = [powershell]::Create()
    $script:PS.Runspace = $script:Runspace
    [void]$script:PS.AddScript($script:Worker)
    $script:Handle = $script:PS.BeginInvoke()
    $script:Timer.Start()
}

function Start-Scan {
    $targets = @($script:Items | Where-Object { $_.NivelN -le $script:Level -and $_.Habilitado })
    Start-Job2 -Mode 'scan' -JobItems $targets -RestorePoint $false
}

function Receive-Message {
    param($Msg)
    $s = $script:Sync
    if ($Msg.Kind -eq 'restore') { $script:UI.TxtStatus.Text = $script:T.criandoPonto; return }
    $it = $script:ById[$Msg.Id]
    if (-not $it) { return }
    if ($Msg.Kind -eq 'start') {
        $fmt = if ($s.Mode -eq 'scan') { $script:T.statusAnalisando } else { $script:T.statusExecutando }
        $script:UI.TxtStatus.Text = ($fmt -f ($script:JobDone + 1), $script:JobTotal) + '   ' + $it.Nome
        $it.Status = if ($s.Mode -eq 'scan') { $script:T.analisando } else { $script:T.executando }
        return
    }
    $r = $Msg.R
    $script:JobDone++
    $script:UI.Barra.Value = $script:JobDone
    if ($s.Mode -eq 'scan') {
        $it.Bytes = $r.Bytes
        $it.Analisado = $true
        $it.TamanhoTexto = Format-Size $r.Bytes
        $it.Status = Get-Note $r
        return
    }
    $script:Freed += $r.Freed
    $script:Skipped += $r.Skipped
    $it.Selecionado = $false
    $it.Analisado = $false
    $it.Bytes = -1
    $it.TamanhoTexto = $script:Dash
    $size = Format-Size $r.Freed
    if ($r.Error -or $r.NoteKey) {
        $it.Status = Get-Note $r
        if ($r.Freed -gt 0) { $it.Status += '  ' + [char]0x00B7 + '  ' + ($script:T.liberado -f $size) }
    }
    elseif ($script:IsDryRun) { $it.Status = ($script:T.liberaria -f $size) }
    elseif ($r.Freed -eq 0 -and $r.Skipped -eq 0) { $it.Status = $script:T.nadaALimpar }
    elseif ($r.Skipped -gt 0) { $it.Status = ($script:T.liberadoPulados -f $size, $r.Skipped) }
    else { $it.Status = ($script:T.liberado -f $size) }
}

function Complete-Job {
    $s = $script:Sync
    try { $script:PS.EndInvoke($script:Handle) | Out-Null } catch { }
    $script:PS.Dispose(); $script:PS = $null
    foreach ($it in $script:Items) {
        if ($it.Status -eq $script:T.naFila -or $it.Status -eq $script:T.analisando -or $it.Status -eq $script:T.executando) { $it.Status = '' }
    }
    Set-Busy $false
    $script:UI.Barra.Value = 0
    Update-Total
    if ($s.Abort) {
        $script:UI.TxtStatus.Text = $script:T.statusCancelado
        $text = if ($s.RestorePoint) { $script:T.pontoFalhou -f $s.Abort } else { $script:T.erro -f $s.Abort }
        [void](Show-Msg $text 'OK' 'Warning')
        return
    }
    if ($s.Cancel) { $script:UI.TxtStatus.Text = $script:T.statusCancelado }
    elseif ($s.Mode -eq 'scan') { $script:UI.TxtStatus.Text = $script:T.statusAnalisado }
    if ($s.Mode -ne 'clean') { return }

    Update-Disks
    Update-HibernationItem
    if (-not $s.Cancel) { $script:UI.TxtStatus.Text = $script:T.statusPronto }
    if ($script:IsDryRun) { [void](Show-Msg ($script:T.resumoSimulacao -f (Format-Size $script:Freed), $script:LogPath)) }
    else { [void](Show-Msg ($script:T.resumo -f (Format-Size $script:Freed), $script:Skipped, $script:LogPath)) }
}

# --- dialogs ----------------------------------------------------------------

function Show-ListDialog {
    param([string]$Title, [string]$Info, $Rows, [string]$OkText)
    $dlg = [Windows.Markup.XamlReader]::Parse($script:ListXaml)
    $dlg.Owner = $script:Window
    $dlg.Title = $Title
    $dlg.FindName('TxtInfo').Text = $Info
    $dlg.FindName('Linhas').ItemsSource = $Rows
    $ok = $dlg.FindName('BtnOk')
    $ok.Content = $OkText
    $ok.Add_Click({ param($sender, $e) [Windows.Window]::GetWindow($sender).DialogResult = $true })
    return ($dlg.ShowDialog() -eq $true)
}

function Show-StartupDialog {
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($e in @(Get-ACStartupEntries)) {
        $protected = @($script:Config.inicializacaoProtegidos) -contains $e.Name
        $needAdmin = $e.Admin -and -not $script:IsAdmin
        $row = New-Object ACRow
        $row.Titulo = $e.Name
        $row.Detalhe = $e.Command
        if ($protected) { $row.Detalhe = $script:T.iniProtegido }
        elseif ($needAdmin) { $row.Detalhe = $script:T.iniAdmin + '  ' + [char]0x00B7 + '  ' + $e.Command }
        $row.Marcado = $e.Enabled
        $row.Habilitado = -not ($protected -or $needAdmin)
        $row.Tag = $e
        $rows.Add($row)
    }
    if (-not (Show-ListDialog -Title $script:T.iniTitulo -Info $script:T.iniInfo -Rows $rows -OkText $script:T.iniOk)) { return '' }
    $n = 0
    foreach ($row in $rows) {
        if ($row.Habilitado -and ($row.Marcado -ne $row.Tag.Enabled)) { Set-ACStartupEntry -Entry $row.Tag -Enabled $row.Marcado; $n++ }
    }
    return ($script:T.iniAplicado -f $n)
}

function Show-DownloadsDialog {
    param($Item)
    $days = [int]$Item.Dados.dias
    $old = @(Get-ACOldDownloads -Days $days | Sort-Object Bytes -Descending)
    if ($old.Count -eq 0) { return ($script:T.dlVazio -f $days) }
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($o in $old) {
        $row = New-Object ACRow
        $row.Titulo = $(if ($o.IsDir) { $script:T.dlPasta } else { '' }) + $o.Name
        $row.Detalhe = ($script:T.dlDetalhe -f (Format-Size $o.Bytes), $o.Date.ToString('dd/MM/yyyy'))
        $row.Marcado = $false
        $row.Habilitado = $true
        $row.Tag = $o
        $rows.Add($row)
    }
    if (-not (Show-ListDialog -Title $script:T.dlTitulo -Info ($script:T.dlInfo -f $days) -Rows $rows -OkText $script:T.dlOk)) { return '' }
    $n = 0
    foreach ($row in $rows) { if ($row.Marcado -and (Send-ACToRecycleBin -Path $row.Tag.Path)) { $n++ } }
    return ($script:T.dlEnviados -f $n)
}

function Invoke-Interactive {
    param($Item)
    Write-ACLog "== $($Item.Id) ($($Item.Nome))"
    switch ($Item.Dados.acao) {
        'inicializacao' { return (Show-StartupDialog) }
        'downloads' { return (Show-DownloadsDialog $Item) }
        'windows-old' {
            [void](Show-Msg $script:T.windowsOld)
            if (-not $script:IsDryRun) { Start-Process cleanmgr.exe -ArgumentList ('/d ' + $env:SystemDrive) }
            return $script:T.windowsOldAberto
        }
    }
    return ''
}

# Preview is mandatory: nothing runs without an analysis and an explicit yes,
# and medium/high risk asks a second time with the consequences spelled out.
function Invoke-Execute {
    $sel = @($script:Items | Where-Object { $_.Selecionado -and $_.Habilitado -and (Test-Visible $_) })
    if ($sel.Count -eq 0) { [void](Show-Msg $script:T.semSelecao); return }
    if (@($sel | Where-Object { -not $_.Analisado }).Count -gt 0) { [void](Show-Msg $script:T.faltaAnalise); return }

    $sum = [long]0
    foreach ($s in $sel) { if ($s.Bytes -gt 0) { $sum += $s.Bytes } }
    $lines = ($sel | ForEach-Object { $script:T.linhaConfirmar -f $_.Nome, $_.TamanhoTexto }) -join "`n"
    if ((Show-Msg ($script:T.confirmar1 -f $sel.Count, (Format-Size $sum), $lines) 'YesNo' 'Question' 'Yes') -ne 'Yes') { return }

    $risky = @($sel | Where-Object { $_.RiscoN -ge 2 })
    if ($risky.Count -gt 0) {
        $lines = ($risky | ForEach-Object { $script:T.linhaRisco -f $_.RiscoTexto, $_.Nome, $_.Consequencia }) -join "`n`n"
        if ((Show-Msg ($script:T.confirmar2 -f $lines) 'YesNo' 'Warning' 'No') -ne 'Yes') { return }
    }

    $restore = $false
    if ($script:IsAdmin -and @($sel | Where-Object { $_.RiscoN -eq 3 }).Count -gt 0) {
        $answer = Show-Msg $script:T.pontoRestauracao 'YesNoCancel' 'Question' 'Yes'
        if ($answer -eq 'Cancel') { return }
        $restore = ($answer -eq 'Yes')
    }

    Write-ACLog ("---- execucao: {0} itens{1}" -f $sel.Count, $(if ($script:IsDryRun) { ' (SIMULACAO)' } else { '' }))
    foreach ($it in @($sel | Where-Object { $_.Interativo })) {
        $it.Status = Invoke-Interactive $it
        $it.Selecionado = $false
    }
    $background = @($sel | Where-Object { -not $_.Interativo })
    if ($background.Count -gt 0) { Start-Job2 -Mode 'clean' -JobItems $background -RestorePoint $restore }
    else { Update-Total; Update-Disks }
}

function Restart-Elevated {
    $argLine = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}"' -f $script:SelfPath
    if ($script:IsDryRun) { $argLine += ' -DryRun' }
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList $argLine
        $script:Window.Close()
    } catch { [void](Show-Msg $script:T.uacCancelado 'OK' 'Warning') }
}

# Event handlers must never throw into the dispatcher.
function Invoke-Safe {
    param([scriptblock]$Action)
    try { & $Action }
    catch {
        Write-ACLog "ERRO na interface: $($_.Exception.Message)"
        [void](Show-Msg ($script:T.erro -f $_.Exception.Message) 'OK' 'Error')
    }
}

# --- startup ----------------------------------------------------------------

try {
    $script:Config = [IO.File]::ReadAllText((Join-Path $script:Root 'catalog.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
    $script:T = $script:Config.textos
    $script:IsAdmin = Test-ACAdmin

    $logDir = Join-Path $script:Root 'logs'
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
    $script:LogPath = Join-Path $logDir ('AutoCleaner_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    Initialize-ACEngine -Config $script:Config -LogPath $script:LogPath -DryRun $script:IsDryRun -Sync $null
    Write-ACLog ("Auto Cleaner iniciado. admin={0} simulacao={1}" -f $script:IsAdmin, $script:IsDryRun)

    $script:Window = [Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $script:Root 'src\MainWindow.xaml'), [Text.Encoding]::UTF8))
    $script:ListXaml = [IO.File]::ReadAllText((Join-Path $script:Root 'src\ListDialog.xaml'), [Text.Encoding]::UTF8)
    $script:UI = @{}
    foreach ($n in 'TxtDiscos', 'BtnAdmin', 'TxtAdmin', 'RbRapida', 'RbMedia', 'RbCompleta', 'TxtDescNivel', 'CmbRisco', 'Lista',
        'TxtTotal', 'BtnLog', 'BtnCancelar', 'BtnAnalisar', 'BtnExecutar', 'Barra', 'TxtStatus') {
        $script:UI[$n] = $script:Window.FindName($n)
    }
    if ($script:IsDryRun) { $script:Window.Title += $script:T.simulacao }
    $area = [Windows.SystemParameters]::WorkArea
    $script:Window.Width = [math]::Min($script:Window.Width, $area.Width - 20)
    $script:Window.Height = [math]::Min($script:Window.Height, $area.Height - 20)

    # Build the item list from the catalog.
    $levels = @{ rapida = 1; media = 2; completa = 3 }
    $risks = @{ baixo = 1; medio = 2; alto = 3 }
    $riskText = @{ baixo = $script:T.riscoBaixo; medio = $script:T.riscoMedio; alto = $script:T.riscoAlto }
    $script:Items = New-Object 'System.Collections.ObjectModel.ObservableCollection[ACItem]'
    $script:ById = @{}
    foreach ($d in $script:Config.itens) {
        if ($d.existe) {
            $p = Expand-ACPath $d.existe
            if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
        }
        if (-not $levels.ContainsKey([string]$d.nivel) -or -not $risks.ContainsKey([string]$d.risco)) { continue }
        $it = New-Object ACItem
        $it.Id = $d.id; $it.Categoria = $d.categoria; $it.Nome = $d.nome; $it.Descricao = $d.descricao
        $it.Consequencia = $d.consequencia; $it.Risco = $d.risco; $it.RiscoTexto = $riskText[[string]$d.risco]
        $it.NivelN = $levels[[string]$d.nivel]; $it.RiscoN = $risks[[string]$d.risco]
        $it.Admin = [bool]$d.admin
        $it.Interativo = ($d.tipo -eq 'interativo')
        $it.PreMarcar = ($d.marcarPorPadrao -ne $false)
        $it.Habilitado = -not ($it.Admin -and -not $script:IsAdmin)
        $it.Bytes = -1
        $it.TamanhoTexto = $script:Dash
        $it.Status = if ($it.Habilitado) { '' } else { $script:T.requerAdmin }
        $it.Dados = $d
        $script:Items.Add($it)
        $script:ById[$it.Id] = $it
    }
    Update-HibernationItem

    $script:Level = 1
    $script:MaxRisk = 3
    $script:Busy = $false
    $script:UI.Lista.ItemsSource = $script:Items
    $script:View = [Windows.Data.CollectionViewSource]::GetDefaultView($script:Items)
    $script:View.GroupDescriptions.Add((New-Object Windows.Data.PropertyGroupDescription 'Categoria'))
    $script:View.Filter = [Predicate[object]] { param($o) Test-Visible $o }

    if ($script:IsAdmin) {
        $script:UI.BtnAdmin.Visibility = 'Collapsed'
        $script:UI.TxtAdmin.Text = $script:T.adminSim
    } else { $script:UI.TxtAdmin.Text = $script:T.adminNao }
    Update-Disks

    # Background runspace + queue.
    $script:Sync = [hashtable]::Synchronized(@{
        Queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        EnginePath = (Join-Path $script:Root 'src\Engine.ps1')
        OptPath = (Join-Path $script:Root 'src\Optimizations.ps1')
        Config = $script:Config; LogPath = $script:LogPath; DryRun = $script:IsDryRun
        Mode = ''; Data = @(); Cancel = $false; Done = $false; Abort = $null; RestorePoint = $false
    })
    $script:Runspace = [runspacefactory]::CreateRunspace()
    $script:Runspace.ApartmentState = 'STA'
    $script:Runspace.ThreadOptions = 'ReuseThread'
    $script:Runspace.Open()
    $script:Runspace.SessionStateProxy.SetVariable('sync', $script:Sync)

    $script:Timer = New-Object Windows.Threading.DispatcherTimer
    $script:Timer.Interval = [TimeSpan]::FromMilliseconds(120)
    $script:Timer.Add_Tick({
        Invoke-Safe {
            $msg = $null
            while ($script:Sync.Queue.TryDequeue([ref]$msg)) { Receive-Message $msg }
            if ($script:Sync.Done -and $script:Sync.Queue.IsEmpty) {
                $script:Timer.Stop()
                Complete-Job
            }
        }
    })

    $script:UI.RbRapida.Add_Checked({ Invoke-Safe { Set-Level 1 } })
    $script:UI.RbMedia.Add_Checked({ Invoke-Safe { Set-Level 2 } })
    $script:UI.RbCompleta.Add_Checked({ Invoke-Safe { Set-Level 3 } })
    $script:UI.CmbRisco.Add_SelectionChanged({
        Invoke-Safe {
            $script:MaxRisk = $script:UI.CmbRisco.SelectedIndex + 1
            foreach ($it in $script:Items) { if (-not (Test-Visible $it)) { $it.Selecionado = $false } }
            $script:View.Refresh()
            Update-Total
        }
    })
    $script:UI.Lista.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler] { Invoke-Safe { Update-Total } })
    $script:UI.BtnAnalisar.Add_Click({ Invoke-Safe { Start-Scan } })
    $script:UI.BtnExecutar.Add_Click({ Invoke-Safe { Invoke-Execute } })
    $script:UI.BtnCancelar.Add_Click({ $script:Sync.Cancel = $true; $script:UI.BtnCancelar.IsEnabled = $false })
    $script:UI.BtnAdmin.Add_Click({ Invoke-Safe { Restart-Elevated } })
    $script:UI.BtnLog.Add_Click({ Invoke-Safe { Start-Process notepad.exe -ArgumentList ('"{0}"' -f $script:LogPath) } })
    $script:Window.Add_Loaded({ $script:UI.RbRapida.IsChecked = $true })
    $script:Window.Add_Closing({
        $script:Sync.Cancel = $true
        $script:Timer.Stop()
    })

    [void]$script:Window.ShowDialog()

    if ($script:PS) { try { $script:PS.Stop() } catch { } }
    $script:Runspace.Dispose()
    Write-ACLog 'Auto Cleaner encerrado.'
}
catch {
    $detail = "$($_.Exception.Message)`n$($_.ScriptStackTrace)"
    try { Write-ACLog "ERRO FATAL: $detail" } catch { }
    $text = if ($script:T) { $script:T.erroFatal -f $detail } else { $detail }
    [void][Windows.MessageBox]::Show($text, 'Auto Cleaner', 'OK', 'Error')
    exit 1
}
