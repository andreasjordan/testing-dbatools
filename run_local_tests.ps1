param(
    [int]$NumberOfTestsToTest = 1000,
    [int]$NumberOfTestsToSkip = 0,
    [string]$CommandToStartWith,
    [switch]$ContinueOnFailure,
    [switch]$SkipEnvironmentTest
)

$ErrorActionPreference = 'Stop'

$githubBase   = 'C:\GitHub'

$dbatoolsBase = "$githubBase\dbatools"
$testingBase = "$githubBase\testing-dbatools"

$configFile = "$testingBase\TestConfig_local_instanes.ps1"
$logPath    = "$testingBase\logs"

$resultsFileName = "$logPath\results_$([datetime]::Now.ToString('yyyMMdd_HHmmss')).txt"


$start = Get-Date

Import-Module -Name "$dbatoolsBase\dbatools.psm1" -Force
$null = Set-DbatoolsInsecureConnection
#Set-DbatoolsConfig -FullName 'sql.connection.nonpooled' -Value $true

# For the pester4 tests the configFile needs to be copied
Copy-Item -Path $configFile -Destination "$dbatoolsBase\tests\constants.local.ps1"

$TestConfig = Get-TestConfig -LocalConfigPath $configFile

$tests = Get-ChildItem -Path "$dbatoolsBase\tests\*-Dba*.Tests.ps1" | Sort-Object -Property Name

$skipTests = @(
    'Invoke-DbaDbMirroring.Tests.ps1'  # "the partner server name must be distinct"
    'Watch-DbaDbLogin.Tests.ps1'       # Command does not work
    'Get-DbaWindowsLog.Tests.ps1'      # Sometimes failes (gets no data), sometimes takes forever
    'Get-DbaPageFileSetting.Tests.ps1' # Classes Win32_PageFile and Win32_PageFileSetting do not return any information
    'New-DbaSsisCatalog.Tests.ps1'     # needs an SSIS server
    'Get-DbaClientProtocol.Tests.ps1'  # No ComputerManagement Namespace on CLIENT.dom.local
)
$tests = $tests | Where-Object Name -notin $skipTests

if ($PSVersionTable.PSVersion.Major -gt 5) {
    $skipTests = @(
        'Add-DbaComputerCertificate.Tests.ps1'    # does not work on pwsh because of X509Certificate2
        'Backup-DbaComputerCertificate.Tests.ps1' # does not work on pwsh because of X509Certificate2
        'Enable-DbaFilestream.Tests.ps1'          # does not work on pwsh because of WMI-Object not haveing method EnableFilestream
        'Invoke-DbaQuery.Tests.ps1'               # does not work on pwsh because "DataReader.GetFieldType(0) returned null." with geometry
    )
}
$tests = $tests | Where-Object Name -notin $skipTests


# Filter tests based on script parameters

if ($CommandToStartWith) {
    $commandIndex = $tests.Name.IndexOf("$CommandToStartWith.Tests.ps1")
    if ($commandIndex -ge 0) {
        $tests = $tests[$commandIndex..($tests.Count - 1)]
    } else {
        Write-Warning -Message "No test for [$CommandToStartWith] found"
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

    if ((Get-Content -Path $test.FullName)[0] -match 'Requires.*Pester.*5') { 
        $resultTest = Invoke-Pester -Path $test.FullName -Output Detailed -PassThru
        if ($resultTest.FailedCount -gt 0) {
            $failure = $true
        }
    } else {
        Remove-Module -Name Pester
        Import-Module -Name Pester -MaximumVersion 4.99
        $resultTest = Invoke-Pester -Script $test.FullName -Show All -PassThru
        if ($resultTest.FailedCount -gt 0) {
            $failure = $true
        }
        Remove-Module -Name Pester
        Import-Module -Name Pester -MinimumVersion 5.0
    }

    $usedMemory = [int]([System.GC]::GetTotalMemory($false)/1MB) - $startMemory

    if (-not $SkipEnvironmentTest) {
        $resultEnvironment = Invoke-Pester -Path "$testingBase\TestEnvironment.Tests.ps1" -Output None -PassThru
        if ($resultEnvironment.Result -ne 'Passed') {
            Write-Warning -Message "Environment test failed: $($resultEnvironment.Failed.ExpandedPath)"
            $failure = $true
        }
    }

    Clear-DbaConnectionPool

    [int]$sleepingProcs1 = (Get-DbaProcess -SqlInstance $TestConfig.instance1 | Where-Object { $_.Program -match 'dbatools' -and $_.Status -eq 'sleeping' }).Count
    [int]$sleepingProcs2 = (Get-DbaProcess -SqlInstance $TestConfig.instance2 | Where-Object { $_.Program -match 'dbatools' -and $_.Status -eq 'sleeping' }).Count
    [int]$sleepingProcs3 = (Get-DbaProcess -SqlInstance $TestConfig.instance3 | Where-Object { $_.Program -match 'dbatools' -and $_.Status -eq 'sleeping' }).Count
    
    Remove-DbaDbBackupRestoreHistory -SqlInstance $TestConfig.instance1, $TestConfig.instance2, $TestConfig.instance3 -KeepDays -1 -Confirm:$false

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

    $null = Get-DbaConnectedInstance | Disconnect-DbaInstance
    Clear-DbaConnectionPool
    [System.GC]::Collect()

    $progressCompleted++

    if ($failure -and -not $ContinueOnFailure) {
        break
    }
}
Write-Progress @progressParameter -Completed

Write-Host "Finished $progressCompleted tests in $([int]((Get-Date) - $start).TotalMinutes) minutes"
