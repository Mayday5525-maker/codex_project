#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms

$window = [Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'AssistantMover-GUI.xaml')))
$controls = @{}
foreach ($name in @('StatusBadge','TargetBox','BrowseTarget','SourceList','AddWorkspace','RemoveWorkspace','RunHint','LogBox','DryRunBox','RestoreButton','RunButton')) {
    $controls[$name] = $window.FindName($name)
}
$items = New-Object 'System.Collections.Generic.List[object]'
$script:process = $null
$script:logPosition = 0L
$script:outputPath = Join-Path $env:TEMP ('assistant-mover-gui-' + [guid]::NewGuid().ToString('N') + '.log')
$script:errorPath = $script:outputPath + '.err'
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(250)

function Add-SourceItem {
    param([string]$Id,[string]$App,[string]$Path,[string]$Kind)
    if ($items | Where-Object { $_.Path.Equals($Path,[StringComparison]::OrdinalIgnoreCase) }) { return }
    $exists = Test-Path -LiteralPath $Path -PathType Container
    $text = if ($exists) { "$App   |   $Path" } else { "$App   |   $Path   (未找到)" }
    $box = New-Object Windows.Controls.CheckBox
    $box.Content = $text
    $box.Tag = [PSCustomObject]@{ Id=$Id; App=$App; Path=$Path; Kind=$Kind }
    $box.IsChecked = $exists
    $box.IsEnabled = $exists
    [void]$controls.SourceList.Children.Add($box)
    $items.Add($box)
}

function Refresh-RunState {
    if (Test-Path -LiteralPath $script:outputPath) {
        $content = [IO.File]::ReadAllText($script:outputPath)
        if ($content.Length -gt $script:logPosition) {
            $controls.LogBox.AppendText($content.Substring([int]$script:logPosition))
            $script:logPosition = $content.Length
            $controls.LogBox.ScrollToEnd()
        }
    }
    if ($script:process -and -not $script:process.HasExited) { return }
    if ($script:process) {
        $script:process.Refresh()
        $controls.StatusBadge.Text = if ($script:process.ExitCode -eq 0) { '完成' } else { '有错误' }
        $controls.StatusBadge.Foreground = if ($script:process.ExitCode -eq 0) { [Windows.Media.Brushes]::SeaGreen } else { [Windows.Media.Brushes]::Firebrick }
        $controls.RunButton.IsEnabled = $true
        $controls.RestoreButton.IsEnabled = $true
        $controls.BrowseTarget.IsEnabled = $true
        $controls.AddWorkspace.IsEnabled = $true
        $controls.RemoveWorkspace.IsEnabled = $true
        $timer.Stop()
        $script:process.Dispose()
        $script:process = $null
        return
    }
}

function Start-Engine {
    param([string]$ActionName,[switch]$UseDryRun)
    $selected = @($items | Where-Object { $_.IsChecked -and $_.Tag.Kind -eq 'AppData' } | ForEach-Object { $_.Tag.Id })
    $workspaces = @($items | Where-Object { $_.IsChecked -and $_.Tag.Kind -eq 'Workspace' } | ForEach-Object { $_.Tag.Path })
    if ($ActionName -eq 'Migrate' -and $selected.Count -eq 0 -and $workspaces.Count -eq 0) {
        [Windows.MessageBox]::Show('请先选择至少一个现存目录。','Assistant Mover') | Out-Null
        return
    }
    if ($ActionName -eq 'Migrate' -and -not $UseDryRun) {
        $answer = [Windows.MessageBox]::Show('正式迁移会创建目标盘副本并将原路径替换为 junction。请先退出 TRAE CN、WorkBuddy、VS Code 和 Claude Code。继续吗？','确认迁移',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Warning)
        if ($answer -ne [Windows.MessageBoxResult]::Yes) { return }
    }
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'AssistantMover.ps1'),'-Action',$ActionName,'-TargetRoot',$controls.TargetBox.Text)
    if ($selected.Count -gt 0) { $arguments += '-Include'; $arguments += $selected }
    if ($workspaces.Count -gt 0) { $arguments += '-Workspace'; $arguments += $workspaces }
    if ($UseDryRun) { $arguments += '-DryRun' }
    $quoted = @($arguments | ForEach-Object { ([string][char]34) + ([string]$_).Replace([string][char]34,([string][char]92+[char]34)) + [string][char]34 }) -join ([string][char]32)
    Remove-Item -LiteralPath $script:outputPath,$script:errorPath -Force -ErrorAction SilentlyContinue
    $script:logPosition = 0L
    $controls.LogBox.Clear()
    $controls.StatusBadge.Text = if ($UseDryRun) { '演练中' } else { '运行中' }
    $controls.StatusBadge.Foreground = [Windows.Media.Brushes]::DarkOrange
    $controls.RunButton.IsEnabled = $false
    $controls.RestoreButton.IsEnabled = $false
    $controls.BrowseTarget.IsEnabled = $false
    $controls.AddWorkspace.IsEnabled = $false
    $controls.RemoveWorkspace.IsEnabled = $false
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $PSHOME 'powershell.exe'
    $info.Arguments = $quoted
    $info.WorkingDirectory = $PSScriptRoot
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $script:process = New-Object Diagnostics.Process
    $script:process.StartInfo = $info
    $script:process.add_OutputDataReceived({ param($sender,$event) if ($event.Data) { [IO.File]::AppendAllText($script:outputPath,$event.Data+[Environment]::NewLine) } })
    $script:process.add_ErrorDataReceived({ param($sender,$event) if ($event.Data) { [IO.File]::AppendAllText($script:errorPath,$event.Data+[Environment]::NewLine) } })
    [void]$script:process.Start()
    $script:process.BeginOutputReadLine()
    $script:process.BeginErrorReadLine()
    $timer.Start()
}

