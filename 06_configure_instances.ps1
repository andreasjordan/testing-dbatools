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

try {

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

Write-PSFMessage -Level Host -Message 'Finished'

} catch { Write-PSFMessage -Level Warning -Message 'Failed' -ErrorRecord $_ }
