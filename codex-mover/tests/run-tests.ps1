#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
$engine = Join-Path $root 'AssistantMover.ps1'
$gui = Join-Path $root 'AssistantMover-GUI.ps1'
$tokens = $null
$parseErrors = $null
foreach ($path in @($engine,$gui,$PSCommandPath)) {
    [Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -gt 0) { throw ('PowerShell parse failed: ' + $path + ' | ' + ($parseErrors.Message -join '; ')) }
    $bytes = [IO.File]::ReadAllBytes($path)
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 239 -or $bytes[1] -ne 187 -or $bytes[2] -ne 191) { throw ('UTF-8 BOM missing: ' + $path) }
}
Add-Type -AssemblyName PresentationFramework
$window = [Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $root 'AssistantMover-GUI.xaml')))
foreach ($name in @('StatusPanel','StatusBadge','DriveBox','FolderBox','TargetPreview','SourceList','CustomPathBox','RefreshSizes','AddWorkspace','RemoveWorkspace','RunHint','LogBox','DryRunBox','RestoreButton','RunButton','ExitButton')) {
    if (-not $window.FindName($name)) { throw "Missing XAML control: $name" }
}
Write-Output 'PowerShell 5.1 parse, UTF-8 BOM, XAML and named controls passed.'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $gui -SelfTest
if ($LASTEXITCODE -ne 0) { throw 'GUI initialization failed.' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $gui -SmokeTest
if ($LASTEXITCODE -ne 0) { throw 'GUI child-process dry-run smoke tests failed.' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine -Action SelfTest
if ($LASTEXITCODE -ne 0) { throw 'Copy/hash/junction safety self-test failed.' }
# Load function definitions without executing the command-line entry point.
$ast = [Management.Automation.Language.Parser]::ParseFile($engine,[ref]$tokens,[ref]$parseErrors)
foreach ($statement in $ast.EndBlock.Statements) {
    if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) { Invoke-Expression $statement.Extent.Text }
}
$script:Version = '1.1.0'
$script:StateName = 'assistant-mover-state.json'
$script:LogPath = $null
$TargetRoot = Join-Path $env:TEMP 'dev-mover-unused-target'
$Workspace = @()
$Include = @()
$ExplicitSelection = $true
$catalog = @(Get-DefaultSpecs)
if (@($catalog | Where-Object { $_.App -eq 'OpenAI Codex' }).Count -lt 5) { throw 'Codex catalog missing.' }
if (@(Get-CheckedSources -Specs $catalog).Count -ne 0) { throw 'An explicit empty selection selected application data.' }
$previousHome = $env:CODEX_HOME
try {
    $env:CODEX_HOME = Join-Path $env:TEMP 'dev-mover-test-custom-home'
    $custom = @(Get-DefaultSpecs | Where-Object { $_.Id -eq 'codex-custom-home' })
    if ($custom.Count -ne 1 -or $custom[0].Path -ne $env:CODEX_HOME) { throw 'CODEX_HOME catalog handling failed.' }
} finally { $env:CODEX_HOME = $previousHome }
# Only process and drive preflights are stubbed for disposable same-volume fixtures.
function Get-RunningAppNames { return @() }
function Test-TargetDrive { param([string]$Root,[long]$RequiredBytes); return 'Z:\' }
$fixtureRoot = Join-Path $env:TEMP ('dev-mover-transactions-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
function New-FixtureSpec {
    param([string]$Id,[string]$Batch)
    $source = Join-Path (Join-Path $fixtureRoot $Batch) ('source space 中文-' + $Id)
    [IO.Directory]::CreateDirectory((Join-Path $source 'nested')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $source 'nested\data.txt'),('original-' + $Id))
    return @{ Id=$Id; App='Test'; Path=$source; Kind='Workspace'; Target=(Join-Path $TargetRoot $Id) }
}
$realNewJunction = (Get-Item Function:New-Junction).ScriptBlock
$realRemoveJunction = (Get-Item Function:Remove-JunctionOnly).ScriptBlock
$createdSpecs = @()
try {
    $TargetRoot = Join-Path $fixtureRoot 'success-target'
    $specs = @((New-FixtureSpec -Id 'one' -Batch 'success'),(New-FixtureSpec -Id 'two' -Batch 'success'))
    $createdSpecs += $specs
    Invoke-Migration -Specs $specs
    foreach ($spec in $specs) {
        if (-not (Get-JunctionTarget -Path $spec.Path)) { throw 'Migration did not create a junction.' }
        [IO.File]::WriteAllText((Join-Path $spec.Path 'nested\data.txt'),('updated-' + $spec.Id))
        [IO.File]::WriteAllText((Join-Path $spec.Path 'new.txt'),'new application data')
    }
    $script:removeCount = 0
    function Remove-JunctionOnly {
        param([string]$Path,[string]$ExpectedTarget)
        $script:removeCount++
        if ($script:removeCount -eq 2) { throw 'Injected restore failure.' }
        & $realRemoveJunction -Path $Path -ExpectedTarget $ExpectedTarget
    }
    $failed = $false
    try { Invoke-Restore } catch { $failed = $true }
    if (-not $failed) { throw 'Injected restore failure did not fail.' }
    foreach ($spec in $specs) {
        if (-not (Get-JunctionTarget -Path $spec.Path)) { throw 'Restore rollback lost an original junction.' }
        if ([IO.File]::ReadAllText((Join-Path $spec.Target 'new.txt')) -ne 'new application data') { throw 'Restore rollback modified active target data.' }
    }
    Set-Item Function:Remove-JunctionOnly $realRemoveJunction
    Invoke-Restore
    foreach ($spec in $specs) {
        if (Test-IsReparsePoint -Path $spec.Path) { throw 'Restore did not return a regular directory.' }
        if ([IO.File]::ReadAllText((Join-Path $spec.Path 'nested\data.txt')) -ne ('updated-' + $spec.Id)) { throw 'Restore lost updated data.' }
        if (-not (Test-Path -LiteralPath (Join-Path $spec.Path 'new.txt'))) { throw 'Restore lost a newly created file.' }
        if (-not (Test-Path -LiteralPath $spec.Target)) { throw 'Restore removed target data.' }
    }
    Write-Output 'Migration and restore of updated data, plus restore failure rollback passed.'
    $TargetRoot = Join-Path $fixtureRoot 'rollback-target'
    $specs = @((New-FixtureSpec -Id 'one' -Batch 'rollback'),(New-FixtureSpec -Id 'two' -Batch 'rollback'))
    $createdSpecs += $specs
    $script:newJunctionCount = 0
    function New-Junction {
        param([string]$Link,[string]$Target)
        $script:newJunctionCount++
        if ($script:newJunctionCount -eq 2) { throw 'Injected migration failure.' }
        & $realNewJunction -Link $Link -Target $Target
    }
    $failed = $false
    try { Invoke-Migration -Specs $specs } catch { $failed = $true }
    if (-not $failed) { throw 'Injected migration failure did not fail.' }
    foreach ($spec in $specs) {
        if (Test-IsReparsePoint -Path $spec.Path) { throw 'Rollback left a junction behind.' }
        if ([IO.File]::ReadAllText((Join-Path $spec.Path 'nested\data.txt')) -ne ('original-' + $spec.Id)) { throw 'Migration rollback lost source data.' }
    }
    $statePath = Join-Path (Join-Path $TargetRoot '.assistant-mover') $script:StateName
    $state = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
    if ($state.Status -ne 'RolledBack') { throw 'Rollback state is incorrect.' }
    Write-Output 'Injected migration commit failure restored both original directories.'
} finally {
    Set-Item Function:New-Junction $realNewJunction
    Set-Item Function:Remove-JunctionOnly $realRemoveJunction
    $script:LogPath = $null
    foreach ($spec in $createdSpecs) {
        if (Get-JunctionTarget -Path $spec.Path) { Remove-JunctionOnly -Path $spec.Path -ExpectedTarget $spec.Target }
    }
    if ([IO.Path]::GetFullPath($fixtureRoot).StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\dev-mover-transactions-',[StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
}
Write-Output 'All Dev Mover tests passed. No real application data was migrated.'