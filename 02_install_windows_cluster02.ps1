[CmdletBinding()]
param (
    [string]$ClusterName = 'CLUSTER02',
    [string[]]$ClusterNodes = @('SQL03', 'SQL04'),
    [string]$ClusterIP = '192.168.3.80'
)

$ErrorActionPreference = 'Stop'

Import-Module -Name PSFramework
Import-Module -Name ActiveDirectory

try {

Write-PSFMessage -Level Host -Message 'Install cluster feature on each node'
Invoke-Command -ComputerName $ClusterNodes -ScriptBlock { Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools } | Format-Table

Write-PSFMessage -Level Host -Message 'Run cluster test'
$clusterTest = Test-Cluster -Node $ClusterNodes -WarningAction SilentlyContinue
# &$clusterTest.FullName

Write-PSFMessage -Level Host -Message 'Create the cluster'
$cluster = New-Cluster -Name $ClusterName -Node $ClusterNodes -StaticAddress $ClusterIP

Write-PSFMessage -Level Host -Message 'Configure cluster name to publish PTR records'
$cluster | Get-ClusterResource -Name 'Cluster Name' | Set-ClusterParameter -Name PublishPTRRecords -Value 1 -WarningAction SilentlyContinue
$null = $cluster | Stop-ClusterResource -Name 'Cluster Name'
$null = $cluster | Start-ClusterResource -Name 'Cluster Name'

Write-PSFMessage -Level Host -Message 'Rename cluster network for client access'
($cluster | Get-ClusterNetwork | Where-Object { $_.Role -eq 'ClusterAndClient' }).Name = 'Cluster Network Public'

Write-PSFMessage -Level Host -Message 'Grant rights to cluster'
$adComputerGUID = [GUID]::new('bf967a86-0de6-11d0-a285-00aa003049e2')
# If you don't trust me or https://docs.microsoft.com/en-us/windows/win32/adschema/c-computer
# $adComputerGUID = [GUID](Get-ADObject -Filter 'Name -eq "Computer"' -SearchBase (Get-ADRootDSE).schemaNamingContext -Properties schemaIDGUID).schemaIDGUID
$adClusterComputer = Get-ADComputer -Filter "Name -eq '$($ClusterName)'"
$adClusterIdentity = [System.Security.Principal.SecurityIdentifier]::new($adClusterComputer.SID)
$adClusterOU = [ADSI]([ADSI]"LDAP://$($adClusterComputer.DistinguishedName)").Parent
$accessRule1 = [System.DirectoryServices.ActiveDirectoryAccessRule]::new($adClusterIdentity, "ReadProperty", "Allow", [GUID]::Empty, "All", [GUID]::Empty)
$accessRule2 = [System.DirectoryServices.ActiveDirectoryAccessRule]::new($adClusterIdentity, "CreateChild", "Allow", $adComputerGUID, "All", [GUID]::Empty)
$adClusterOU.psbase.ObjectSecurity.AddAccessRule($accessRule1)
$adClusterOU.psbase.ObjectSecurity.AddAccessRule($accessRule2)
$adClusterOU.psbase.CommitChanges()

Write-PSFMessage -Level Host -Message 'Finished'

} catch { Write-PSFMessage -Level Warning -Message 'Failed' -ErrorRecord $_ }
