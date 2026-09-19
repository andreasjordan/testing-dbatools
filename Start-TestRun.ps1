# Starts one full test run per instance set, side by side, each in its own PowerShell process.
#
# Examples:
#     .\Start-TestRun.ps1 -ConfigFilename TestConfig_remote_set03.ps1, TestConfig_remote_setCS.ps1 -Edition Desktop, Core -ContinueOnFailure -TestForWarnings
#     .\Start-TestRun.ps1 -ConfigFilename TestConfig_remote_setFCI.ps1, TestConfig_remote_set04.ps1 -ExcludeScenario '', HADR -ContinueOnFailure -TestForWarnings
#     .\Start-TestRun.ps1 -ConfigFilename TestConfig_remote_set04.ps1 -Scenario HADR -ContinueOnFailure -TestForWarnings
#     .\Start-TestRun.ps1 -ConfigFilename TestConfig_remote_set03.ps1, TestConfig_remote_setFCI.ps1 -WhatIf   # refused: both on SQL03
#
# Before anything starts, the sets are checked against the rules in TestConfig_remote_instances.ps1: no set twice,
# disjoint hosts, and at most one Hadr instance inside the availability group cluster. The second, fourth, ... run
# gets -ReverseOrder, so that two runs cross once instead of processing the same test file at the same moment.
#
# Start this from a PowerShell console, not from a tool that inherits another PATH: on 2026-09-16 two runs started
# from Git Bash had Git's usr\bin first in PATH, its whoami answered "Admin" instead of "ORDIX\Admin", and two tests
# failed for that reason alone. A Windows PowerShell child started from pwsh inherits the PSModulePath of pwsh and
# loads the wrong modules; the Desktop runs below therefore get the module path of Windows PowerShell.
#
# The console output of every run goes to logs\console_<set>_<timestamp>.out.txt (errors to .err.txt); the results
# go where run_tests.ps1 always writes them, logs\results_<scenario>_<timestamp>.txt.

[CmdletBinding(SupportsShouldProcess)]
param (
    # One config file per run. Two runs need disjoint hosts, see above.
    [Parameter(Mandatory)]
    [string[]]$ConfigFilename,
    # One per run, or one for all. Desktop is powershell.exe (5.1), Core is pwsh.exe.
    [ValidateSet('Desktop', 'Core')]
    [string[]]$Edition = 'Desktop',
    # One per run, or one for all. An empty string means no exclusion.
    [string[]]$ExcludeScenario = '',
    # Applies to every run.
    [ValidateSet('SINGLE', 'MULTI', 'COPY', 'HADR', 'RESTART', '2008R2SP2Express')]
    [string]$Scenario,
    [switch]$ContinueOnFailure,
    [switch]$TestForWarnings,
    [switch]$SkipEnvironmentTest,
    [switch]$CheckSleepingConnections,
    # Passed through to run_tests.ps1 for every run. Handy to watch two sets on a handful of files first.
    [int]$NumberOfTestsToTest,
    [string]$CommandToStartWith,
    # Keeps every run in alphabetical order instead of reversing every second one.
    [switch]$KeepOrder,
    # Reverses every run. Needed to resume a reversed run on its own, together with -CommandToStartWith.
    [switch]$ReverseOrder,
    # Seconds between two starts. The run stamp has a resolution of one second and names the result file.
    [int]$StartGapSeconds = 5
)

$ErrorActionPreference = 'Stop'

$githubBase  = 'C:\GitHub'
$testingBase = "$githubBase\testing-dbatools"
$logPath     = "$testingBase\logs"

$scenarioNames = 'SINGLE', 'MULTI', 'COPY', 'HADR', 'RESTART', '2008R2SP2Express'

function Get-RunValue {
    # One value for all runs, or one value per run.
    param([string[]]$Values, [int]$Index, [string]$Name)
    if ($Values.Count -eq 1) {
        return $Values[0]
    }
    if ($Values.Count -ne $ConfigFilename.Count) {
        throw "$Name has $($Values.Count) values, but there are $($ConfigFilename.Count) config files. Give one value for all runs or one per run."
    }
    return $Values[$Index]
}

# The config files only mutate a $config hashtable, so they can be read without importing dbatools.
$runs = for ($index = 0; $index -lt $ConfigFilename.Count; $index++) {
    $configFile = "$testingBase\$($ConfigFilename[$index])"
    if (-not (Test-Path -Path $configFile)) {
        throw "Configuration file not found: $configFile"
    }
    $config = @{ }
    . $configFile

    $instances = $config.Keys |
        Where-Object { $_ -match '^Instance' -and $_ -ne 'InstanceConfiguration' -and $config[$_] -is [string] -and $config[$_] } |
        ForEach-Object { $config[$_] } |
        Sort-Object -Unique
    $hosts = $instances | ForEach-Object { ($_ -split '\\')[0] } | Sort-Object -Unique
    $hadrHost = ($config['InstanceHadr'] -split '\\')[0]

    $runExcludeScenario = Get-RunValue -Values $ExcludeScenario -Index $index -Name 'ExcludeScenario'
    if ($runExcludeScenario -and $runExcludeScenario -notin $scenarioNames) {
        throw "ExcludeScenario '$runExcludeScenario' is not one of $($scenarioNames -join ', ')"
    }
    $runEdition = Get-RunValue -Values $Edition -Index $index -Name 'Edition'

    # Does this run create availability groups inside the cluster? Only then rule 2 applies.
    $runsHadr = ($runExcludeScenario -ne 'HADR') -and (-not $Scenario -or $Scenario -eq 'HADR')

    [PSCustomObject]@{
        Index           = $index
        ConfigFilename  = $ConfigFilename[$index]
        SetName         = $ConfigFilename[$index] -replace '^TestConfig_(remote_)?(.+)\.ps1$', '$2'
        Edition         = $runEdition
        ExcludeScenario = $runExcludeScenario
        ReverseOrder    = $ReverseOrder -or ((-not $KeepOrder) -and ($index % 2 -eq 1))
        Instances       = $instances
        Hosts           = $hosts
        HadrInCluster   = $runsHadr -and ($hadrHost -in $config['ClusterWitnessNodes'])
    }
}

