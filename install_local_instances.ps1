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
    Version            = $TestConfig.InstanceConfiguration.Version
    Path               = $TestConfig.InstanceConfiguration.SourcePath
    UpdateSourcePath   = $TestConfig.InstanceConfiguration.UpdateSourcePath
    Feature            = 'Engine'
    IFI                = $true
    Configuration      = @{
        SqlMaxMemory = '2048'
        NpEnabled    = 1
    }
    AuthenticationMode = 'Mixed'
    SaCredential       = $TestConfig.SqlCred
    EnableException    = $false
}

foreach ($instance in $sqlInstance) {
    # $instance = $sqlInstance[0]
    if (Get-DbaService -SqlInstance $instance) {
        continue
    }
    Write-Host "[$([datetime]::Now.ToString('HH:mm:ss'))] Starting install of $instance"
    $result = Install-DbaInstance @instanceParams -SqlInstance $instance
    Write-Host "[$([datetime]::Now.ToString('HH:mm:ss'))] Finished install of $instance"
    if ($result.Successful -ne $true) {
        $result
        throw "[$([datetime]::Now.ToString('HH:mm:ss'))] Installation failed"
    }
    if ($result.Notes -match 'restart') {
        throw "[$([datetime]::Now.ToString('HH:mm:ss'))] Restart needed"
    }
}

$null = Set-DbaSpConfigure -SqlInstance $sqlInstance -SqlCredential $TestConfig.SqlCred -Name IsSqlClrEnabled -Value $true
$null = Set-DbaSpConfigure -SqlInstance $sqlInstance -SqlCredential $TestConfig.SqlCred -Name ClrStrictSecurity -Value $false

$null = Set-DbaSpConfigure -SqlInstance $sqlInstance[1, 2] -SqlCredential $TestConfig.SqlCred -Name ExtensibleKeyManagementEnabled -Value $true
Invoke-DbaQuery -SqlInstance $sqlInstance[1, 2] -SqlCredential $TestConfig.SqlCred -Query "CREATE CRYPTOGRAPHIC PROVIDER dbatoolsci_AKV FROM FILE = '$($TestConfig.appveyorlabrepo)\keytests\ekm\Microsoft.AzureKeyVaultService.EKM.dll'"
$null = Enable-DbaAgHadr -SqlInstance $sqlInstance[1, 2] -Force

Invoke-DbaQuery -SqlInstance $sqlInstance[2] -SqlCredential $TestConfig.SqlCred -Query "CREATE MASTER KEY ENCRYPTION BY PASSWORD = '<StrongPassword>'"
Invoke-DbaQuery -SqlInstance $sqlInstance[2] -SqlCredential $TestConfig.SqlCred -Query "CREATE CERTIFICATE dbatoolsci_AGCert WITH SUBJECT = 'AG Certificate'"

$null = Set-DbaNetworkConfiguration -SqlInstance $sqlInstance[1] -StaticPortForIPAll 14333 -RestartService
$null = Set-DbaNetworkConfiguration -SqlInstance $sqlInstance[2] -StaticPortForIPAll 14334 -RestartService

if (-not (Test-Path -Path $TestConfig.Temp)) {
    $null = New-Item -Path $TestConfig.Temp -ItemType Directory
}

Write-Host "[$([datetime]::Now.ToString('HH:mm:ss'))] Finished install"
