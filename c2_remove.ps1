[CmdletBinding()]
param (
    [string]$ClusterName = 'CLUSTER01',
    [string[]]$ClusterNodes = @('SQL01', 'SQL02'),
    [string]$SqlNetworkName = 'FCI01',
    [string]$SqlInstance = 'MSSQLSERVER',
    [string]$SqlIP = '192.168.3.71',
    [string]$SqlIPSubnet = '255.255.255.0',
    [string]$SqlVersion = 2025
)

$installCredential = [PSCredential]::new("ORDIX\Admin", (ConvertTo-SecureString -String 'P@ssw0rd' -AsPlainText -Force))

$paramsRemoveNode = @{
    InstanceName  = $SqlInstance
    Version       = $SqlVersion

    Configuration = @{ ACTION = 'RemoveNode' }

    Path          = '\\fs\Software\SQLServer\ISO'
    Restart       = $true
    Credential    = $installCredential
    Confirm       = $false
}

$result = Install-DbaInstance @paramsRemoveNode -ComputerName $clusterNodes[0]
$result | Format-Table
if (-not $result.Successful) {
    throw "Failed to uninstall SQL Server"
}

$result = Install-DbaInstance @paramsRemoveNode -ComputerName $clusterNodes[1]
$result | Format-Table
if (-not $result.Successful) {
    throw "Failed to uninstall SQL Server"
}


