$ErrorActionPreference = 'Stop'

$githubBase   = 'C:\GitHub'

$dbatoolsBase = "$githubBase\dbatools"
$testingBase = "$githubBase\testing-dbatools"

$configFile = "$testingBase\TestConfig_local_instanes.ps1"
$logPath    = "$testingBase\logs"

$resultsFileName = "$logPath\results_$([datetime]::Now.ToString('yyyMMdd_HHmmss')).txt"

Import-Module -Name "$dbatoolsBase\dbatools.psm1" -Force
$null = Set-DbatoolsInsecureConnection

$TestConfig = Get-TestConfig -LocalConfigPath $configFile

$null = Restart-DbaService -SqlInstance $TestConfig.instance1, $TestConfig.instance2, $TestConfig.instance2 -Type Engine -Force

$results = Get-Content -Path "$logPath\results_*.txt" | ConvertFrom-Json
$selected = $results | ogv -PassThru
