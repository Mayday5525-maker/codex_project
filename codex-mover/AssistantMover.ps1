#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Plan','Migrate','Restore','SelfTest')]
    [string]$Action = 'Plan',
    [string]$TargetRoot,
    [string[]]$Include = @(),
    [string[]]$Workspace = @(),
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Version = '1.0.0'
$script:LogPath = $null
$script:StateName = 'assistant-mover-state.json'

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')] [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Output $line
    if ($script:LogPath) { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 }
}

function Get-DefaultSpecs {
    $roaming = [Environment]::GetFolderPath('ApplicationData')
    $local = [Environment]::GetFolderPath('LocalApplicationData')
    $profile = $env:USERPROFILE
    $specs = @(
        @{ Id='trae-roaming'; App='TRAE CN'; Path=(Join-Path $roaming 'Trae CN') },
        @{ Id='trae-local'; App='TRAE CN'; Path=(Join-Path $local 'Trae CN') },
        @{ Id='trae-user'; App='TRAE CN'; Path=(Join-Path $profile '.trae') },
        @{ Id='workbuddy-roaming'; App='WorkBuddy'; Path=(Join-Path $roaming 'WorkBuddy') },
        @{ Id='workbuddy-tencent'; App='WorkBuddy'; Path=(Join-Path $roaming 'Tencent\WorkBuddy') },
        @{ Id='workbuddy-local'; App='WorkBuddy'; Path=(Join-Path $local 'WorkBuddy') },
        @{ Id='vscode-roaming'; App='VS Code'; Path=(Join-Path $roaming 'Code') },
        @{ Id='vscode-extensions'; App='VS Code'; Path=(Join-Path $profile '.vscode\extensions') },
        @{ Id='vscode-insiders-roaming'; App='VS Code Insiders'; Path=(Join-Path $roaming 'Code - Insiders') },
        @{ Id='vscode-insiders-extensions'; App='VS Code Insiders'; Path=(Join-Path $profile '.vscode-insiders\extensions') },
        @{ Id='claude-code'; App='Claude Code'; Path=(Join-Path $profile '.claude') }
    )
    foreach ($spec in $specs) {
        $spec['Kind'] = 'AppData'
        $spec['Display'] = '{0}  |  {1}' -f $spec.App, $spec.Path
        $spec['Target'] = Join-Path (Join-Path $TargetRoot $spec.App.Replace(' ','-')) $spec.Id
    }
    foreach ($path in $Workspace) {
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw "工作区不存在：$path" }
        $full = [IO.Path]::GetFullPath($path).TrimEnd('\')
        $leaf = Split-Path -Leaf $full
        $digest = [BitConverter]::ToString(([Security.Cryptography.SHA256]::Create()).ComputeHash([Text.Encoding]::UTF8.GetBytes($full))).Replace('-','').Substring(0,8).ToLowerInvariant()
        $id = 'workspace-' + $leaf + '-' + $digest
        $specs += @{ Id=$id; App='Workspaces'; Path=$full; Kind='Workspace'; Display=('工作区  |  {0}' -f $full); Target=(Join-Path (Join-Path $TargetRoot 'Workspaces') $id) }
    }
    return $specs
}

function Test-IsReparsePoint {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    return ($null -ne $item -and [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint))
}

