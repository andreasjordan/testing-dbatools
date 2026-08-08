[CmdletBinding()]
param (
    [string[]]$SqlInstances = @('FCI01', 'FCI02\SQL2022', 'SQL03\SQL2025', 'SQL03\SQL2022', 'SQL03\SQL2019', 'SQL04\SQL2025', 'SQL04\SQL2022', 'SQL04\SQL2019'),
    [string[]]$HadrInstances = @('SQL03\SQL2025', 'SQL04\SQL2025'),
    [string[]]$ServiceInstances = @('SQL03\SQL2022')
)

$ErrorActionPreference = 'Stop'

Import-Module -Name PSFramework
Import-Module -Name ActiveDirectory
Import-Module -Name dbatools

Write-PSFMessage -Level Host -Message 'Enabling remote DAC'
$null = Set-DbaSpConfigure -SqlInstance $SqlInstances -Name RemoteDacConnectionsEnabled -Value $true

Write-PSFMessage -Level Host -Message 'Creating master key'
Invoke-DbaQuery -SqlInstance $SqlInstances -Query "CREATE MASTER KEY ENCRYPTION BY PASSWORD = '<StrongPassword>'"

Write-PSFMessage -Level Host -Message 'Configuration for advanced encryption tests'
$null = Set-DbaSpConfigure -SqlInstance $SqlInstances -Name ExtensibleKeyManagementEnabled -Value $true
Invoke-DbaQuery -SqlInstance $SqlInstances -Query "CREATE CRYPTOGRAPHIC PROVIDER dbatoolsci_AKV FROM FILE = '\\fs\appveyor-lab\keytests\ekm\Microsoft.AzureKeyVaultService.EKM.dll'"

Write-PSFMessage -Level Host -Message 'Configuration for Availability Group tests'
$null = Enable-DbaAgHadr -SqlInstance $HadrInstances -Force
$null = New-DbaDbCertificate -SqlInstance $HadrInstances[0] -Name dbatoolsci_AGCert -Subject 'AG Certificate'
$null = Copy-DbaDbCertificate -Source $HadrInstances[0] -Destination $HadrInstances[1] -Certificate dbatoolsci_AGCert -SharedPath \\fs\Temp -Confirm:$false

Write-PSFMessage -Level Host -Message 'Configuration for service configuration tests'
$null = Set-DbaNetworkConfiguration -SqlInstance $ServiceInstances -StaticPortForIPAll 14333 -RestartService -Confirm:$false

Write-PSFMessage -Level Host -Message "Configuration for login lockout tests"
# A SQL login can only be locked out when the host running the instance has an account lockout
# threshold, and SQL Server reads that from the local policy of the host. Set-DbaLogin.Tests.ps1
# fails five logons on purpose, so the threshold has to be 5 or lower.
#
# This used to be "net accounts /lockoutthreshold:5" on SQL03 and SQL04, which does not survive:
# the Default Domain Policy sets LockoutBadCount = 0, and security policy is re-applied to the
# local account database of every member server at boot and every 16 hours. On 2026-08-08 a reboot
# put the threshold back to Never and the unlock test failed in the lab.
#
# So the threshold is defined as policy instead. Account policy in a GPO linked to an OU applies to
# the local account database of the computers in that OU and leaves domain accounts alone, which is
# exactly the scope we want - a domain-wide threshold could lock out ORDIX\Admin or the gMSA.
$lockoutGpoName = "SQL Lab - Account Lockout"
$lockoutOu      = "OU=SqlComputer,DC=ordix,DC=local"

$null = Invoke-Command -ComputerName DC -ArgumentList $lockoutGpoName, $lockoutOu -ScriptBlock {
    param($GpoName, $TargetOu)

    $ErrorActionPreference = "Stop"
    Import-Module GroupPolicy
    Import-Module ActiveDirectory

    $gpo = Get-GPO -Name $GpoName -ErrorAction SilentlyContinue
    if (-not $gpo) {
        $gpo = New-GPO -Name $GpoName -Comment "Local account lockout threshold for the SQL Server test lab, needed by Set-DbaLogin.Tests.ps1."
    }

    # The GroupPolicy module has no cmdlet for account policy, it lives in GptTmpl.inf in SYSVOL.
    # LockoutDuration must not be lower than ResetLockoutCount or the client rejects the template.
    $guid       = "{$($gpo.Id)}"
    $policyRoot = "\\ordix.local\SYSVOL\ordix.local\Policies\$guid"
    $secEditDir = Join-Path -Path $policyRoot -ChildPath "Machine\Microsoft\Windows NT\SecEdit"
    $null = New-Item -ItemType Directory -Path $secEditDir -Force

    $gptTmpl = @"
[Unicode]
Unicode=yes
[System Access]
LockoutBadCount = 5
ResetLockoutCount = 10
LockoutDuration = 10
[Version]
signature="`$CHICAGO`$"
Revision=1
"@
    Set-Content -Path (Join-Path -Path $secEditDir -ChildPath "GptTmpl.inf") -Value $gptTmpl -Encoding Unicode

    # Without the Security client side extension the clients never read GptTmpl.inf, and without a
    # higher version number they do not notice that it changed.
    $gpoDn       = "CN=$guid,CN=Policies,CN=System,DC=ordix,DC=local"
    $adGpo       = Get-ADObject -Identity $gpoDn -Properties versionNumber, gPCMachineExtensionNames
    $version     = [int]$adGpo.versionNumber + 1
    $securityCse = "[{827D319E-6EAC-11D2-A4EA-00C04F79F83A}{803E14A0-B4FB-11D0-A0D0-00A0C90F574B}]"

    $splatSetGpo = @{
        Identity = $gpoDn
        Replace  = @{
            versionNumber            = $version
            gPCMachineExtensionNames = $securityCse
        }
    }
    Set-ADObject @splatSetGpo
    Set-Content -Path (Join-Path -Path $policyRoot -ChildPath "GPT.INI") -Value "[General]`r`nVersion=$version" -Encoding ASCII

    $existingLink = (Get-GPInheritance -Target $TargetOu).GpoLinks | Where-Object DisplayName -eq $GpoName
    if (-not $existingLink) {
        $null = New-GPLink -Name $GpoName -Target $TargetOu -LinkEnabled Yes
    }
}

# The policy only reaches the hosts on the next refresh, so pull it now and check it arrived.
$lockoutComputers = @("SQL03", "SQL04")
$lockoutState = Invoke-Command -ComputerName $lockoutComputers -ScriptBlock {
    $null = gpupdate /target:computer /force
    [PSCustomObject]@{
        Computer  = $env:COMPUTERNAME
        Threshold = (net accounts | Select-String -Pattern "Lockout threshold").ToString().Split(":")[1].Trim()
    }
}
foreach ($state in $lockoutState) {
    if ($state.Threshold -eq "5") {
        Write-PSFMessage -Level Host -Message "Lockout threshold on $($state.Computer) is $($state.Threshold)"
    } else {
        Write-PSFMessage -Level Warning -Message "Lockout threshold on $($state.Computer) is $($state.Threshold), expected 5"
    }
}

Write-PSFMessage -Level Host -Message 'Finished'
