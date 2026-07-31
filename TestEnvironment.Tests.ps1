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
}

Describe "the temporary files" {
    It "Has no files in legacy temp folder" -Skip:($TestConfig.Temp -eq 'C:\Temp') {
        Get-ChildItem -Path C:\Temp -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It "Has no files in new temp folder" {
        Get-ChildItem -Path $TestConfig.Temp | Should -BeNullOrEmpty
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
