[CmdletBinding()]
param (
    [string[]]$SqlNodes = @('SQL03', 'SQL04'),
    [string[]]$SqlInstances = @('SQL2025', 'SQL2022', 'SQL2019')
)

$ErrorActionPreference = 'Stop'

Import-Module -Name PSFramework
Import-Module -Name ActiveDirectory
Import-Module -Name dbatools

$installCredential = [PSCredential]::new("ORDIX\Admin", (ConvertTo-SecureString -String 'P@ssw0rd' -AsPlainText -Force))
$sqlServiceCredential = [PSCredential]::new("ORDIX\gMSA-SQLServer$", [SecureString]::new())

$instanceParams = @{
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

foreach ($sqlInstance in $SqlInstances) {
    Write-PSFMessage -Level Host -Message "Starting install of $sqlInstance"
    $result = Install-DbaInstance @instanceParams -ComputerName $SqlNodes -InstanceName $sqlInstance -Version ($sqlInstance -replace '^\D+(\d+)$', '$1')
    if ($result.Successful -contains $false) {
        throw "Failed to install $sqlInstance"
    }
    foreach ($sqlNode in $SqlNodes) {
        $null = Connect-DbaInstance -SqlInstance "$sqlNode\$sqlInstance" -TrustServerCertificate
    }
}

Write-PSFMessage -Level Host -Message 'Finished'
