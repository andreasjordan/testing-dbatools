$ErrorActionPreference = 'Stop'

$githubBase   = 'C:\GitHub'

$dbatoolsBase = "$githubBase\dbatools"
$testingBase = "$githubBase\testing-dbatools"
$logPath    = "$testingBase\logs"

# Get-ChildItem -Path $logPath -Filter results*.txt

$resultFile = Get-ChildItem -Path $logPath -Filter results*.txt | Sort-Object LastWriteTime | Select-Object -Last 1
$lines = $resultFile | Get-Content | ConvertFrom-Json

# The run header and footer are separate lines. Result files written before those existed
# have no Type at all, so everything without a Type is a test file.
$runStart = $lines | Where-Object { $_.Type -eq "RunStart" }
$runEnd = $lines | Where-Object { $_.Type -eq "RunEnd" }
$results = @($lines | Where-Object { -not $_.Type -or $_.Type -eq "TestFile" })

Write-Host "Result file: $($resultFile.FullName)"
if ($runStart) {
    Write-Host "Started $($runStart.StartTime) on $($runStart.ComputerName) with $($runStart.ConfigFilename), scenario [$($runStart.Scenario)]"
    Write-Host "dbatools branch $($runStart.DbatoolsBranch) at $($runStart.DbatoolsCommit)$(if ($runStart.DbatoolsIsDirty) { " with uncommitted changes" })"
}
if ($runEnd) {
    Write-Host "Ended $($runEnd.EndTime) after $($runEnd.DurationMinutes) minutes, $($runEnd.CompletedCount) of $($runEnd.TestFileCount) test files$(if ($runEnd.StopReason) { ", $($runEnd.StopReason)" })"
} else {
    Write-Host "No end of run recorded - the run is still going, or it was aborted by hand"
}

$results | Group-Object Result -NoElement

$passed = @($results | Where-Object Result -eq "Passed")
$failed = @($results | Where-Object Result -eq "Failed")

$failed.TestFileName

# A test file can also be a problem without failing: it can leave objects in the lab,
# leave the module loaded, or write warnings when the run asked for warnings to count.
$problems = @($results | Where-Object { $_.Result -ne "Passed" -or $_.TestsFailed -or $_.EnvironmentFailed -or $_.ModuleLeftLoaded -or $_.Warnings })

foreach ($result in $problems) {
    Write-Host "`n$($result.TestFileName)" -ForegroundColor Yellow
    foreach ($failedTest in $result.TestsFailed) {
        # Source says where Pester put the detail: on the test, on the block (a failing BeforeAll)
        # or on the container (the file did not get through discovery).
        Write-Host "  FAILED ($($failedTest.Source))  $($failedTest.Name)"
        if ($failedTest.Line) {
            Write-Host "          line $($failedTest.Line): $($failedTest.LineText)"
        }
        Write-Host "          $($failedTest.Message)"
    }
    foreach ($failedEnvironment in $result.EnvironmentFailed | Where-Object { $_ }) {
        # Result files written before the message was kept only have the name of the check.
        if ($failedEnvironment.Name) {
            Write-Host "  LEFTOVER IN LAB  $($failedEnvironment.Name)"
            Write-Host "                   $($failedEnvironment.Message)"
        } else {
            Write-Host "  LEFTOVER IN LAB  $failedEnvironment"
        }
    }
    if ($result.ModuleLeftLoaded) {
        Write-Host "  MODULE LEFT LOADED  the test file did not remove the dbatools module"
    }
    foreach ($warning in $result.Warnings) {
        Write-Host "  WARNING  $warning"
    }
}

if ($failed) {
    # Details of the test that failed last - this is where a stopped run has to be continued.
    Write-Host "`nContinue with: .\run_tests.ps1 -CommandToStartWith $($failed[-1].TestFileName -replace "\.Tests\.ps1")"
}

break


$selected = $passed | Out-GridView -PassThru
$selected = $failed | Out-GridView -PassThru
