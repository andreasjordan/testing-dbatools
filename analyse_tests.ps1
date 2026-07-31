[CmdletBinding()]
param (
    [string]$TestPath = "C:\GitHub\dbatools\tests",
    # By default the result is put into the clipboard, use this to get it as objects.
    [switch]$PassThru
)

$testFiles = Get-ChildItem -Path $TestPath -Filter *-Dba*.Tests.ps1 | Sort-Object -Property Name

$result = foreach ($file in $testFiles) {
    $content = Get-Content -Path $file.FullName
    # This matches both the current names ($TestConfig.InstanceSingle, $TestConfig.InstanceMulti1, ...)
    # and the legacy names ($TestConfig.instance1, ...), but not commented out code.
    $instanceNames = foreach ($line in $content) {
        $code = $line -replace '#.*$', ''
        [regex]::Matches($code, '\$TestConfig\.Instance(\w+)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) | ForEach-Object { $_.Groups[1].Value }
    }
    $instanceNames = $instanceNames | Sort-Object -Unique

    [PSCustomObject]@{
        Command   = $file.Name -replace '.Tests.ps1$', ''
        Instances = $instanceNames -join ' '
    }
}

$resultGroups = $result | Group-Object -Property Instances | Sort-Object -Property Name

$output = @(
    'Summary:'
    '========'
    ''
)
$output += foreach ($group in $resultGroups) {
    "$($group.Count) Tests using these instances: $($group.Name)"
}
$output += @(
    ''
    ''
    'Details:'
    '========'
    ''
)
$output += foreach ($group in $resultGroups) {
    ''
    "$($group.Count) Tests using these instances: $($group.Name)"
    foreach ($command in $group.Group.Command) {
        "* $command"
    }
}

if ($PassThru) {
    $result
} else {
    $output | Set-Clipboard
    Write-Host "Analysed $($testFiles.Count) test files, the summary is in the clipboard"
    $resultGroups | Format-Table -Property Count, Name -AutoSize
}
