# Sets up a PowerShell session for working on dbatools in this lab.
# Has to be dot-sourced, because it sets variables that are used afterwards:
#     . .\Initialize-LabSession.ps1
#
# Afterwards $TestConfig is available and dbatools is imported from the local repository,
# so that changes to the source code are tested without reinstalling the module.

[CmdletBinding()]
param (
    [string]$ConfigFilename = 'TestConfig_remote_instances.ps1',
    # Imports the installed module from the gallery instead of the local repository.
    [switch]$UseInstalledModule
)

$ErrorActionPreference = 'Stop'

$githubBase   = 'C:\GitHub'
$dbatoolsBase = "$githubBase\dbatools"
$testingBase  = "$githubBase\testing-dbatools"

$configFile = "$testingBase\$ConfigFilename"
if (-not (Test-Path -Path $configFile)) {
    # Get-TestConfig silently falls back to autodetection if the file is missing,
    # which leads to tests running against the wrong instances. So we stop here instead.
    throw "Configuration file not found: $configFile"
}

if ($UseInstalledModule) {
    Import-Module -Name dbatools -Force
} else {
    Import-Module -Name "$dbatoolsBase\dbatools.psm1" -Force
}

$TestConfig = Get-TestConfig -LocalConfigPath $configFile

# The same defaults that the tests use, so that commands typed by hand behave like commands inside a test.
$PSDefaultParameterValues = $TestConfig.Defaults.Clone()
$PSDefaultParameterValues['*-Dba*:EnableException'] = $true

Write-Host "dbatools $((Get-Module -Name dbatools).Version) imported from $((Get-Module -Name dbatools).Path)"
Write-Host "Configuration loaded from $configFile"
Write-Host "Configured instances:"
$TestConfig.PSObject.Properties |
    Where-Object { $_.Name -match '^Instance' -and $_.Name -notin 'InstanceConfiguration', 'instance2_detailed' -and $_.Value -is [string] -and $_.Value } |
    ForEach-Object { "    {0,-16} {1}" -f $_.Name, $_.Value }