function Get-TreeManifest {
    param([string]$Root)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $directories = New-Object 'System.Collections.Generic.List[string]'
    $files = New-Object 'System.Collections.Generic.List[object]'
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($rootFull)
    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        foreach ($item in [IO.Directory]::EnumerateFileSystemEntries($current)) {
            $attributes = [IO.File]::GetAttributes($item)
            if ($attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            $relative = $item.Substring($rootFull.Length).TrimStart('\')
            if ($attributes -band [IO.FileAttributes]::Directory) {
                $directories.Add($relative)
                $stack.Push($item)
            } else {
                $info = New-Object IO.FileInfo($item)
                $hash = (Get-FileHash -LiteralPath $item -Algorithm SHA256).Hash
                $files.Add([PSCustomObject]@{ Path=$relative; Length=$info.Length; Hash=$hash })
            }
        }
    }
    $dirs = @($directories | Sort-Object -Culture en-US)
    $fileList = @($files | Sort-Object Path)
    $bytes = [long]0
    foreach ($file in $fileList) { $bytes += [long]$file.Length }
    return [PSCustomObject]@{ Directories=$dirs; Files=$fileList; FileCount=$fileList.Count; DirectoryCount=$dirs.Count; Bytes=$bytes }
}

function Compare-Manifests {
    param($SourceManifest, $TargetManifest)
    $differences = New-Object 'System.Collections.Generic.List[string]'
    if ($SourceManifest.DirectoryCount -ne $TargetManifest.DirectoryCount) { $differences.Add('directory count') }
    $targetDirectories = @{}
    foreach ($directory in $TargetManifest.Directories) { $targetDirectories[$directory] = $true }
    foreach ($directory in $SourceManifest.Directories) {
        if (-not $targetDirectories.ContainsKey($directory)) { $differences.Add('directory: ' + $directory) }
    }
    if ($SourceManifest.FileCount -ne $TargetManifest.FileCount) { $differences.Add('file count') }
    if ($SourceManifest.Bytes -ne $TargetManifest.Bytes) { $differences.Add('total bytes') }
    $targetFiles = @{}
    foreach ($file in $TargetManifest.Files) { $targetFiles[$file.Path] = $file }
    foreach ($file in $SourceManifest.Files) {
        if (-not $targetFiles.ContainsKey($file.Path)) { $differences.Add('missing: ' + $file.Path); continue }
        $other = $targetFiles[$file.Path]
        if ($file.Length -ne $other.Length) { $differences.Add('size: ' + $file.Path) }
        elseif ($file.Hash -ne $other.Hash) { $differences.Add('hash: ' + $file.Path) }
    }
    return @($differences)
}

function Get-CheckedSources {
    param([hashtable[]]$Specs)
    $chosen = @($Specs | Where-Object {
        (($_.Kind -eq 'Workspace') -or (Test-Path -LiteralPath $_.Path -PathType Container)) -and
        (($Include.Count -eq 0) -or ($Include -contains $_.Id) -or ($Include -contains $_.App))
    })
    $ids = @{}
    $targets = @{}
    foreach ($spec in $chosen) {
        if ($ids.ContainsKey($spec.Id)) { throw "重复的迁移项目 ID：$($spec.Id)" }
        $ids[$spec.Id] = $true
        $source = [IO.Path]::GetFullPath($spec.Path).TrimEnd('\')
        $target = [IO.Path]::GetFullPath($spec.Target).TrimEnd('\')
        if ($targets.ContainsKey($target.ToLowerInvariant())) { throw "多个项目映射到了同一目标：$target" }
        $targets[$target.ToLowerInvariant()] = $true
        if ($source.Equals($target,[StringComparison]::OrdinalIgnoreCase) -or $target.StartsWith($source + '\',[StringComparison]::OrdinalIgnoreCase) -or $source.StartsWith($target + '\',[StringComparison]::OrdinalIgnoreCase)) { throw "源与目标路径不能互相包含：$source -> $target" }
        $spec.Path = $source
        $spec.Target = $target
    }
    return $chosen
}

function Get-RunningAppNames {
    $known = @('Trae','Trae CN','WorkBuddy','Code','Code - Insiders','Claude')
    $running = @()
    foreach ($name in $known) {
        if (Get-Process -Name $name -ErrorAction SilentlyContinue) { $running += $name }
    }
    return @($running | Sort-Object -Unique)
}

function Test-TargetDrive {
    param([string]$Root, [long]$RequiredBytes)
    $full = [IO.Path]::GetFullPath($Root)
    $drive = [IO.Path]::GetPathRoot($full)
    if (-not $drive -or $drive.Length -lt 2 -or $drive[1] -ne ':') { throw '目标必须是本机固定磁盘上的路径。' }
    $deviceId = $drive.Substring(0,2)
    $filter = 'DeviceID=' + [char]39 + $deviceId + [char]39
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter $filter
    if (-not $disk -or $disk.DriveType -ne 3) { throw "目标盘 $drive 不是本机固定磁盘。" }
    if ($disk.FileSystem -ne 'NTFS') { throw "目标盘必须为 NTFS，当前格式：$($disk.FileSystem)" }
    if ([long]$disk.FreeSpace -lt $RequiredBytes) { throw ('目标盘空间不足；需要 {0:N1} GB，剩余 {1:N1} GB。' -f ($RequiredBytes / 1GB), ([long]$disk.FreeSpace / 1GB)) }
    return $drive
}

function Invoke-Robocopy {
    param([string]$Source, [string]$Destination)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $arguments = @($Source,$Destination,'/E','/COPY:DAT','/DCOPY:DAT','/XJ','/SL','/R:1','/W:1','/NP','/NFL','/NDL','/NJH','/NJS')
    $process = Start-Process -FilePath 'robocopy.exe' -ArgumentList $arguments -NoNewWindow -Wait -PassThru
    if ($process.ExitCode -ge 8) { throw "robocopy 失败，退出码：$($process.ExitCode)" }
}

function Get-JunctionTarget {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item -or -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $null }
    $target = @($item.Target)[0]
    if ($target) { return [IO.Path]::GetFullPath([string]$target).TrimEnd('\') }
    return $null
}

function New-Junction {
    param([string]$Link, [string]$Target)
    New-Item -ItemType Junction -Path $Link -Target $Target -ErrorAction Stop | Out-Null
    $actual = Get-JunctionTarget -Path $Link
    if (-not $actual -or -not $actual.Equals([IO.Path]::GetFullPath($Target).TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)) { throw "Junction 校验失败：$Link" }
}

function Remove-JunctionOnly {
    param([string]$Path, [string]$ExpectedTarget)
    $actual = Get-JunctionTarget -Path $Path
    if (-not $actual) { throw "拒绝删除非 junction 路径：$Path" }
    if (-not $actual.Equals([IO.Path]::GetFullPath($ExpectedTarget).TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)) { throw "junction 目标与预期不一致，拒绝操作：$Path" }
    [IO.Directory]::Delete($Path,$false)
}

function Write-State {
    param([string]$Path, $State)
    $temp = $Path + '.tmp'
    $json = $State | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($temp,$json,(New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp,$Path,$null) } else { [IO.File]::Move($temp,$Path) }
}

function Invoke-Plan {
    param([hashtable[]]$Specs)
    $sources = @(Get-CheckedSources -Specs $Specs)
    if ($sources.Count -eq 0) { Write-Log '没有找到符合条件的源目录。'; return }
    foreach ($spec in $sources) {
        $isJunction = $null -ne (Get-JunctionTarget -Path $spec.Path)
        if ($isJunction) {
            Write-Log ('已是联接，跳过  {0} -> {1}' -f $spec.Path,(Get-JunctionTarget -Path $spec.Path)) 'WARN'
            continue
        }
        $manifest = Get-TreeManifest -Root $spec.Path
        Write-Log ('{0} | {1} files, {2} dirs, {3:N2} GB | {4} -> {5}' -f $spec.Id,$manifest.FileCount,$manifest.DirectoryCount,($manifest.Bytes / 1GB),$spec.Path,$spec.Target)
    }
}

function Invoke-Migration {
    param([hashtable[]]$Specs)
    if (-not $TargetRoot) { throw '请指定目标目录，例如 G:\AssistantData。' }
    $sources = @(Get-CheckedSources -Specs $Specs)
    if ($sources.Count -eq 0) { throw '没有找到可迁移的源目录。' }
    $pending = New-Object 'System.Collections.Generic.List[object]'
    $required = [long]0
    foreach ($spec in $sources) {
        $junctionTarget = Get-JunctionTarget -Path $spec.Path
        if ($junctionTarget) {
            if ($junctionTarget.Equals($spec.Target,[StringComparison]::OrdinalIgnoreCase)) { Write-Log ("已经迁移，跳过 {0}" -f $spec.Id) 'WARN'; continue }
            throw "源路径已是指向其他位置的联接，拒绝覆盖：$($spec.Path) -> $junctionTarget"
        }
        if (Test-IsReparsePoint -Path $spec.Path) { throw "源路径是符号链接或其他重解析点，暂不支持：$($spec.Path)" }
        $processNames = Get-RunningAppNames
        if ($processNames.Count -gt 0) { throw ('请先退出相关应用：' + ($processNames -join ', ')) }
        if (Test-Path -LiteralPath $spec.Target) { throw "目标目录已存在，拒绝覆盖：$($spec.Target)" }
        $manifest = Get-TreeManifest -Root $spec.Path
        $required += [long]$manifest.Bytes
        $pending.Add([PSCustomObject]@{ Spec=$spec; Manifest=$manifest; Stash=($spec.Path + '.__assistant-mover-' + (Get-Date -Format 'yyyyMMddHHmmssfff')) })
    }
    if ($pending.Count -eq 0) { Write-Log '所选源目录均已迁移，无需操作。'; return }
    $drive = Test-TargetDrive -Root $TargetRoot -RequiredBytes ([long]($required * 1.05))
    foreach ($entry in $pending) {
        if ([IO.Path]::GetPathRoot($entry.Spec.Path).Equals($drive,[StringComparison]::OrdinalIgnoreCase)) { throw "目标盘与源目录在同一分区，无法释放系统盘空间：$($entry.Spec.Path)" }
    }
    $stateDir = Join-Path $TargetRoot '.assistant-mover'
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:LogPath = Join-Path $stateDir ('migration-' + $timestamp + '.log')
    $statePath = Join-Path $stateDir $script:StateName
    if (Test-Path -LiteralPath $statePath) { throw "发现已有迁移状态文件：$statePath。请先执行 Restore 或备份该状态。" }
    $state = [PSCustomObject]@{ Version=$script:Version; Id=$timestamp; Status='Preparing'; TargetRoot=[IO.Path]::GetFullPath($TargetRoot); Entries=@() }
    Write-Log ('开始迁移 {0} 个目录到 {1}' -f $pending.Count,$TargetRoot)
    try {
        foreach ($entry in $pending) {
            $spec = $entry.Spec
            Write-Log ('复制 {0}：{1}' -f $spec.Id,$spec.Path)
            Invoke-Robocopy -Source $spec.Path -Destination $spec.Target
            $targetManifest = Get-TreeManifest -Root $spec.Target
            $differences = @(Compare-Manifests -SourceManifest $entry.Manifest -TargetManifest $targetManifest)
            if ($differences.Count -gt 0) { throw ('校验失败 {0}：{1}' -f $spec.Id,($differences -join '; ')) }
            $sourceAfterCopy = Get-TreeManifest -Root $spec.Path
            $sourceDifferences = @(Compare-Manifests -SourceManifest $entry.Manifest -TargetManifest $sourceAfterCopy)
            if ($sourceDifferences.Count -gt 0) { throw ('复制期间源目录发生变化 {0}：{1}' -f $spec.Id,($sourceDifferences -join '; ')) }
            Write-Log ('校验通过 {0}：{1} 个文件，SHA-256 逐项一致' -f $spec.Id,$entry.Manifest.FileCount)
            $state.Entries += [PSCustomObject]@{ Id=$spec.Id; App=$spec.App; Kind=$spec.Kind; Source=$spec.Path; Target=$spec.Target; Stash=$entry.Stash; Files=$entry.Manifest.FileCount; Bytes=$entry.Manifest.Bytes; Manifest=$entry.Manifest; Status='Prepared' }
            Write-State -Path $statePath -State $state
        }
    } catch {
        $prepareError = $_.Exception.Message
        Write-Log ('复制或校验失败，清理本次未提交的副本：' + $prepareError) 'ERROR'
        foreach ($entry in $pending) {
            if (Test-Path -LiteralPath $entry.Spec.Target) {
                try { Remove-Item -LiteralPath $entry.Spec.Target -Recurse -Force -ErrorAction Stop }
                catch { Write-Log ('无法清理未提交目标，请保留并检查：{0} | {1}' -f $entry.Spec.Target,$_.Exception.Message) 'ERROR' }
            }
        }
        if (Test-Path -LiteralPath $statePath) { Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue }
        throw $prepareError
    }
    $touched = New-Object 'System.Collections.Generic.List[object]'
    try {
        $state.Status = 'Committing'
        Write-State -Path $statePath -State $state
        foreach ($entry in $pending) {
            $spec = $entry.Spec
            Write-Log ('创建 junction：{0}' -f $spec.Path)
            [IO.Directory]::Move($spec.Path,$entry.Stash)
            $touched.Add($entry)
            New-Junction -Link $spec.Path -Target $spec.Target
            $targetManifest = Get-TreeManifest -Root $spec.Path
            $differences = @(Compare-Manifests -SourceManifest $entry.Manifest -TargetManifest $targetManifest)
            if ($differences.Count -gt 0) { throw ('联接后校验失败 {0}：{1}' -f $spec.Id,($differences -join '; ')) }
            Write-Log ('联接校验通过 {0}' -f $spec.Id)
        }
        $state.Status = 'Committed'
        foreach ($entry in $state.Entries) { $entry.Status = 'Committed' }
        Write-State -Path $statePath -State $state
    } catch {
        Write-Log ('迁移失败，开始自动回滚：' + $_.Exception.Message) 'ERROR'
        $rollbackErrors = New-Object 'System.Collections.Generic.List[string]'
        for ($i=$touched.Count-1; $i -ge 0; $i--) {
            $entry = $touched[$i]
            try {
                if (Get-JunctionTarget -Path $entry.Spec.Path) { Remove-JunctionOnly -Path $entry.Spec.Path -ExpectedTarget $entry.Spec.Target }
                if (Test-Path -LiteralPath $entry.Stash) { [IO.Directory]::Move($entry.Stash,$entry.Spec.Path) }
                if (-not (Test-Path -LiteralPath $entry.Spec.Path)) { throw '原路径未能恢复' }
                Write-Log ('回滚完成：{0}' -f $entry.Spec.Path)
            } catch { $rollbackErrors.Add(($_.Exception.Message)); Write-Log ('回滚失败：' + $_.Exception.Message) 'ERROR' }
        }
        $state.Status = if ($rollbackErrors.Count -eq 0) { 'RolledBack' } else { 'RollbackIncomplete' }
        Write-State -Path $statePath -State $state
        if ($rollbackErrors.Count -gt 0) { throw ('自动回滚未完全完成，请保留目标盘数据和日志：' + ($rollbackErrors -join '; ')) }
        throw
    }
    foreach ($entry in $touched) {
        try { Remove-Item -LiteralPath $entry.Stash -Recurse -Force -ErrorAction Stop; Write-Log ('清理旧副本完成：{0}' -f $entry.Stash) }
        catch { Write-Log ('保留旧副本以便手动恢复：{0}' -f $entry.Stash) 'WARN' }
    }
    Write-Log ('迁移完成。备份/活动数据位于目标盘，恢复清单：{0}' -f $statePath)
}

function Invoke-Restore {
    if (-not $TargetRoot) { throw '请指定当初迁移时使用的目标目录。' }
    $statePath = Join-Path (Join-Path $TargetRoot '.assistant-mover') $script:StateName
    if (-not (Test-Path -LiteralPath $statePath)) { throw "找不到迁移状态：$statePath" }
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($state.Status -ne 'Committed') { throw "迁移状态不是 Committed（当前：$($state.Status)），拒绝自动恢复。" }
    $running = Get-RunningAppNames
    if ($running.Count -gt 0) { throw ('请先退出相关应用：' + ($running -join ', ')) }
    $script:LogPath = Join-Path (Split-Path -Parent $statePath) ('restore-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
    $restored = New-Object 'System.Collections.Generic.List[object]'
    try {
        foreach ($entry in @($state.Entries)) {
            $actual = Get-JunctionTarget -Path $entry.Source
            if (-not $actual -or -not $actual.Equals([IO.Path]::GetFullPath($entry.Target).TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)) { throw "原路径联接与状态不符，拒绝恢复：$($entry.Source)" }
            if (-not (Test-Path -LiteralPath $entry.Target -PathType Container)) { throw "目标备份不存在：$($entry.Target)" }
            $expected = [PSCustomObject]@{ Directories=@($entry.Manifest.Directories); Files=@($entry.Manifest.Files); FileCount=[int]$entry.Manifest.FileCount; DirectoryCount=[int]$entry.Manifest.DirectoryCount; Bytes=[long]$entry.Manifest.Bytes }
            $current = Get-TreeManifest -Root $entry.Target
            $baselineDiff = @(Compare-Manifests -SourceManifest $expected -TargetManifest $current)
            if ($baselineDiff.Count -gt 0) { throw ('目标盘数据与迁移清单不一致 {0}：{1}' -f $entry.Id,($baselineDiff -join '; ')) }
            $stage = $entry.Source + '.__assistant-restore-' + (Get-Date -Format 'yyyyMMddHHmmssfff')
            Write-Log ('恢复到原路径：{0}' -f $entry.Source)
            Invoke-Robocopy -Source $entry.Target -Destination $stage
            $live = Get-TreeManifest -Root $entry.Target
            $copy = Get-TreeManifest -Root $stage
            $diff = @(Compare-Manifests -SourceManifest $live -TargetManifest $copy)
            if ($diff.Count -gt 0) { throw ('恢复副本校验失败 {0}：{1}' -f $entry.Id,($diff -join '; ')) }
            $entry | Add-Member -NotePropertyName RestoreStage -NotePropertyValue $stage -Force
            $restored.Add($entry)
        }
        foreach ($entry in $restored) {
            Remove-JunctionOnly -Path $entry.Source -ExpectedTarget $entry.Target
            [IO.Directory]::Move($entry.RestoreStage,$entry.Source)
            Write-Log ('恢复完成：{0}' -f $entry.Source)
        }
        $state.Status = 'Restored'
        Write-State -Path $statePath -State $state
        Write-Log '所有项目均已恢复，目标盘备份保留。'
    } catch {
        Write-Log ('恢复失败，尝试恢复 junction：' + $_.Exception.Message) 'ERROR'
        foreach ($entry in $restored) {
            try {
                if (-not (Test-Path -LiteralPath $entry.Source) -and (Test-Path -LiteralPath $entry.RestoreStage)) { [IO.Directory]::Move($entry.RestoreStage,$entry.Source) }
                elseif (-not (Get-JunctionTarget -Path $entry.Source)) { New-Junction -Link $entry.Source -Target $entry.Target }
            } catch { Write-Log ('人工检查路径：{0} | {1}' -f $entry.Source,$_.Exception.Message) 'ERROR' }
        }
        throw
    }
}

function Invoke-SelfTest {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('assistant-mover-test-' + [guid]::NewGuid().ToString('N'))
    $source = Join-Path $root 'source'
    $target = Join-Path $root 'target'
    New-Item -ItemType Directory -Path (Join-Path $source 'nested') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $source 'a.txt'),'assistant-mover-test')
    [IO.File]::WriteAllText((Join-Path $source 'nested\b.txt'),'sha256')
    $left = Get-TreeManifest -Root $source
    Invoke-Robocopy -Source $source -Destination $target
    $right = Get-TreeManifest -Root $target
    $diff = @(Compare-Manifests -SourceManifest $left -TargetManifest $right)
    if ($diff.Count -gt 0) { throw ('SelfTest copy/hash failed: ' + ($diff -join ', ')) }
    $link = Join-Path $root 'junction-test'
    New-Junction -Link $link -Target $target
    if (-not (Test-Path -LiteralPath (Join-Path $link 'nested\b.txt'))) { throw 'SelfTest junction read failed.' }
    $blocked = $false
    try { Remove-JunctionOnly -Path $link -ExpectedTarget $source } catch { $blocked = $true }
    if (-not $blocked -or -not (Test-Path -LiteralPath (Join-Path $target 'a.txt'))) { throw 'SelfTest junction safety guard failed.' }
    Remove-JunctionOnly -Path $link -ExpectedTarget $target
    Write-Log ('SelfTest passed: {0} files, {1} bytes, per-file SHA-256 match.' -f $left.FileCount,$left.Bytes)
    Remove-Item -LiteralPath $root -Recurse -Force
}

try {
    if ($Action -eq 'SelfTest') { Invoke-SelfTest; exit 0 }
    if (-not $TargetRoot) { $TargetRoot = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'AssistantData' }
    $specs = @(Get-DefaultSpecs)
    if ($Action -eq 'Restore') { Invoke-Restore; exit 0 }
    if ($Action -eq 'Plan' -or $DryRun) { Invoke-Plan -Specs $specs; exit 0 }
    Invoke-Migration -Specs $specs
    exit 0
} catch {
    Write-Log $_.Exception.Message 'ERROR'
    exit 1
}
