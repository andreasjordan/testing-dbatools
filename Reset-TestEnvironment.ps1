# Removes the leftovers that a failed or aborted test run leaves behind,
# so that TestEnvironment.Tests.ps1 passes again and the next run starts from a clean lab.
#
# This drops databases, logins and endpoints. Only run this against a test lab.
#
# Examples:
#     .\Reset-TestEnvironment.ps1 -WhatIf     # show what would be removed
#     .\Reset-TestEnvironment.ps1             # ask before removing
#     .\Reset-TestEnvironment.ps1 -Confirm:$false

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param (
    [string]$ConfigFilename = 'TestConfig_remote_instances.ps1',
    # Keeps the files in the legacy temp folder C:\Temp, which may contain files that are not from a test run.
    [switch]$SkipLegacyTemp
)

$ErrorActionPreference = 'Stop'

$testingBase = 'C:\GitHub\testing-dbatools'

. "$testingBase\Initialize-LabSession.ps1" -ConfigFilename $ConfigFilename

$instances = $TestConfig.PSObject.Properties |
    Where-Object { $_.Name -match '^Instance' -and $_.Name -notin 'InstanceConfiguration', 'instance2_detailed' -and $_.Value -is [string] -and $_.Value } |
    ForEach-Object { $_.Value } |
    Sort-Object -Unique


# Windows failover clusters
#
# Nothing here is repaired automatically. Putting a disk back or moving the quorum needs a judgement
# call that a cleanup script should not make on its own, so we only report the drift and say what
# restores it. Every Wsfc command of dbatools is a Get command, so a test run cannot cause any of
# this: it means someone has changed the cluster, or the lab was built without the fixtures.

$clusters = @($TestConfig.ClusterStorage, $TestConfig.ClusterWitness) | Where-Object { $_ }
foreach ($clusterName in $clusters) {
    # $clusterName = $clusters[0]
    $clusterInfo = Get-DbaWsfcCluster -ComputerName $clusterName
    if ($clusterName -eq $TestConfig.ClusterWitness) {
        $expectedQuorumType = 'Node and File Share Majority'
        $quorumRepair = "Set-ClusterQuorum -Cluster $clusterName -NodeAndFileShareMajority '$($TestConfig.ClusterWitnessPath)'"
    } else {
        $expectedQuorumType = 'Node and Disk Majority'
        $quorumRepair = "Set-ClusterQuorum -Cluster $clusterName -NodeAndDiskMajority 'Cluster Disk Quorum'"
    }
    if ($clusterInfo.QuorumType -ne $expectedQuorumType) {
        Write-Warning "Cluster $clusterName uses quorum type '$($clusterInfo.QuorumType)' but should use '$expectedQuorumType'. Restore it with: $quorumRepair"
    }
    if ($clusterName -eq $TestConfig.ClusterStorage) {
        $volumeCount = @(Get-DbaWsfcSharedVolume -ComputerName $clusterName).Count
        if ($volumeCount -ne 1) {
            Write-Warning "Cluster $clusterName has $volumeCount cluster shared volumes but should have 1. Restore it with: Add-ClusterSharedVolume -Cluster $clusterName -Name 'Cluster Disk CSV'"
        }
        $availableDiskCount = @(Get-DbaWsfcAvailableDisk -ComputerName $clusterName).Count
        if ($availableDiskCount -ne 1) {
            Write-Warning "Cluster $clusterName has $availableDiskCount available disks but should have 1. The disk that Get-DbaWsfcAvailableDisk needs has been added to the cluster and has to be removed from it again."
        }
    }
}


# Temporary folders

$tempPaths = @($TestConfig.Temp)
if (-not $SkipLegacyTemp -and $TestConfig.Temp -ne 'C:\Temp') {
    $tempPaths += 'C:\Temp'
}

foreach ($tempPath in $tempPaths) {
    $tempFiles = Get-ChildItem -Path $tempPath -ErrorAction SilentlyContinue
    foreach ($tempFile in $tempFiles) {
        if ($PSCmdlet.ShouldProcess($tempFile.FullName, 'Remove file')) {
            Remove-Item -Path $tempFile.FullName -Recurse -Force
        }
    }
}


# Everything on the instances

foreach ($instance in $instances) {
    # $instance = $instances[0]
    Write-Host "Checking $instance"

    $server = Connect-DbaInstance -SqlInstance $instance

    $userDatabases = Get-DbaDatabase -SqlInstance $server -ExcludeSystem
    foreach ($userDatabase in $userDatabases) {
        if ($PSCmdlet.ShouldProcess("$instance", "Remove database $($userDatabase.Name)")) {
            $null = Remove-DbaDatabase -SqlInstance $server -Database $userDatabase.Name -Confirm:$false
        }
    }

    $sqlLogins = Get-DbaLogin -SqlInstance $server -Type SQL | Where-Object { $_.Name -notmatch '^##' -and $_.Name -ne 'sa' }
    foreach ($sqlLogin in $sqlLogins) {
        if ($PSCmdlet.ShouldProcess("$instance", "Remove login $($sqlLogin.Name)")) {
            $null = Remove-DbaLogin -SqlInstance $server -Login $sqlLogin.Name -Confirm:$false
        }
    }

    $mirroringEndpoints = Get-DbaEndpoint -SqlInstance $server -Type DatabaseMirroring
    foreach ($mirroringEndpoint in $mirroringEndpoints) {
        if ($PSCmdlet.ShouldProcess("$instance", "Remove endpoint $($mirroringEndpoint.Name)")) {
            $null = Remove-DbaEndpoint -SqlInstance $server -Endpoint $mirroringEndpoint.Name -Confirm:$false
        }
    }

    # The default backup folder is a local path on the host of the instance,
    # so we have to go through the admin share to reach a remote instance.
    $backupPath = $server.BackupDirectory
    if ($server.ComputerName -ne $env:COMPUTERNAME) {
        $backupPath = '\\{0}\{1}' -f $server.ComputerName, ($backupPath -replace '^([A-Za-z]):', '$1$')
    }
    $backupFiles = Get-ChildItem -Path $backupPath -ErrorAction SilentlyContinue
    foreach ($backupFile in $backupFiles) {
        if ($PSCmdlet.ShouldProcess($backupFile.FullName, 'Remove file')) {
            Remove-Item -Path $backupFile.FullName -Recurse -Force
        }
    }
}

Write-Host "Finished. Run TestEnvironment.Tests.ps1 to verify that the lab is clean."
