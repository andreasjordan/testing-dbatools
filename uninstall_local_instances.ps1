$ErrorActionPreference = 'Stop'

$githubBase   = 'C:\GitHub'

$dbatoolsBase = "$githubBase\dbatools"
$testingBase = "$githubBase\testing-dbatools"

$configFile = "$testingBase\TestConfig_local_instanes.ps1"

Import-Module -Name "$dbatoolsBase\dbatools.psm1" -Force
$PSDefaultParameterValues['*-Dba*:EnableException'] = $true
$PSDefaultParameterValues['*-Dba*:Confirm'] = $false
$null = Set-DbatoolsInsecureConnection

$TestConfig = Get-TestConfig -LocalConfigPath $configFile
$sqlInstance = $TestConfig.instance1, $TestConfig.instance2, $TestConfig.instance3

$instanceParams = @{
    Version         = $TestConfig.InstanceConfiguration.Version
    Path            = $TestConfig.InstanceConfiguration.SourcePath
    Configuration   = @{ ACTION = 'Uninstall' }
    EnableException = $false
}

foreach ($instance in $sqlInstance) {
    # $instance = $sqlInstance[0]
    if (-not (Get-DbaService -SqlInstance $instance)) {
        continue
    }
    Write-Host "[$([datetime]::Now.ToString('HH:mm:ss'))] Starting uninstall of $instance"
    $result = Install-DbaInstance @instanceParams -SqlInstance $instance
    Write-Host "[$([datetime]::Now.ToString('HH:mm:ss'))] Finished uninstall of $instance"
    if ($result.Successful -ne $true) {
        $result
        throw "[$([datetime]::Now.ToString('HH:mm:ss'))] Uninstallation failed"
    }
    if ($result.Notes -match 'restart') {
        throw "[$([datetime]::Now.ToString('HH:mm:ss'))] Restart needed"
    }
}

Remove-Item -Path 'C:\Program Files\Microsoft SQL Server\MSSQL*' -Recurse
Remove-Item -Path "$($TestConfig)\*" -Recurse -ErrorAction SilentlyContinue

Write-Host "[$([datetime]::Now.ToString('HH:mm:ss'))] Finished uninstall"
