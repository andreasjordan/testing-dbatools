#Requires -Module @{ ModuleName="Pester"; ModuleVersion="5.0"}
param(
    $ModuleName               = "dbatools",
    $PSDefaultParameterValues = $TestConfig.Defaults
)

BeforeDiscovery {
    $instance = $TestConfig.instance1, $TestConfig.instance2, $TestConfig.instance3
}

Describe "the temporary files" {
    It -Skip:($TestConfig.Temp -eq 'C:\Temp') "Has no files in legacy temp folder" {
        Get-ChildItem -Path C:\Temp | Should -BeNullOrEmpty
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
    }

    #It "Has correct default backup folder" {
    #    $server.BackupDirectory | Should -match '^C..Program.Files.Microsoft.SQL.Server.MSSQL.*MSSQL.Backup$'
    #}

    It "Has no files in default backup folder" {
        # Works only for local instances
        Get-ChildItem -Path $server.BackupDirectory | Should -HaveCount 0
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
        if ($PSItem -eq $TestConfig.instance1) {
            $configTcpPort = 1433
        } elseif ($PSItem -eq $TestConfig.instance2) {
            $configTcpPort = 14333
        } elseif ($PSItem -eq $TestConfig.instance3) {
            $configTcpPort = 14334
        }

        ($netConf.TcpIpAddresses | Where-Object Name -eq IPAll).TcpPort | Should -Be $configTcpPort
    }

    It "Has the correct Hadr setting" {
        if ($PSItem -eq $TestConfig.instance1) {
            $targeIsHadrEnabled = $false
        } elseif ($PSItem -eq $TestConfig.instance2) {
            $targeIsHadrEnabled = $true
        } elseif ($PSItem -eq $TestConfig.instance3) {
            $targeIsHadrEnabled = $true
        }

        $agHadr.IsHadrEnabled | Should -Be $targeIsHadrEnabled
    }

    It "Has a certificate (if needed)" {
        if ($PSItem -eq $TestConfig.instance3) {
            $server.Databases['master'].Certificates | Where-Object Name -eq 'dbatoolsci_AGCert' | Should -Not -BeNullOrEmpty
        }
        if ($PSItem -ne $TestConfig.instance3) {
            $server.Databases['master'].Certificates | Where-Object Name -eq 'dbatoolsci_AGCert' | Should -BeNullOrEmpty
        }
    }
}