# The rules for running side by side.
$problems = @()
$duplicateSets = $runs | Group-Object -Property ConfigFilename | Where-Object Count -gt 1
foreach ($duplicateSet in $duplicateSets) {
    $problems += "$($duplicateSet.Name) is listed $($duplicateSet.Count) times; a set cannot run beside itself."
}
for ($first = 0; $first -lt $runs.Count; $first++) {
    for ($second = $first + 1; $second -lt $runs.Count; $second++) {
        $sharedHosts = @($runs[$first].Hosts | Where-Object { $_ -in $runs[$second].Hosts })
        if ($sharedHosts) {
            $problems += "$($runs[$first].SetName) and $($runs[$second].SetName) share the host(s) $($sharedHosts -join ', '); 41 test files act on the host of an instance."
        }
        if ($runs[$first].HadrInCluster -and $runs[$second].HadrInCluster) {
            $problems += "$($runs[$first].SetName) and $($runs[$second].SetName) both create availability groups inside the cluster; run one of them with -ExcludeScenario HADR and its HADR scenario afterwards."
        }
    }
}
if ($problems) {
    throw "These sets cannot run side by side:`n  $($problems -join "`n  ")"
}

foreach ($run in $runs) {
    Write-Host ("{0,-8} {1,-7} {2,-16} {3}" -f $run.SetName, $run.Edition, $(if ($run.ExcludeScenario) { "not $($run.ExcludeScenario)" } elseif ($Scenario) { $Scenario } else { 'all' }), ($run.Instances -join ', '))
}

# Windows PowerShell must not inherit the module path of pwsh, see above.
$desktopModulePath = "$HOME\Documents\WindowsPowerShell\Modules;$env:ProgramFiles\WindowsPowerShell\Modules;$env:windir\System32\WindowsPowerShell\v1.0\Modules"

$started = foreach ($run in $runs) {
    $arguments = @(
        '-NoProfile'
        '-ExecutionPolicy', 'Bypass'
        '-File', "$testingBase\run_tests.ps1"
        '-ConfigFilename', $run.ConfigFilename
    )
    if ($run.ExcludeScenario) {
        $arguments += '-ExcludeScenario', $run.ExcludeScenario
    }
    if ($Scenario) {
        $arguments += '-Scenario', $Scenario
    }
    if ($NumberOfTestsToTest) {
        $arguments += '-NumberOfTestsToTest', $NumberOfTestsToTest
    }
    if ($CommandToStartWith) {
        $arguments += '-CommandToStartWith', $CommandToStartWith
    }
    foreach ($switchName in 'ContinueOnFailure', 'TestForWarnings', 'SkipEnvironmentTest', 'CheckSleepingConnections') {
        if ((Get-Variable -Name $switchName -ValueOnly)) {
            $arguments += "-$switchName"
        }
    }
    if ($run.ReverseOrder) {
        $arguments += '-ReverseOrder'
    }

    $executable = if ($run.Edition -eq 'Desktop') { 'powershell.exe' } else { 'pwsh.exe' }
    $stamp = [datetime]::Now.ToString('yyyyMMdd_HHmmss')
    $consoleOut = "$logPath\console_$($run.SetName)_$stamp.out.txt"
    $consoleErr = "$logPath\console_$($run.SetName)_$stamp.err.txt"

    if (-not $PSCmdlet.ShouldProcess("$($run.SetName) ($($run.Edition))", "$executable $($arguments -join ' ')")) {
        continue
    }

    $savedModulePath = $env:PSModulePath
    if ($run.Edition -eq 'Desktop') {
        $env:PSModulePath = $desktopModulePath
    }
    try {
        $splatStart = @{
            FilePath               = $executable
            ArgumentList           = $arguments
            WorkingDirectory       = $testingBase
            RedirectStandardOutput = $consoleOut
            RedirectStandardError  = $consoleErr
            WindowStyle            = 'Minimized'
            PassThru               = $true
        }
        $process = Start-Process @splatStart
    } finally {
        $env:PSModulePath = $savedModulePath
    }
    Write-Host "Started $($run.SetName) ($($run.Edition)) as process $($process.Id), console output in $consoleOut"
    [PSCustomObject]@{
        SetName    = $run.SetName
        Edition    = $run.Edition
        ProcessId  = $process.Id
        ConsoleOut = $consoleOut
    }

    if ($run.Index -lt $runs.Count - 1) {
        Start-Sleep -Seconds $StartGapSeconds
    }
}

$started
