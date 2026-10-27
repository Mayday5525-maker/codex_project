#Requires -Version 5.1
[CmdletBinding()]
param([switch]$SelfTest,[switch]$SmokeTest,[string]$PreviewImage)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml,System.Windows.Forms
$window = [Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'AssistantMover-GUI.xaml')))
$controls = @{}
foreach ($name in @('StatusPanel','StatusBadge','DriveBox','FolderBox','TargetPreview','SourceList','CustomPathBox','RefreshSizes','AddWorkspace','RemoveWorkspace','RunHint','LogBox','DryRunBox','RestoreButton','RunButton','ExitButton')) {
    $controls[$name] = $window.FindName($name)
    if (-not $controls[$name]) { throw "Missing XAML control: $name" }
}
$items = New-Object 'System.Collections.Generic.List[object]'
$script:process = $null
$script:sizeJob = $null
$script:sessionRoot = Join-Path ([IO.Path]::GetTempPath()) ('dev-mover-gui-' + [guid]::NewGuid().ToString('N'))
$script:outputPath = Join-Path $script:sessionRoot 'engine.log'
$script:errorPath = Join-Path $script:sessionRoot 'engine.err'
$script:requestPath = Join-Path $script:sessionRoot 'request.json'
$script:logPositions = @{}
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(250)
function Append-Log {
    param([string]$Message)
    $controls.LogBox.AppendText($Message + [Environment]::NewLine)
    $controls.LogBox.ScrollToEnd()
}
function Set-Status {
    param([string]$Text,[string]$Color='#129962',[string]$Fill='#D3F0DF')
    $controls.StatusBadge.Text = $Text
    $converter = New-Object Windows.Media.BrushConverter
    $controls.StatusBadge.Foreground = $converter.ConvertFromString($Color)
    $controls.StatusPanel.Background = $converter.ConvertFromString($Fill)
}
function Update-SourceItem {
    param($Box,[string]$SizeLabel)
    $meta = $Box.Tag
    $entry = Get-Item -LiteralPath $meta.Path -Force -ErrorAction SilentlyContinue
    $exists = $null -ne $entry -and $entry.PSIsContainer
    $linked = $exists -and [bool]($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)
    $status = if (-not $exists) { '[不存在]' } elseif ($linked) { '[已迁移(联接)]' } elseif ($SizeLabel) { '[' + $SizeLabel + ']' } else { '[大小待刷新]' }
    $Box.Content = '{0} — {1}  {2}' -f $meta.App,$meta.Path,$status
    $Box.ToolTip = if ($linked) { $meta.Path + ' -> ' + (@($entry.Target) -join ', ') } else { $meta.Path }
    $Box.IsEnabled = $exists
    if (-not $exists -or $linked) { $Box.IsChecked = $false }
}
function Add-SourceItem {
    param([string]$Id,[string]$App,[string]$Path,[string]$Kind)
    if (@($items | Where-Object { $_.Tag.Path.Equals($Path,[StringComparison]::OrdinalIgnoreCase) }).Count) { return }
    $box = New-Object Windows.Controls.CheckBox
    $box.Tag = [PSCustomObject]@{ Id=$Id; App=$App; Path=$Path; Kind=$Kind }
    $box.IsChecked = $true
    Update-SourceItem -Box $box
    [void]$controls.SourceList.Children.Add($box)
    $items.Add($box)
}
function Get-TargetRoot {
    if (-not $controls.DriveBox.SelectedItem) { throw '请先选择可用的本机 NTFS 目标盘。' }
    $folder = $controls.FolderBox.Text.Trim()
    if (-not $folder -or $folder -in @('.','..') -or $folder.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $folder.EndsWith('.') -or $folder -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') { throw '请输入有效的单级文件夹名称，例如 DevData。' }
    return Join-Path $controls.DriveBox.SelectedItem.Root $folder
}
function Update-TargetPreview {
    try { $controls.TargetPreview.Text = '迁移目标：' + (Get-TargetRoot) }
    catch { $controls.TargetPreview.Text = $_.Exception.Message }
}
function Set-Busy {
    param([bool]$Busy)
    foreach ($name in @('RunButton','RestoreButton','DriveBox','FolderBox','RefreshSizes','CustomPathBox','AddWorkspace','RemoveWorkspace','DryRunBox','SourceList')) { $controls[$name].IsEnabled = -not $Busy }
}
function Read-EngineLog {
    foreach ($path in @($script:outputPath,$script:errorPath)) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try {
            $stream = [IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
            $reader = New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true)
            try { $content = $reader.ReadToEnd() } finally { $reader.Dispose() }
            $position = if ($script:logPositions.ContainsKey($path)) { [int]$script:logPositions[$path] } else { 0 }
            if ($content.Length -gt $position) {
                $controls.LogBox.AppendText($content.Substring($position))
                $script:logPositions[$path] = $content.Length
                $controls.LogBox.ScrollToEnd()
            }
        } catch [IO.IOException] { }
    }
}
function Refresh-RunState {
    if ($script:sizeJob -and $script:sizeJob.State -in @('Completed','Failed','Stopped')) {
        try {
            $sizes = @(Receive-Job -Job $script:sizeJob -ErrorAction Stop)
            foreach ($size in $sizes) { foreach ($box in $items) { if ($box.Tag.Id -eq $size.Id) { Update-SourceItem -Box $box -SizeLabel $size.Label } } }
            Append-Log '目录大小已刷新（未跟随内部联接）。'
        } catch { Append-Log ('刷新大小失败：' + $_.Exception.Message) }
        Remove-Job -Job $script:sizeJob -Force
        $script:sizeJob = $null
        Set-Busy -Busy $false
        Set-Status -Text '就绪'
    }
    Read-EngineLog
    if (-not $script:process -or -not $script:process.HasExited) { return }
    $script:process.WaitForExit()
    $script:process.Refresh()
    Read-EngineLog
    if ($script:process.ExitCode -eq 0) { Set-Status -Text '完成' } else { Set-Status -Text '有错误' -Color '#B53645' -Fill '#FCE3E6' }
    Append-Log ('子进程退出码：' + $script:process.ExitCode)
    $script:process.Dispose()
    $script:process = $null
    Set-Busy -Busy $false
    foreach ($box in $items) { Update-SourceItem -Box $box }
}
function Start-Engine {
    param([string]$ActionName,[switch]$UseDryRun,[switch]$SkipConfirmation)
    try {
        $targetRoot = Get-TargetRoot
        $selected = @($items | Where-Object { $_.IsChecked -and $_.Tag.Kind -eq 'AppData' } | ForEach-Object { $_.Tag.Id })
        $workspaces = @($items | Where-Object { $_.IsChecked -and $_.Tag.Kind -eq 'Workspace' } | ForEach-Object { $_.Tag.Path })
        if ($ActionName -eq 'Migrate' -and $selected.Count -eq 0 -and $workspaces.Count -eq 0) { throw '请先勾选至少一个现存目录。' }
        if (-not $SkipConfirmation -and -not $UseDryRun) {
            $message = if ($ActionName -eq 'Restore') { '将把当前目标盘数据恢复到原路径，目标盘数据仍保留。请先退出所有相关应用。继续吗？' } else { '正式迁移前请退出 OpenAI Codex、TRAE CN、WorkBuddy、VS Code、Claude Code 和相关终端。将先复制和校验，再创建目录联接。继续吗？' }
            if ([Windows.MessageBox]::Show($message,'Dev Mover · 确认',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Warning) -ne [Windows.MessageBoxResult]::Yes) { return }
        }
        [IO.Directory]::CreateDirectory($script:sessionRoot) | Out-Null
        $request = [ordered]@{ Action=$ActionName; TargetRoot=$targetRoot; Include=@($selected); Workspace=@($workspaces); DryRun=[bool]$UseDryRun }
        [IO.File]::WriteAllText($script:requestPath,($request | ConvertTo-Json -Depth 4),(New-Object Text.UTF8Encoding($false)))
        $script:logPositions = @{}
        $controls.LogBox.Clear()
        Append-Log ('目标：' + $targetRoot)
        Append-Log ('应用目录：{0}；自定义目录：{1}' -f $selected.Count,$workspaces.Count)
        Set-Busy -Busy $true
        Set-Status -Text $(if ($UseDryRun) { '演练中' } else { '运行中' }) -Color '#A16A0D' -Fill '#FFF0CF'
        $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -RequestPath "{1}"' -f (Join-Path $PSScriptRoot 'AssistantMover.ps1'),$script:requestPath
        $script:process = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -WorkingDirectory $PSScriptRoot -WindowStyle Hidden -RedirectStandardOutput $script:outputPath -RedirectStandardError $script:errorPath -PassThru
        $null = $script:process.Handle
    } catch {
        Set-Busy -Busy $false
        Set-Status -Text '有错误' -Color '#B53645' -Fill '#FCE3E6'
        Append-Log $_.Exception.Message
        if ($SkipConfirmation) { throw }
        [Windows.MessageBox]::Show($_.Exception.Message,'Dev Mover',[Windows.MessageBoxButton]::OK,[Windows.MessageBoxImage]::Error) | Out-Null
    }
}
function Start-SizeRefresh {
    if ($script:sizeJob -or $script:process) { return }
    foreach ($box in $items) { Update-SourceItem -Box $box }
    $paths = @($items | ForEach-Object { [PSCustomObject]@{ Id=$_.Tag.Id; Path=$_.Tag.Path } }) | ConvertTo-Json -Compress
    Set-Busy -Busy $true
    Set-Status -Text '扫描中' -Color '#A16A0D' -Fill '#FFF0CF'
    $script:sizeJob = Start-Job -ArgumentList $paths -ScriptBlock {
        param($Json)
        foreach ($source in ($Json | ConvertFrom-Json)) {
            $root = Get-Item -LiteralPath $source.Path -Force -ErrorAction SilentlyContinue
            if (-not $root -or -not $root.PSIsContainer -or ($root.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
            $bytes = [long]0
            $stack = New-Object 'System.Collections.Generic.Stack[string]'
            $stack.Push($source.Path)
            try {
                while ($stack.Count -gt 0) {
                    foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($stack.Pop())) {
                        $attr = [IO.File]::GetAttributes($path)
                        if ($attr -band [IO.FileAttributes]::ReparsePoint) { continue }
                        if ($attr -band [IO.FileAttributes]::Directory) { $stack.Push($path) } else { $bytes += (New-Object IO.FileInfo($path)).Length }
                    }
                }
                $label = if ($bytes -ge 1GB) { '{0:N2} GB' -f ($bytes/1GB) } elseif ($bytes -ge 1MB) { '{0:N1} MB' -f ($bytes/1MB) } else { '{0:N1} KB' -f ($bytes/1KB) }
            } catch { $label = '无法完整读取' }
            [PSCustomObject]@{ Id=$source.Id; Label=$label }
        }
    }
}
function Add-CustomDirectory {
    $path = $controls.CustomPathBox.Text.Trim().Trim('"')
    if (-not $path) {
        $dialog = New-Object Windows.Forms.FolderBrowserDialog
        $dialog.Description = '选择要迁移的实际项目工作区或自定义目录'
        try { if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return }; $path = $dialog.SelectedPath } finally { $dialog.Dispose() }
    }
    try {
        $full = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($path)).TrimEnd('\')
        if (-not (Test-Path -LiteralPath $full -PathType Container)) { throw "目录不存在：$full" }
        if ($full -eq [IO.Path]::GetPathRoot($full).TrimEnd('\')) { throw '不能选择整块磁盘。' }
        $hasher = [Security.Cryptography.SHA256]::Create()
        try { $digest = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($full))).Replace('-','').Substring(0,8).ToLowerInvariant() } finally { $hasher.Dispose() }
        Add-SourceItem -Id ('workspace-' + (Split-Path -Leaf $full) + '-' + $digest) -App '自定义工作区' -Path $full -Kind 'Workspace'
        $controls.CustomPathBox.Clear()
    } catch { [Windows.MessageBox]::Show($_.Exception.Message,'Dev Mover') | Out-Null }
}
# One source catalog shared with the engine, including CODEX_HOME if configured.
$catalogText = & (Join-Path $PSHOME 'powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'AssistantMover.ps1') -Action Sources
if ($LASTEXITCODE -ne 0) { throw ('读取应用目录失败：' + ($catalogText -join [Environment]::NewLine)) }
$defaultSpecs = ($catalogText -join [Environment]::NewLine) | ConvertFrom-Json
foreach ($spec in $defaultSpecs) { Add-SourceItem -Id $spec.Id -App $spec.App -Path $spec.Path -Kind 'AppData' }
$drives = @([IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and $_.DriveType -eq 'Fixed' -and $_.DriveFormat -eq 'NTFS' } | Sort-Object Name)
foreach ($drive in $drives) {
    $display = '{0}  ·  剩余 {1:N1} GB' -f $drive.Name,($drive.AvailableFreeSpace/1GB)
    [void]$controls.DriveBox.Items.Add([PSCustomObject]@{ Root=$drive.Name; Display=$display })
}
$preferred = @($controls.DriveBox.Items | Where-Object { $_.Root -eq 'G:\' })
if (-not $preferred.Count) { $preferred = @($controls.DriveBox.Items | Where-Object { $_.Root -ne ($env:SystemDrive + '\') }) }
if ($preferred.Count) { $controls.DriveBox.SelectedItem = $preferred[0] } elseif ($controls.DriveBox.Items.Count) { $controls.DriveBox.SelectedIndex = 0 }
Update-TargetPreview
Append-Log 'Dev Mover v1.1 已就绪。默认启用演练模式。'
Append-Log ("已载入 $($defaultSpecs.Count) 个应用目录；工作区可手动添加。")
$controls.DriveBox.Add_SelectionChanged({ Update-TargetPreview })
$controls.FolderBox.Add_TextChanged({ Update-TargetPreview })
$controls.AddWorkspace.Add_Click({ Add-CustomDirectory })
$controls.RemoveWorkspace.Add_Click({ foreach ($box in @($items | Where-Object { $_.Tag.Kind -eq 'Workspace' })) { [void]$controls.SourceList.Children.Remove($box); [void]$items.Remove($box) } })
$controls.RefreshSizes.Add_Click({ Start-SizeRefresh })
$controls.DryRunBox.Add_Checked({ $controls.RunButton.Content='开始演练'; $controls.RunHint.Text='演练不会更改文件' })
$controls.DryRunBox.Add_Unchecked({ $controls.RunButton.Content='开始迁移'; $controls.RunHint.Text='正式迁移前请退出相关应用' })
$controls.RunButton.Add_Click({ if ($controls.DryRunBox.IsChecked) { Start-Engine -ActionName 'Migrate' -UseDryRun } else { Start-Engine -ActionName 'Migrate' } })
$controls.RestoreButton.Add_Click({ Start-Engine -ActionName 'Restore' })
$controls.ExitButton.Add_Click({ $window.Close() })
$timer.Add_Tick({ Refresh-RunState })
$window.Add_Closing({
    param($sender,$event)
    if ($script:process -and -not $script:process.HasExited) { $event.Cancel=$true; [Windows.MessageBox]::Show('操作仍在运行，请等待完成。','Dev Mover') | Out-Null }
})
$window.Add_Closed({
    $timer.Stop()
    if ($script:sizeJob) { Stop-Job -Job $script:sizeJob; Remove-Job -Job $script:sizeJob -Force }
    if ($script:process) { $script:process.Dispose() }
    if (Test-Path -LiteralPath $script:sessionRoot) { Remove-Item -LiteralPath $script:sessionRoot -Recurse -Force }
})
if ($SelfTest -or $SmokeTest) {
    if ($items.Count -ne $defaultSpecs.Count -or @($defaultSpecs | Where-Object { $_.App -eq 'OpenAI Codex' }).Count -lt 5) { throw 'Directory catalog initialization failed.' }
    if ($controls.DriveBox.Items.Count -gt 0 -and -not $controls.DriveBox.SelectedItem.Display.Contains('GB')) { throw 'Drive display failed.' }
    Write-Output "GUI initialization passed: $($items.Count) sources including Codex; $($controls.DriveBox.Items.Count) NTFS drives."
}
if ($SelfTest -and -not $SmokeTest) { exit 0 }
if ($SmokeTest) {
    [IO.Directory]::CreateDirectory($script:sessionRoot) | Out-Null
    $fixture = Join-Path $script:sessionRoot 'fixture space 中文'
    [IO.Directory]::CreateDirectory($fixture) | Out-Null
    [IO.File]::WriteAllText((Join-Path $fixture 'sample.txt'),'GUI smoke test')
    foreach ($box in $items) { $box.IsChecked=$false }
    Add-SourceItem -Id 'smoke-fixture' -App '测试工作区' -Path $fixture -Kind 'Workspace'
    $controls.FolderBox.Text = 'DevMoverSmokeTarget'
    Start-Engine -ActionName 'Migrate' -UseDryRun -SkipConfirmation
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ($script:process -and [DateTime]::UtcNow -lt $deadline) { Refresh-RunState; Start-Sleep -Milliseconds 80 }
    if ($script:process) { throw 'GUI engine smoke test timed out.' }
    if ($controls.StatusBadge.Text -ne '完成' -or -not $controls.LogBox.Text.Contains($fixture) -or $controls.LogBox.Text.Contains('codex-home |')) { throw ('GUI selection/dry-run smoke test failed: ' + $controls.LogBox.Text) }
    [IO.File]::WriteAllText($script:requestPath,'{invalid request')
    $script:logPositions = @{}
    $argsText = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -RequestPath "{1}"' -f (Join-Path $PSScriptRoot 'AssistantMover.ps1'),$script:requestPath
    $script:process = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $argsText -WindowStyle Hidden -RedirectStandardOutput $script:outputPath -RedirectStandardError $script:errorPath -PassThru
        $null = $script:process.Handle
    while ($script:process -and [DateTime]::UtcNow -lt $deadline) { Refresh-RunState; Start-Sleep -Milliseconds 80 }
    if ($script:process -or $controls.StatusBadge.Text -ne '有错误') { throw 'GUI error visibility smoke test failed.' }
    foreach ($box in @($items | Where-Object { $_.Tag.Kind -eq 'Workspace' })) { [void]$controls.SourceList.Children.Remove($box); [void]$items.Remove($box) }
    foreach ($box in $items) { $box.IsChecked=$true; Update-SourceItem -Box $box }
    $controls.FolderBox.Text = 'DevData'
    $controls.LogBox.Clear()
    Append-Log 'Dev Mover v1.1 已就绪。默认启用演练模式。'
    Append-Log 'GUI 子进程演练、目录选择和错误显示自检通过。'
    Set-Status -Text '就绪'
    if ($PreviewImage) {
        $window.Show()
        $window.UpdateLayout()
        $surface = $window.Content
        $width = [int]$surface.ActualWidth
        $height = [int]$surface.ActualHeight
        $visual = New-Object Windows.Media.DrawingVisual
        $drawing = $visual.RenderOpen()
        $drawing.DrawRectangle($window.Background,$null,(New-Object Windows.Rect(0,0,$width,$height)))
        $drawing.DrawRectangle((New-Object Windows.Media.VisualBrush($surface)),$null,(New-Object Windows.Rect(0,0,$width,$height)))
        $drawing.Close()
        $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap($width,$height,96,96,[Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($visual)
        $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $file = [IO.File]::Create([IO.Path]::GetFullPath($PreviewImage))
        try { $encoder.Save($file) } finally { $file.Dispose() }
    }
    $window.Close()
    Write-Output 'GUI smoke tests passed: child-process dry run, workspace-only selection, visible errors, rendered layout.'
    exit 0
}
$timer.Start()
[void]$window.ShowDialog()
