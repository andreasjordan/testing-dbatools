$ErrorActionPreference = 'Stop'

$githubBase   = 'C:\GitHub'

$dbatoolsBase = "$githubBase\dbatools"
$testingBase = "$githubBase\testing-dbatools"

$configFile = "$testingBase\TestConfig_local_instanes.ps1"
$logPath    = "$testingBase\logs"

Import-Module -Name "$dbatoolsBase\dbatools.psm1" -Force
$null = Set-DbatoolsInsecureConnection

$TestConfig = Get-TestConfig -LocalConfigPath $configFile




$results = Get-Content -Path "$logPath\results_*.txt" | ConvertFrom-Json
$selected = $results | ogv -PassThru