$roaming = [Environment]::GetFolderPath('ApplicationData')
$local = [Environment]::GetFolderPath('LocalApplicationData')
$profile = $env:USERPROFILE
$defaultSpecs = @(
    @{Id='trae-roaming';App='TRAE CN';Path=(Join-Path $roaming 'Trae CN')},
    @{Id='trae-local';App='TRAE CN';Path=(Join-Path $local 'Trae CN')},
    @{Id='trae-user';App='TRAE CN';Path=(Join-Path $profile '.trae')},
    @{Id='workbuddy-roaming';App='WorkBuddy';Path=(Join-Path $roaming 'WorkBuddy')},
    @{Id='workbuddy-tencent';App='WorkBuddy';Path=(Join-Path $roaming 'Tencent\WorkBuddy')},
    @{Id='workbuddy-local';App='WorkBuddy';Path=(Join-Path $local 'WorkBuddy')},
    @{Id='vscode-roaming';App='VS Code';Path=(Join-Path $roaming 'Code')},
    @{Id='vscode-extensions';App='VS Code';Path=(Join-Path $profile '.vscode\extensions')},
    @{Id='vscode-insiders-roaming';App='VS Code Insiders';Path=(Join-Path $roaming 'Code - Insiders')},
    @{Id='vscode-insiders-extensions';App='VS Code Insiders';Path=(Join-Path $profile '.vscode-insiders\extensions')},
    @{Id='claude-code';App='Claude Code';Path=(Join-Path $profile '.claude')}
)
foreach ($spec in $defaultSpecs) { Add-SourceItem -Id $spec.Id -App $spec.App -Path $spec.Path -Kind 'AppData' }

$controls.BrowseTarget.Add_Click({
    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    $dialog.SelectedPath = $controls.TargetBox.Text
    $dialog.ShowNewFolderButton = $true
    if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) { $controls.TargetBox.Text = $dialog.SelectedPath }
})
$controls.AddWorkspace.Add_Click({
    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    $dialog.Description = '选择一个真实项目工作区文件夹'
    if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
        $path = [IO.Path]::GetFullPath($dialog.SelectedPath).TrimEnd('\')
        $leaf = Split-Path -Leaf $path
        $digest = [BitConverter]::ToString(([Security.Cryptography.SHA256]::Create()).ComputeHash([Text.Encoding]::UTF8.GetBytes($path))).Replace('-','').Substring(0,8).ToLowerInvariant()
        Add-SourceItem -Id ('workspace-' + $leaf + '-' + $digest) -App '工作区' -Path $path -Kind 'Workspace'
    }
})
$controls.RemoveWorkspace.Add_Click({
    foreach ($box in @($items | Where-Object { $_.IsSelected -and $_.Tag.Kind -eq 'Workspace' })) { [void]$controls.SourceList.Children.Remove($box); [void]$items.Remove($box) }
})
$controls.DryRunBox.Add_Checked({ $controls.RunButton.Content='开始演练'; $controls.RunHint.Text='演练不会更改文件'; $controls.RunButton.Background=[Windows.Media.Brushes]::SeaGreen })
$controls.DryRunBox.Add_Unchecked({ $controls.RunButton.Content='开始迁移'; $controls.RunHint.Text='正式迁移前请退出应用'; $controls.RunButton.Background=[Windows.Media.Brushes]::Firebrick })
$controls.RunButton.Add_Click({ if ($controls.DryRunBox.IsChecked) { Start-Engine -ActionName 'Migrate' -UseDryRun } else { Start-Engine -ActionName 'Migrate' } })
$controls.RestoreButton.Add_Click({
    $answer = [Windows.MessageBox]::Show('这将把数据复制回原路径并移除 junction，目标盘副本仍保留。继续吗？','确认恢复',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Warning)
    if ($answer -eq [Windows.MessageBoxResult]::Yes) { Start-Engine -ActionName 'Restore' }
})
$timer.Add_Tick({ Refresh-RunState })
$window.Add_Closing({ param($sender,$event) if ($script:process -and -not $script:process.HasExited) { $event.Cancel=$true; [Windows.MessageBox]::Show('迁移仍在运行，请等待操作完成。','Assistant Mover') | Out-Null } })
[void]$window.ShowDialog()
