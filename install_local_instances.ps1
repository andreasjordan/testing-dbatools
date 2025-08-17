$ErrorActionPreference = 'Stop'

$githubBase   = 'C:\GitHub'

$dbatoolsBase = "$githubBase\dbatools"
$testingBase = "$githubBase\testing-dbatools"

$configFile = "$testingBase\TestConfig_local_instanes.ps1"

Import-Module -Name dbatools
$PSDefaultParameterValues['*-Dba*:EnableException'] = $true
$PSDefaultParameterValues['*-Dba*:Confirm'] = $false
$null = Set-DbatoolsInsecureConnection

. "$dbatoolsBase\private\testing\Get-TestConfig.ps1"
$TestConfig = Get-TestConfig -LocalConfigPath $configFile
$sqlInstance = $TestConfig.instance1, $TestConfig.instance2, $TestConfig.instance3

$instanceParams = @{
    Version            = $TestConfig.InstanceConfiguration.Version
    Path               = $TestConfig.InstanceConfiguration.SourcePath
    Feature            = 'Engine'
    IFI                = $true
    Configuration      = @{
        SqlMaxMemory = '1024'
    }
    AuthenticationMode = 'Mixed'
    SaCredential       = $TestConfig.SqlCred
    EnableException    = $false
}
if ($TestConfig.InstanceConfiguration.UpdateSourcePath) {
    $instanceParams.UpdateSourcePath = $TestConfig.InstanceConfiguration.UpdateSourcePath
}
if (Test-Path -Path 'C:\SQLServerFull') {
    # We are on an Azure virtual maschine with preinstalled SQL Server
    $server = Connect-DbaInstance -SqlInstance $sqlInstance[0]
    $server.LoginMode = 'Mixed'
    $server.Alter()
    $null = Restart-DbaService -SqlInstance $sqlInstance[0] -Type Engine -Force
    $null = Set-DbaLogin -SqlInstance $sqlInstance[0] -Login sa -Enable
}

foreach ($instance in $sqlInstance) {
    # $instance = $sqlInstance[0]
    if (Get-DbaService -SqlInstance $instance) {
        continue
    }
    Write-Host "[$([datetime]::Now.ToString('HH:mm:ss'))] Starting install of $instance"
    $result = Install-DbaInstance @instanceParams -SqlInstance $instance -WarningVariable WarnVar
    Write-Host "[$([datetime]::Now.ToString('HH:mm:ss'))] Finished install of $instance"
    if ($WarnVar -match 'pending a reboot') {
        Write-Warning -Message "[$([datetime]::Now.ToString('HH:mm:ss'))] Restart needed"
		Restart-Computer -Force -Confirm
		return
    }
    if ($result.Successful -ne $true) {
        $result
        Write-Warning -Message "[$([datetime]::Now.ToString('HH:mm:ss'))] Installation failed"
		return
    }
    if ($result.Notes -match 'restart') {
        Write-Warning -Message "[$([datetime]::Now.ToString('HH:mm:ss'))] Restart needed"
		Restart-Computer -Force -Confirm
		return
    }
}

$null = Set-DbaSpConfigure -SqlInstance $sqlInstance -Name IsSqlClrEnabled -Value $true
$null = Set-DbaSpConfigure -SqlInstance $sqlInstance -Name ClrStrictSecurity -Value $false

$null = Set-DbaSpConfigure -SqlInstance $sqlInstance[1, 2] -Name ExtensibleKeyManagementEnabled -Value $true
Invoke-DbaQuery -SqlInstance $sqlInstance[1, 2] -Query "CREATE CRYPTOGRAPHIC PROVIDER dbatoolsci_AKV FROM FILE = '$($TestConfig.appveyorlabrepo)\keytests\ekm\Microsoft.AzureKeyVaultService.EKM.dll'"
$null = Enable-DbaAgHadr -SqlInstance $sqlInstance[1, 2] -Force

Invoke-DbaQuery -SqlInstance $sqlInstance[2] -Query "CREATE MASTER KEY ENCRYPTION BY PASSWORD = '<StrongPassword>'"
Invoke-DbaQuery -SqlInstance $sqlInstance[2] -Query "CREATE CERTIFICATE dbatoolsci_AGCert WITH SUBJECT = 'AG Certificate'"

$null = Set-DbaNetworkConfiguration -SqlInstance $sqlInstance[1] -StaticPortForIPAll 14333 -RestartService
$null = Set-DbaNetworkConfiguration -SqlInstance $sqlInstance[2] -StaticPortForIPAll 14334 -RestartService

if (-not (Test-Path -Path $TestConfig.Temp)) {
    $null = New-Item -Path $TestConfig.Temp -ItemType Directory
}

Write-Host "[$([datetime]::Now.ToString('HH:mm:ss'))] Finished install"
