[CmdletBinding()]
param (
    [string[]]$SqlInstances = @('FCI01', 'FCI02\SQL2022', 'SQL03\SQL2025', 'SQL03\SQL2022', 'SQL03\SQL2019', 'SQL04\SQL2025', 'SQL04\SQL2022', 'SQL04\SQL2019'),
    [string[]]$HadrInstances = @('SQL03\SQL2025', 'SQL04\SQL2025'),
    [string[]]$ServiceInstances = @('SQL03\SQL2022')
)

$ErrorActionPreference = 'Stop'

Import-Module -Name PSFramework
Import-Module -Name ActiveDirectory
Import-Module -Name dbatools

Write-PSFMessage -Level Host -Message 'Enabling remote DAC'
$null = Set-DbaSpConfigure -SqlInstance $SqlInstances -Name RemoteDacConnectionsEnabled -Value $true

Write-PSFMessage -Level Host -Message 'Creating master key'
Invoke-DbaQuery -SqlInstance $SqlInstances -Query "CREATE MASTER KEY ENCRYPTION BY PASSWORD = '<StrongPassword>'"

Write-PSFMessage -Level Host -Message 'Configuration for advanced encryption tests'
$null = Set-DbaSpConfigure -SqlInstance $SqlInstances -Name ExtensibleKeyManagementEnabled -Value $true
Invoke-DbaQuery -SqlInstance $SqlInstances -Query "CREATE CRYPTOGRAPHIC PROVIDER dbatoolsci_AKV FROM FILE = '\\fs\appveyor-lab\keytests\ekm\Microsoft.AzureKeyVaultService.EKM.dll'"

Write-PSFMessage -Level Host -Message 'Configuration for Availability Group tests'
$null = Enable-DbaAgHadr -SqlInstance $HadrInstances -Force
$null = New-DbaDbCertificate -SqlInstance $HadrInstances[0] -Name dbatoolsci_AGCert -Subject 'AG Certificate'
$null = Copy-DbaDbCertificate -Source $HadrInstances[0] -Destination $HadrInstances[1] -Certificate dbatoolsci_AGCert -SharedPath \\fs\Temp -Confirm:$false

Write-PSFMessage -Level Host -Message 'Configuration for service configuration tests'
$null = Set-DbaNetworkConfiguration -SqlInstance $ServiceInstances -StaticPortForIPAll 14333 -RestartService -Confirm:$false

Write-PSFMessage -Level Host -Message "Configuration for login lockout tests"
# A SQL login can only be locked out when the host running the instance has an account lockout
# threshold, and SQL Server reads that from the local policy of the host - the domain policy of this
# lab has no threshold at all. Set-DbaLogin.Tests.ps1 fails five logons on purpose, so the threshold
# has to be 5 or lower. Only the standalone hosts are configured here, because the computer name of
# an FCI is the cluster network name and a local policy cannot be set through that.
$lockoutComputers = @("SQL03", "SQL04")
$null = Invoke-Command -ComputerName $lockoutComputers -ScriptBlock { net accounts /lockoutthreshold:5 }

Write-PSFMessage -Level Host -Message 'Finished'
