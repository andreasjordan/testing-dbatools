$ErrorActionPreference = 'Stop'

$githubBase   = 'C:\GitHub'

$dbatoolsBase = "$githubBase\dbatools"
$testingBase = "$githubBase\testing-dbatools"
$logPath    = "$testingBase\logs"

# Get-ChildItem -Path $logPath -Filter results*.txt

$results = Get-ChildItem -Path $logPath -Filter results*.txt | Sort-Object LastWriteTime | Select-Object -Last 1 | Get-Content | ConvertFrom-Json

$results | Group-Object Result -NoElement

$passed = $results | Where-Object Result -eq 'Passed'
$failed = $results | Where-Object Result -eq 'Failed'

$failed.TestFileName

$failed[-1].TestsFailed

break


$selected = $passed | Out-GridView -PassThru
$selected = $failed | Out-GridView -PassThru
