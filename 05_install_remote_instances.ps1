[CmdletBinding()]
param (
    [string[]]$SqlNodes = @('SQL03', 'SQL04'),
    [string[]]$SqlInstances = @('SQL2025', 'SQL2022', 'SQL2019'),
    # Collation of master, which is what decides whether database and object names are case sensitive.
    # Empty means the setup default, SQL_Latin1_General_CP1_CI_AS, which is what SQL03 and SQL04 have.
    # SQL05 is installed with SQL_Latin1_General_CP1_CS_AS so that case sensitive behaviour can be
    # tested at all - see the case sensitivity finding on dbatools PR #10579.
    [string]$SqlCollation
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

if ($SqlCollation) {
    $instanceParams.SqlCollation = $SqlCollation
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
