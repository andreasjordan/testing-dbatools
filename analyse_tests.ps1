$testPath = "$env:OneDrive\github.com\dataplat\dbatools\tests"

$testFiles = Get-ChildItem -Path $testPath -Filter *-Dba*.Tests.ps1

$result = foreach ($file in $testFiles) {
    $content = Get-Content -Path $file.FullName
    $instanceNumbers = foreach ($line in $content) {
        if ($line -match '^[^#]*\$TestConfig\.instance(\d)') {
            $Matches[1]
        }
    }
    $instanceNumbers = $instanceNumbers | Sort-Object -Unique

    [PSCustomObject]@{
        Command   = $file.Name -replace '.Tests.ps1$', ''
        Instance1 = $instanceNumbers -contains 1
        Instance2 = $instanceNumbers -contains 2
        Instance3 = $instanceNumbers -contains 3
        Instances = $instanceNumbers -join ' '
    }
}

$resultGroups = $result | Group-Object -Property Instances | Sort-Object Name
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

$output | Set-Clipboard