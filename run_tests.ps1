param(
    [int]$NumberOfTestsToTest = 1000,
    [int]$NumberOfTestsToSkip = 0,
    [string]$CommandToStartWith,
    [switch]$ContinueOnFailure,
    [switch]$SkipEnvironmentTest,
    [switch]$TestForWarnings,
    [string]$StatusUrl = $Env:MyStatusUrl,
    [string]$ConfigFilename = $Env:MyConfigFilename
)

$ErrorActionPreference = 'Stop'

$githubBase   = 'C:\GitHub'

$dbatoolsBase = "$githubBase\dbatools"
$testingBase = "$githubBase\testing-dbatools"

$configFile = "$testingBase\$ConfigFilename"
$logPath    = "$testingBase\logs"

$resultsFileName = "$logPath\results_$([datetime]::Now.ToString('yyyMMdd_HHmmss')).txt"



function Send-Status {
    Param([string]$Message)
    if ($StatusUrl) {
        $requestParams = @{
            Uri             = $StatusUrl
            Method          = 'Post'
            ContentType     = 'application/json'
            Body            = @{
                IP      = '127.0.0.1'
                Host    = 'localhost'
                Message = $Message
            } | ConvertTo-Json -Compress
            UseBasicParsing = $true
        }
        try {
            $null = Invoke-WebRequest @requestParams
        } catch {
            Write-Warning -Message "Failed to send status: $_"
        }
    }
}




$start = Get-Date

Import-Module -Name "$dbatoolsBase\dbatools.psm1" -Force
$null = Set-DbatoolsInsecureConnection

$TestConfig = Get-TestConfig -LocalConfigPath $configFile

$tests = Get-ChildItem -Path "$dbatoolsBase\tests\*-Dba*.Tests.ps1" | Sort-Object -Property Name

# Filter tests based on script parameters

if ($CommandToStartWith) {
    $commandIndex = $tests.Name.IndexOf("$CommandToStartWith.Tests.ps1")
    if ($commandIndex -ge 0) {
        $tests = $tests[$commandIndex..($tests.Count - 1)]
    } else {
        Write-Warning -Message "No test for [$CommandToStartWith] found"
        break
    }
}

$tests = $tests | Select-Object -First $NumberOfTestsToTest -Skip $NumberOfTestsToSkip


Import-Module -Name Pester -MinimumVersion 5.0

$progressParameter = @{ Id = Get-Random ; Activity = 'Running tests' }
$progressTotal = $tests.Count
$progressCompleted = 0
$progressStart = Get-Date
foreach ($test in $tests) {
    # $test = $tests[0]

    $progressParameter.Status = "$progressCompleted of $progressTotal tests completed ($sleepingProcs1 / $sleepingProcs2 / $sleepingProcs3 / $usedMemory MB / $startMemory MB)"
    $progressParameter.CurrentOperation = "processing $($test.Name)"
    $progressParameter.PercentComplete = $progressCompleted * 100 / $progressTotal
    if ($progressParameter.PercentComplete -gt 0) {
        $progressParameter.SecondsRemaining = ((Get-Date) - $progressStart).TotalSeconds / $progressParameter.PercentComplete * (100 - $progressParameter.PercentComplete)
    }
    Write-Progress @progressParameter

    $failure = $false
    $startMemory = [int]([System.GC]::GetTotalMemory($false)/1MB)

    $warningsFile = "$logPath\$($test.Name).warnings.txt"
    if ($TestForWarnings) {
        $resultTest = Invoke-Pester -Path $test.FullName -Output Detailed -PassThru 3> $warningsFile
        $warnings = Get-Content -Path $warningsFile
        if ($warnings) {
            $warnings | ForEach-Object { Write-Warning -Message $_ }
            $failure = $true
        } else {
            Remove-Item -Path $warningsFile
        }
    } else {
        $resultTest = Invoke-Pester -Path $test.FullName -Output Detailed -PassThru
    }
    if ($resultTest.FailedCount -gt 0) {
        $failure = $true
    }

    $usedMemory = [int]([System.GC]::GetTotalMemory($false)/1MB) - $startMemory

    if (-not $SkipEnvironmentTest) {
        $resultEnvironment = Invoke-Pester -Path "$testingBase\TestEnvironment.Tests.ps1" -Output None -PassThru
        if ($resultEnvironment.Result -ne 'Passed') {
            Write-Warning -Message "Environment test failed: $($resultEnvironment.Failed.ExpandedPath)"
            $failure = $true
        }
    }

    if (Get-Module -Name dbatools | Where-Object { $_.Version.Major -gt 0 }) {
        Write-Warning -Message "dbatools was loaded"
        $failure = $true
    }

#    Clear-DbaConnectionPool

#    [int]$sleepingProcs1 = (Get-DbaProcess -SqlInstance $TestConfig.instance1 | Where-Object { $_.Program -match 'dbatools' -and $_.Status -eq 'sleeping' }).Count
#    [int]$sleepingProcs2 = (Get-DbaProcess -SqlInstance $TestConfig.instance2 | Where-Object { $_.Program -match 'dbatools' -and $_.Status -eq 'sleeping' }).Count
#    [int]$sleepingProcs3 = (Get-DbaProcess -SqlInstance $TestConfig.instance3 | Where-Object { $_.Program -match 'dbatools' -and $_.Status -eq 'sleeping' }).Count
    
#    Remove-DbaDbBackupRestoreHistory -SqlInstance $TestConfig.instance1, $TestConfig.instance2, $TestConfig.instance3 -KeepDays -1 -Confirm:$false

    Write-Host "`n$((Get-Date).ToString('HH:mm:ss')) ========= $sleepingProcs1 / $sleepingProcs2 / $sleepingProcs3 / $usedMemory MB / $([int]([System.GC]::GetTotalMemory($false)/1MB)) MB ==========`n"

    $resultInfo = [ordered]@{
        TestFileName      = $test.Name
        Result            = $( if ($resultTest.Result) { $resultTest.Result } elseif ($resultTest.FailedCount -eq 0) { 'Passed' } else { 'Failed' })
        DurationSeconds   = $( if ($resultTest.Duration) { $resultTest.Duration.TotalSeconds } else { $resultTest.Time.TotalSeconds })
        TotalCount        = $resultTest.TotalCount
        PassedCount       = $resultTest.PassedCount
        FailedCount       = $resultTest.FailedCount
        SkippedCount      = $resultTest.SkippedCount
        UsedMemoryMB      = $usedMemory
        SleepingProcs1    = $sleepingProcs1
        SleepingProcs2    = $sleepingProcs2
        SleepingProcs3    = $sleepingProcs3
        EnvironmentFailed = $(if ($resultEnvironment.Result -ne 'Passed') { $resultEnvironment.Failed })
    }
    $resultInfo | ConvertTo-Json -Compress | Add-Content -Path $resultsFileName

#    $null = Get-DbaConnectedInstance | Disconnect-DbaInstance
#    Clear-DbaConnectionPool
#    [System.GC]::Collect()

    $progressCompleted++

    if ($failure -and -not $ContinueOnFailure) {
        Send-Status -Message "TEST FAILED: $($test.Name)"
        break
    }
    Send-Status -Message "Test $progressCompleted of $progressTotal ok: $($test.Name)"
}
Write-Progress @progressParameter -Completed

Write-Host "Finished $progressCompleted tests in $([int]((Get-Date) - $start).TotalMinutes) minutes"
