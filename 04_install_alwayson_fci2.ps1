[CmdletBinding()]
param (
    [string]$ClusterName = 'CLUSTER01',
    [string[]]$ClusterNodes = @('SQL01', 'SQL02'),
    [string]$SqlNetworkName = 'FCI02',
    [string]$SqlInstance = 'SQL2022',
    [string]$SqlIP = '192.168.3.72',
    [string]$SqlIPSubnet = '255.255.255.0',
    [string]$SqlVersion = 2022
)

$ErrorActionPreference = 'Stop'

Import-Module -Name PSFramework
Import-Module -Name ActiveDirectory
Import-Module -Name dbatools

try {

$installCredential = [PSCredential]::new("ORDIX\Admin", (ConvertTo-SecureString -String 'P@ssw0rd' -AsPlainText -Force))
$sqlServiceCredential = [PSCredential]::new("ORDIX\gMSA-SQLServer$", [SecureString]::new())

Write-PSFMessage -Level Verbose -Message "Getting owner node for available disks"
$ownerNode = (Get-ClusterGroup -Cluster $ClusterName -Name 'Available Storage').OwnerNode.Name
if ($ownerNode -ne $ClusterNodes[0]) {
    Write-PSFMessage -Level Verbose -Message "Moving available disks to first node"
    $null = Move-ClusterGroup -Cluster $ClusterName -Name 'Available Storage' -Node $ClusterNodes[0]
}

Write-PSFMessage -Level Verbose -Message "Getting drive letter for $SqlInstance"
$cimSession = New-CimSession -ComputerName $ClusterNodes[0]
$driveLetter = (Get-Volume -CimSession $cimSession -FileSystemLabel $SqlInstance).DriveLetter
Write-PSFMessage -Level Verbose -Message "Using drive letter $driveLetter"
$cimSession | Remove-CimSession

$paramsInstallFailoverCluster = @{
    ComputerName       = $ClusterNodes[0]
    InstanceName       = $SqlInstance
    Version            = $SqlVersion

    Configuration      = @{
        ACTION                     = 'InstallFailoverCluster'
        FAILOVERCLUSTERNETWORKNAME = $SqlNetworkName
        FAILOVERCLUSTERDISKS       = "Cluster Disk $SqlInstance"
        FAILOVERCLUSTERGROUP       = "SQL Server ($SqlInstance)"
        FAILOVERCLUSTERIPADDRESSES = "IPv4;$SqlIP;Cluster Network Public;$SqlIPSubnet"
        INSTALLSQLDATADIR          = "$($driveLetter):\$SqlInstance"
    }

    Feature            = 'Engine'
    AuthenticationMode = 'Mixed'
    AdminAccount       = $installCredential.UserName

    EngineCredential   = $sqlServiceCredential
    AgentCredential    = $sqlServiceCredential
    Path               = '\\fs\Software\SQLServer\ISO'
    UpdateSourcePath   = '\\fs\Software\SQLServer\CU'
    Restart            = $true
    Credential         = $installCredential
    Confirm            = $false
}

$paramsAddNode = @{
    ComputerName       = $ClusterNodes[1]
    InstanceName       = $SqlInstance
    Version            = $SqlVersion

    Configuration      = @{ ACTION = 'AddNode' }

    EngineCredential   = $sqlServiceCredential
    AgentCredential    = $sqlServiceCredential
    Path               = '\\fs\Software\SQLServer\ISO'
    UpdateSourcePath   = '\\fs\Software\SQLServer\CU'
    Restart            = $true
    Credential         = $installCredential
    Confirm            = $false
}

Write-PSFMessage -Level Host -Message "Installing first node"

$result = Install-DbaInstance @paramsInstallFailoverCluster
$result | Format-Table
if (-not $result.Successful) {
    throw "Failed to install SQL Server on $($paramsInstallFailoverCluster.ComputerName)"
}
$server = Connect-DbaInstance -SqlInstance "$SqlNetworkName\$SqlInstance" -TrustServerCertificate

Write-PSFMessage -Level Host -Message "Installing second node"

$result = Install-DbaInstance @paramsAddNode
$result | Format-Table
if (-not $result.Successful) {
    throw "Failed to install SQL Server on $($paramsAddNode.ComputerName)"
}

Write-PSFMessage -Level Host -Message 'Finished'

} catch { Write-PSFMessage -Level Warning -Message 'Failed' -ErrorRecord $_ }
