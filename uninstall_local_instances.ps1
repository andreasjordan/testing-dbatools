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
    $result = Install-DbaInstance @instanceParams -SqlInstance $instance -WarningVariable WarnVar
    Write-Host "[$([datetime]::Now.ToString('HH:mm:ss'))] Finished uninstall of $instance"
    if ($WarnVar -match 'pending a reboot') {
        Write-Warning -Message "[$([datetime]::Now.ToString('HH:mm:ss'))] Restart needed"
		Restart-Computer -Force -Confirm
		return
    }
    if ($result.Successful -ne $true) {
        $result
        Write-Warning -Message "[$([datetime]::Now.ToString('HH:mm:ss'))] Uninstallation failed"
		return
    }
    if ($result.Notes -match 'restart') {
        Write-Warning -Message "[$([datetime]::Now.ToString('HH:mm:ss'))] Restart needed"
		Restart-Computer -Force -Confirm
		return
    }
}

Remove-Item -Path 'C:\Program Files\Microsoft SQL Server\MSSQL*' -Recurse
Remove-Item -Path "$($TestConfig)\*" -Recurse -ErrorAction SilentlyContinue

Write-Host "[$([datetime]::Now.ToString('HH:mm:ss'))] Finished uninstall"
