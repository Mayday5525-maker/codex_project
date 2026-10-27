#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$engine = Join-Path $root 'AssistantMover.ps1'
$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($engine,[ref]$tokens,[ref]$parseErrors) | Out-Null
if ($parseErrors.Count -gt 0) { $parseErrors | Format-List Message,Extent; throw 'Engine PowerShell parse failed.' }
$xamlPath = Join-Path $root 'AssistantMover-GUI.xaml'
$gui = Join-Path $root 'AssistantMover-GUI.ps1'
Add-Type -AssemblyName PresentationFramework
$window = [Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText($xamlPath))
foreach ($name in @('StatusBadge','TargetBox','BrowseTarget','SourceList','AddWorkspace','RemoveWorkspace','RunHint','LogBox','DryRunBox','RestoreButton','RunButton')) {
    if (-not $window.FindName($name)) { throw "Missing XAML control: $name" }
}
Write-Output 'GUI XAML parsed; all named controls are present.'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $gui -SelfTest
if ($LASTEXITCODE -ne 0) { throw "GUI initialization self-test failed with exit code $LASTEXITCODE" }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine -Action SelfTest
if ($LASTEXITCODE -ne 0) { throw "Assistant Mover self-test failed with exit code $LASTEXITCODE" }
Write-Output 'All Assistant Mover tests passed.'
