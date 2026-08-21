#Requires -Module @{ ModuleName="Pester"; ModuleVersion="6.0"}
param(
    $ModuleName               = "dbatools",
    $PSDefaultParameterValues = $TestConfig.Defaults
)

BeforeDiscovery {
    # Test every instance the loaded configuration knows about.
    # This supports both configuration generations: the current names
    # (InstanceSingle, InstanceMulti1, ...) and the legacy instance1/2/3.
    # Several configuration entries usually point at the same instance,
    # so we sort them unique to test each instance only once.
    $excludedKeys = 'InstanceConfiguration', 'instance2_detailed'
    $instance = $TestConfig.PSObject.Properties |
        Where-Object { $_.Name -match '^Instance' -and $_.Name -notin $excludedKeys -and $_.Value -is [string] -and $_.Value } |
        ForEach-Object { $_.Value } |
        Sort-Object -Unique

    # The failover clusters of the lab, if the configuration knows about any.
    $cluster = @($TestConfig.ClusterStorage, $TestConfig.ClusterWitness) | Where-Object { $_ }
}

Describe "the temporary files" {
    It "Has no files in legacy temp folder" -Skip:($TestConfig.Temp -eq 'C:\Temp') {
        Get-ChildItem -Path C:\Temp -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It "Has no files in new temp folder" {
        Get-ChildItem -Path $TestConfig.Temp | Should -BeNullOrEmpty
    }
}

Describe "the cluster <_>" -ForEach $cluster {
    BeforeAll {
        $clusterInfo = Get-DbaWsfcCluster -ComputerName $PSItem
        $clusterResource = Get-DbaWsfcResource -ComputerName $PSItem
        $clusterVolume = Get-DbaWsfcSharedVolume -ComputerName $PSItem
        $clusterAvailableDisk = Get-DbaWsfcAvailableDisk -ComputerName $PSItem
    }

    It "Has the expected quorum type" {
        # A test that changes the quorum leaves every later run guessing, so this is worth asserting.
        $expectedQuorumType = if ($PSItem -eq $TestConfig.ClusterWitness) { "Node and File Share Majority" } else { "Node and Disk Majority" }
        $clusterInfo.QuorumType | Should -Be $expectedQuorumType
    }

    It "Has the expected witness" {
        if ($PSItem -eq $TestConfig.ClusterWitness) {
            $witness = $clusterResource | Where-Object Type -eq "File Share Witness"
            $witness.PrivateProperties.SharePath | Should -Be $TestConfig.ClusterWitnessPath
        } else {
            ($clusterResource | Where-Object Name -eq "Cluster Disk Quorum").State | Should -Be "Online"
        }
    }

    It "Has exactly one cluster shared volume" -Skip:($PSItem -ne $TestConfig.ClusterStorage) {
        $clusterVolume | Should -HaveCount 1
    }

    It "Has exactly one available disk" -Skip:($PSItem -ne $TestConfig.ClusterStorage) {
        # The disk exists only so that Get-DbaWsfcAvailableDisk has something to return.
        # A test that adds it to the cluster takes that fixture away from every later run.
        $clusterAvailableDisk | Should -HaveCount 1
    }

    It "Has no offline resource" {
        $offlineResources = ($clusterResource | Where-Object State -ne "Online").Name
        $offlineResources | Should -BeNullOrEmpty
    }
}

Describe "the instance <_>" -ForEach $instance {
    BeforeAll {
        $server = Connect-DbaInstance -SqlInstance $PSItem
        $netConf = Get-DbaNetworkConfiguration -SqlInstance $server
        $agHadr = Get-DbaAgHadr -SqlInstance $PSItem

        # The default backup folder is a local path on the host of the instance,
        # so we have to go through the admin share to reach a remote instance.
        $backupPath = $server.BackupDirectory
        if ($server.ComputerName -ne $env:COMPUTERNAME) {
            $backupPath = '\\{0}\{1}' -f $server.ComputerName, ($backupPath -replace '^([A-Za-z]):', '$1$')
        }
    }

    It "Has no files in default backup folder" {
        Get-ChildItem -Path $backupPath | Should -HaveCount 0
    }

    It "Has no user databases" {
        $userDatabaseNames = ($server.Databases | Where-Object Name -notin 'master', 'tempdb', 'model', 'msdb').Name
        $userDatabaseNames | Should -BeNullOrEmpty
    }

    It "Has no system database with an open log chain" {
        # A full backup of a system database in the full recovery model starts its log chain. If no
        # log backup ever follows, the log can never be reused and grows a little on every test run.
        # That growth is in the file size, so a restart does not undo it, and it surfaces much later
        # as a completely unrelated failure: a new database's log is never smaller than model's, so
        # New-DbaDatabase.Tests.ps1 fails its log size assertion once model's log passes 32 MB.
        # Backup-DbaDatabase.Tests.ps1 did exactly this to model on InstanceCopy1 until 2026-08-15.
        #
        # last_log_backup_lsn is NULL while a database has never had a full backup ("pseudo-simple")
        # and is set the moment one runs, so this fails for the test file that started the chain.
        # Do not use log_reuse_wait_desc or SMO's LogReuseWaitStatus instead: both still read NOTHING
        # directly after the backup and only turn to LOG_BACKUP once enough log has accumulated,
        # which would blame whichever test file happens to run later.
        $queryOpenLogChain = @"
SELECT d.name AS DbName
FROM sys.databases AS d
JOIN sys.database_recovery_status AS rs ON rs.database_id = d.database_id
WHERE d.name IN (N'master', N'model', N'msdb')
  AND d.recovery_model_desc <> 'SIMPLE'
  AND rs.last_log_backup_lsn IS NOT NULL
"@
        $openLogChainDatabases = (Invoke-DbaQuery -SqlInstance $server -Database master -Query $queryOpenLogChain).DbName
        $openLogChainDatabases | Should -BeNullOrEmpty
    }

    It "Has no mirroring endpoints" {
        $mirroringEndpointNames = ($server.Endpoints | Where-Object EndpointType -eq DatabaseMirroring).Name
        $mirroringEndpointNames | Should -BeNullOrEmpty
    }

    It "Has no non system sql logins" {
        $sqlLoginNames = ($server.Logins | Where-Object { $_.LoginType -eq 'SqlLogin' -and $_.Name -notmatch '^##' -and $_.Name -ne 'sa' }).Name
        $sqlLoginNames | Should -BeNullOrEmpty
    }

    It "Has default trace enabled" {
        $server.Configuration.DefaultTraceEnabled.RunValue | Should -Be 1
    }

    It "Has the correct TCP port configured" {
        # Only the instances listed in the configuration need a static port,
        # all other instances are free to use whatever dynamic port they got.
        $expectedTcpPort = $TestConfig.ExpectedTcpPort[$PSItem]
        if (-not $expectedTcpPort) {
            Set-ItResult -Skipped -Because "no static port is configured for $PSItem"
        }

        ($netConf.TcpIpAddresses | Where-Object Name -eq IPAll).TcpPort | Should -Be $expectedTcpPort
    }

    It "Has the correct Hadr setting" {
        $agHadr.IsHadrEnabled | Should -Be ($PSItem -in $TestConfig.HadrInstances)
    }

    It "Has a certificate (if needed)" {
        $certificate = $server.Databases['master'].Certificates | Where-Object Name -eq 'dbatoolsci_AGCert'
        if ($PSItem -in $TestConfig.AgCertificateInstances) {
            $certificate | Should -Not -BeNullOrEmpty
        } else {
            $certificate | Should -BeNullOrEmpty
        }
    }
}
