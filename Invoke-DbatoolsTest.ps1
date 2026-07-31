# Runs the tests of single dbatools commands and reports the failures with enough detail to work on them.
#
# This is the script to use while working on a bug or a feature. Use run_tests.ps1 to run the whole test suite.
#
# Examples:
#     .\Invoke-DbatoolsTest.ps1 Get-DbaDatabase
#     .\Invoke-DbatoolsTest.ps1 Get-DbaDatabase, New-DbaDatabase -Tag IntegrationTests
#     .\Invoke-DbatoolsTest.ps1 'Get-DbaDb*' -SkipEnvironmentTest

[CmdletBinding()]
param (
    # Name of the command to test. Wildcards are supported. Can be a list of commands.
    [Parameter(Mandatory, Position = 0)]
    [string[]]$Command,
    [string]$ConfigFilename = 'TestConfig_remote_instances.ps1',
    # Runs only the unit tests or only the integration tests.
    [ValidateSet('UnitTests', 'IntegrationTests')]
    [string]$Tag,
    # Skips the check for leftovers in the lab after every test file.
    [switch]$SkipEnvironmentTest,
    # Returns the result objects instead of only writing the report.
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'

$githubBase   = 'C:\GitHub'
$dbatoolsBase = "$githubBase\dbatools"
$testingBase  = "$githubBase\testing-dbatools"
$logPath      = "$testingBase\logs"

. "$testingBase\Initialize-LabSession.ps1" -ConfigFilename $ConfigFilename

# dbatools moved to Pester 6, the CI pins 6.0.0 in tests\appveyor.prep.ps1.
Import-Module -Name Pester -MinimumVersion 6.0

$tests = foreach ($commandName in $Command) {
    $test = Get-ChildItem -Path "$dbatoolsBase\tests\$commandName.Tests.ps1" -ErrorAction SilentlyContinue
    if (-not $test) {
        Write-Warning -Message "No test file found for [$commandName]"
        continue
    }
    $test
}
$tests = $tests | Sort-Object -Property Name -Unique

if (-not $tests) {
    throw "No test files found for: $($Command -join ', ')"
}

$resultsFileName = "$logPath\command_$([datetime]::Now.ToString('yyyyMMdd_HHmmss')).txt"
$start = Get-Date

$results = foreach ($test in $tests) {
    # $test = $tests[0]

    Write-Host "`n$((Get-Date).ToString('HH:mm:ss')) === $($test.Name)" -ForegroundColor Cyan

    $pesterConfig = New-PesterConfiguration
    $pesterConfig.Run.Path = $test.FullName
    $pesterConfig.Run.PassThru = $true
    $pesterConfig.Output.Verbosity = 'None'
    if ($Tag) {
        $pesterConfig.Filter.Tag = $Tag
    }

    $resultTest = Invoke-Pester -Configuration $pesterConfig

    $failedTests = foreach ($failedTest in $resultTest.Failed) {
        [PSCustomObject]@{
            Name     = $failedTest.ExpandedPath
            Line     = $failedTest.ErrorRecord.TargetObject.Line
            LineText = $failedTest.ErrorRecord.TargetObject.LineText.Trim()
            Message  = ($failedTest.ErrorRecord.Exception.Message -split "`n" | ForEach-Object { $_.Trim() }) -join ' '
        }
    }

    # Leftovers in the lab break the tests that run afterwards,
    # so we want to know which test file caused them.
    $environmentFailed = $null
    if (-not $SkipEnvironmentTest) {
        $resultEnvironment = Invoke-Pester -Path "$testingBase\TestEnvironment.Tests.ps1" -Output None -PassThru
        $environmentFailed = $resultEnvironment.Failed.ExpandedPath
    }

    # A test file must not leave dbatools imported, because the next test file
    # has to start with the module in a defined state.
    # We import from the psm1 file, so our own import has version 0.0 and does not count.
    $moduleLeftLoaded = [bool](Get-Module -Name dbatools | Where-Object { $_.Version.Major -gt 0 })

    [PSCustomObject]@{
        TestFileName      = $test.Name
        Result            = $resultTest.Result
        DurationSeconds   = [int]$resultTest.Duration.TotalSeconds
        TotalCount        = $resultTest.TotalCount
        PassedCount       = $resultTest.PassedCount
        FailedCount       = $resultTest.FailedCount
        SkippedCount      = $resultTest.SkippedCount
        TestsFailed       = $failedTests
        EnvironmentFailed = $environmentFailed
        ModuleLeftLoaded  = $moduleLeftLoaded
    }
}

$results | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 5 | Add-Content -Path $resultsFileName }


# Report

Write-Host "`n$('=' * 60)"
Write-Host "Ran $(@($results).Count) test files in $([int]((Get-Date) - $start).TotalSeconds) seconds"
$results | Format-Table -Property TestFileName, Result, TotalCount, PassedCount, FailedCount, SkippedCount, DurationSeconds -AutoSize

foreach ($result in $results | Where-Object { $_.TestsFailed -or $_.EnvironmentFailed -or $_.ModuleLeftLoaded }) {
    Write-Host "$($result.TestFileName)" -ForegroundColor Yellow
    foreach ($failedTest in $result.TestsFailed) {
        Write-Host "  FAILED  $($failedTest.Name)"
        Write-Host "          line $($failedTest.Line): $($failedTest.LineText)"
        Write-Host "          $($failedTest.Message)"
    }
    foreach ($failedEnvironment in $result.EnvironmentFailed) {
        Write-Host "  LEFTOVER IN LAB  $failedEnvironment"
    }
    if ($result.ModuleLeftLoaded) {
        Write-Host "  MODULE LEFT LOADED  the test file did not remove the dbatools module"
    }
}

Write-Host "`nResults written to $resultsFileName"

if ($PassThru) {
    $results
}
