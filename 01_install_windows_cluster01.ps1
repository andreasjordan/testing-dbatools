$ErrorActionPreference = 'Stop'

$config = @{
    StorageServer = 'dc.ordix.local'
    StoragePath   = 'C:\iSCSIDisks'
    Targets       = @(
        @{
            Name  = 'StorageForCluster01'
            Nodes = @(
                'sql01.ordix.local'
                'sql02.ordix.local'
            )
            Disks = @(
                @{
                    Name        = 'Quorum'
                    Size        = 1GB
                    DriveLetter = 'Q'
                }
                @{
                    Name        = 'MSSQLSERVER'
                    Size        = 20GB
                    DriveLetter = 'S'
                }
                @{
                    Name        = 'SQL2022'
                    Size        = 20GB
                    DriveLetter = 'T'
                }
            )
        }
    )
    ClusterName   = 'CLUSTER01'
    ClusterIP     = '192.168.3.70'
}

try {

# Layer 1: Software and Service

# On the storage server: Install Windows feature
$result = Install-WindowsFeature -ComputerName $config.StorageServer -Name FS-iSCSITarget-Server
if (-not $result.Success) { throw "Installing WindowsFeature iSCSI Target Server failed" }

# On the clients: Configure iSCSI service
Set-Service -ComputerName $config.Targets.Nodes -Name MSiSCSI -StartupType Automatic -Status Running


# Layer 2: Create and connect storage

# On the storage server: Create directory for disks, create target, create and format disks, grant access to clients
Invoke-Command -ComputerName $config.StorageServer -ArgumentList $config.StoragePath -ScriptBlock { 
    Param([string]$StoragePath)
    if (-not (Test-Path -Path $StoragePath)) {
        $null = New-Item -Path $StoragePath -ItemType Directory 
    }
}
foreach ($target in $config.Targets) {
    # $target = $config.Targets[0]
    $null = New-IscsiServerTarget -ComputerName $config.StorageServer -TargetName $target.Name
    $cimSession = New-CimSession -ComputerName $config.StorageServer
    foreach ($disk in $target.Disks) {
        # $disk = $target.Disks[0]
        $diskPath = "$($config.StoragePath)\$($disk.Name).vhdx"
        $null = New-IscsiVirtualDisk -ComputerName $config.StorageServer -Path $diskPath -SizeBytes $disk.Size -Description $disk.Name

        Mount-DiskImage -CimSession $cimSession -ImagePath $diskPath
        $mountedDisk = Get-Disk -CimSession $cimSession | Where-Object PartitionStyle -eq 'RAW'
        $mountedDisk | Initialize-Disk -PartitionStyle GPT
        $partition = $mountedDisk | New-Partition -UseMaximumSize
        $null = $partition | Format-Volume -FileSystem NTFS -NewFileSystemLabel $disk.Name
        Dismount-DiskImage -CimSession $cimSession -ImagePath $diskPath

        Add-IscsiVirtualDiskTargetMapping -ComputerName $config.StorageServer -TargetName $target.Name -Path $diskPath
    }
    $initiatorIds = @( )
    foreach ($node in $target.Nodes) {
        $initiatorIds += "IQN:iqn.1991-05.com.microsoft:$node"
    }
    $null = Set-IscsiServerTarget -ComputerName $config.StorageServer -TargetName $target.Name -InitiatorIds $initiatorIds
    $cimSession | Remove-CimSession
}

# On the clients: Add target portal, connect to target, set disks online, set drive letter for all disks
foreach ($target in $config.Targets) {
    # $target = $config.Targets[0]
    # As we need a per-client loop anyway, we loop through the clients here to have a better logging that helps finding problems
    foreach ($node in $target.Nodes) {
        # $node = $target.Nodes[1]
        $cimSession = New-CimSession -ComputerName $node
        $null = New-IscsiTargetPortal -CimSession $cimSession -TargetPortalAddress $config.StorageServer
        $null = Get-IscsiTarget -CimSession $cimSession | Connect-IscsiTarget -IsPersistent $true
        Get-Disk -CimSession $cimSession | Where-Object IsOffline | Set-Disk -IsOffline $false
        foreach ($disk in $target.Disks) {
            # $disk = $target.Disks[0]
            # "$partition | Set-Partition" does not work if $partition has an empty drive letter - so we need a workaround
            $partition = Get-Volume -CimSession $cimSession -FileSystemLabel $disk.Name | Get-Partition
            if ($partition.DriveLetter -ne $disk.DriveLetter) {
                Set-Partition -CimSession $cimSession -DiskNumber $partition.DiskNumber -PartitionNumber $partition.PartitionNumber -NewDriveLetter $disk.DriveLetter
            }
        }
        $cimSession | Remove-CimSession
    }
}


$ClusterNodes = $config.Targets[0].Nodes

Write-PSFMessage -Level Host -Message 'Install cluster feature on each node'
Invoke-Command -ComputerName $ClusterNodes -ScriptBlock { Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools } | Format-Table

Write-PSFMessage -Level Host -Message 'Run cluster test'
$clusterTest = Test-Cluster -Node $ClusterNodes -WarningAction SilentlyContinue
# &$clusterTest.FullName

Write-PSFMessage -Level Host -Message 'Create the cluster'
$cluster = New-Cluster -Name $config.ClusterName -Node $ClusterNodes -StaticAddress $config.ClusterIP

Write-PSFMessage -Level Host -Message 'Configure cluster name to publish PTR records'
$cluster | Get-ClusterResource -Name 'Cluster Name' | Set-ClusterParameter -Name PublishPTRRecords -Value 1 -WarningAction SilentlyContinue
$null = $cluster | Stop-ClusterResource -Name 'Cluster Name'
$null = $cluster | Start-ClusterResource -Name 'Cluster Name'

Write-PSFMessage -Level Host -Message 'Rename cluster network for client access'
($cluster | Get-ClusterNetwork | Where-Object { $_.Role -eq 'ClusterAndClient' }).Name = 'Cluster Network Public'

Write-PSFMessage -Level Host -Message 'Rename cluster disks to include file system label'
$clusterDisks = Get-CimInstance -ComputerName $cluster.Name -Namespace Root\MSCluster -ClassName MSCluster_Resource | Where-Object Type -eq 'Physical Disk'
foreach ($clusterDisk in $clusterDisks) {
    # $clusterDisk = $clusterDisks[0]
    $partition = $clusterDisk | Get-CimAssociatedInstance -ResultClassName MSCluster_DiskPartition
    $null = $clusterDisk | Invoke-CimMethod -MethodName Rename -Arguments @{ newName = "Cluster Disk $($partition.VolumeLabel)" }
}

Write-PSFMessage -Level Host -Message 'Grant rights to cluster'
$adComputerGUID = [GUID]::new('bf967a86-0de6-11d0-a285-00aa003049e2')
# If you don't trust me or https://docs.microsoft.com/en-us/windows/win32/adschema/c-computer
# $adComputerGUID = [GUID](Get-ADObject -Filter 'Name -eq "Computer"' -SearchBase (Get-ADRootDSE).schemaNamingContext -Properties schemaIDGUID).schemaIDGUID
$adClusterComputer = Get-ADComputer -Filter "Name -eq '$($config.ClusterName)'"
$adClusterIdentity = [System.Security.Principal.SecurityIdentifier]::new($adClusterComputer.SID)
$adClusterOU = [ADSI]([ADSI]"LDAP://$($adClusterComputer.DistinguishedName)").Parent
$accessRule1 = [System.DirectoryServices.ActiveDirectoryAccessRule]::new($adClusterIdentity, "ReadProperty", "Allow", [GUID]::Empty, "All", [GUID]::Empty)
$accessRule2 = [System.DirectoryServices.ActiveDirectoryAccessRule]::new($adClusterIdentity, "CreateChild", "Allow", $adComputerGUID, "All", [GUID]::Empty)
$adClusterOU.psbase.ObjectSecurity.AddAccessRule($accessRule1)
$adClusterOU.psbase.ObjectSecurity.AddAccessRule($accessRule2)
$adClusterOU.psbase.CommitChanges()

Write-PSFMessage -Level Host -Message 'Finished'

} catch { Write-PSFMessage -Level Warning -Message 'Failed' -ErrorRecord $_ }
