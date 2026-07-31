param(
    [int]$NumberOfTestsToTest = 1000,
    [int]$NumberOfTestsToSkip = 0,
    [string]$CommandToStartWith,
    [switch]$ContinueOnFailure,
    [switch]$SkipEnvironmentTest,
    [switch]$TestForWarnings,
    [string]$StatusUrl = $Env:MyStatusUrl,
    [string]$ConfigFilename = 'TestConfig_remote_instances.ps1',
    # These have to be keys of $TestsRunGroups in dbatools\tests\pester.groups.ps1
    [ValidateSet('SINGLE', 'MULTI', 'COPY', 'HADR', 'RESTART', '2008R2SP2Express')]
    [string]$Scenario,
    [hashtable]$Config,
    [switch]$CheckSleepingConnections
)

$ErrorActionPreference = 'Stop'

$githubBase   = 'C:\GitHub'

$dbatoolsBase = "$githubBase\dbatools"
$testingBase = "$githubBase\testing-dbatools"

$configFile = "$testingBase\$ConfigFilename"
$logPath    = "$testingBase\logs"

$resultsFileName = "$logPath\results_$($Scenario)_$([datetime]::Now.ToString('yyyyMMdd_HHmmss')).txt"



function Send-Status {
    Param([string]$Message)
    if ($StatusUrl) {
        $requestParams = @{
            Uri             = $StatusUrl
            Method          = 'Post'
            ContentType     = 'application/json'
            Body            = @{
                IP      = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne '127.0.0.1' } | Select-Object -First 1).IPAddress
                Host    = [System.Net.Dns]::GetHostName()
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

Import-Module "$dbatoolsBase\dbatools.psm1" -Force

$TestConfig = Get-TestConfig -LocalConfigPath $configFile
if ($Config) {
    foreach ($cfg in $Config.GetEnumerator()) {
        Add-Member -InputObject $TestConfig -MemberType NoteProperty -Name $cfg.Name -Value $cfg.Value -Force
    }
}

$tests = Get-ChildItem -Path "$dbatoolsBase\tests\*.Tests.ps1" | Sort-Object -Property Name

# Filter tests based on script parameters

if ($Scenario) {
    . "$dbatoolsBase\tests\appveyor.common.ps1"
    . "$dbatoolsBase\tests\pester.groups.ps1"
    $tests = Get-TestsForScenario -Scenario $Scenario -AllTest $tests
}

if ($CommandToStartWith) {
    # We need @( ) here, because with only one test left, $tests.Name would be a string
    # and IndexOf would search for a character instead of a filename.
    $commandIndex = @($tests.Name).IndexOf("$CommandToStartWith.Tests.ps1")
    if ($commandIndex -ge 0) {
        $tests = $tests[$commandIndex..($tests.Count - 1)]
    } else {
        Write-Warning -Message "No test for [$CommandToStartWith] found"
        break
    }
}

$tests = $tests | Select-Object -First $NumberOfTestsToTest -Skip $NumberOfTestsToSkip

#$ProgressPreference = 'SilentlyContinue'
#Get-Date
#Install-DbaSqlPackage
#Get-Date
#$ProgressPreference = 'Continue'

# dbatools moved to Pester 6, the CI pins 6.0.0 in tests\appveyor.prep.ps1.
Import-Module -Name Pester -MinimumVersion 6.0

$progressParameter = @{ Id = Get-Random ; Activity = 'Running tests' }
$progressTotal = $tests.Count
$progressCompleted = 0
$progressStart = Get-Date
foreach ($test in $tests) {
    # $test = $tests[0]

    $progressParameter.Status = "$progressCompleted of $progressTotal tests completed ($usedMemory MB used by the last test)"
    $progressParameter.CurrentOperation = "processing $($test.Name)"
    $progressParameter.PercentComplete = $progressCompleted * 100 / $progressTotal
    if ($progressParameter.PercentComplete -gt 0) {
        $progressParameter.SecondsRemaining = ((Get-Date) - $progressStart).TotalSeconds / $progressParameter.PercentComplete * (100 - $progressParameter.PercentComplete)
    }
    Write-Progress @progressParameter

    # We scan the test file for the configuration keys it uses, so that we know
    # which instances have to be checked for leftovers after the test has run.
    $content = Get-Content -Path $test.FullName
    $instanceNames = foreach ($line in $content) {
        $code = $line -replace '#.*$',''
        [regex]::Matches($code, '\$TestConfig\.Instance(\w+)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) | ForEach-Object { $_.Groups[1].Value }
    }
    $instanceNames = $instanceNames | Sort-Object -Unique
    $usedInstances = $instanceNames | ForEach-Object { $TestConfig."Instance$PSItem" } | Where-Object { $_ -is [string] -and $_ } | Sort-Object -Unique
    Write-Warning -Message "Using instances: $($usedInstances -join ', ')"
    Write-Warning -Message "Running $($test.FullName)"

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

    # Connections that the test did not close are a common source of problems in later tests,
    # so we can count them - but only on request, as this costs a query per instance and test.
    $sleepingProcs = $null
    if ($CheckSleepingConnections -and $usedInstances) {
        $sleepingProcs = @(Get-DbaProcess -SqlInstance $usedInstances | Where-Object { $_.Program -match 'dbatools' -and $_.Status -eq 'sleeping' }).Count
    }

    $sleepingProcsInfo = if ($null -ne $sleepingProcs) { "$sleepingProcs sleeping / " } else { '' }
    Write-Host "`n$((Get-Date).ToString('HH:mm:ss')) ========= $sleepingProcsInfo$usedMemory MB used / $([int]([System.GC]::GetTotalMemory($false)/1MB)) MB total ==========`n"

    $resultInfo = [ordered]@{
        TestFileName      = $test.Name
        Result            = $( if ($resultTest.Result) { $resultTest.Result } elseif ($resultTest.FailedCount -eq 0) { 'Passed' } else { 'Failed' })
        DurationSeconds   = $( if ($resultTest.Duration) { $resultTest.Duration.TotalSeconds } else { $resultTest.Time.TotalSeconds })
        TotalCount        = $resultTest.TotalCount
        PassedCount       = $resultTest.PassedCount
        FailedCount       = $resultTest.FailedCount
        SkippedCount      = $resultTest.SkippedCount
        UsedMemoryMB      = $usedMemory
        UsedInstances     = $usedInstances
        SleepingProcs     = $sleepingProcs
        TestsFailed       = $resultTest.Failed
        EnvironmentFailed = $(if (-not $SkipEnvironmentTest -and $resultEnvironment.Result -ne 'Passed') { $resultEnvironment.Failed })
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
