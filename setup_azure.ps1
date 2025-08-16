# function prompt { "PS $(if ($NestedPromptLevel -ge 1) { '>>' })> " }

# Takes about 5 minutes to setup the maschine

$ErrorActionPreference = 'Stop'

# Name of resource group and location
$resourceGroupName = 'testing-dbatools'
$location          = 'North Europe'

# Name and password of the initial account
$initUser     = 'initialAdmin'     # Will be used when creating the virtual maschines
$initPassword = 'initialP#ssw0rd'  # Will be used when creating the virtual maschines and for the certificate
$initCredential = [PSCredential]::new($initUser, (ConvertTo-SecureString -String $initPassword -AsPlainText -Force))

# Getting the home IP address to setup firewall rules
$homeIP = (Invoke-WebRequest -Uri "http://ipinfo.io/json" -UseBasicParsing | ConvertFrom-Json).ip
if ($homeIP -notmatch '\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}') {
    Write-Warning -Message 'Failed to get IPv4 home IP. Stopping.'
    return
}

# Loading Azure modules
Import-Module -Name Az.Accounts, Az.Resources, Az.Network, Az.KeyVault, Az.Compute

# Logging in to Azure
$context = Get-AzContext
if (-not $context) {
    Write-Warning -Message "No Azure context found. Please log in to Azure. Stopping."
    return
}

# Cheching if the resource group already exists
if (Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue) {
    Write-Warning -Message "Resource group '$resourceGroupName' already exists. Stopping."
    return
}


# Creating the resource group
#############################

$null = New-AzResourceGroup -Name $resourceGroupName -Location $location


# Creating key vault and certificate
####################################

$keyVaultParam = @{
    VaultName                    = "KeyVault$(Get-Random -Minimum 1000000000 -Maximum 9999999999)"
    EnabledForDeployment         = $true
    EnabledForTemplateDeployment = $true
}
$certificatePolicyParams = @{
    SecretContentType = "application/x-pkcs12"
    SubjectName       = "CN=lab.local"
    IssuerName        = "Self"
    ValidityInMonths  = 12
    ReuseKeyOnRenewal = $true
}
$certificateName = "$($resourceGroupName.Replace('_',''))Certificate"
try {
    $null = New-AzRoleAssignment -SignInName $context.Account.Id -ResourceGroupName $resourceGroupName -RoleDefinitionName 'Key Vault Administrator'
    $null = New-AzKeyVault -ResourceGroupName $resourceGroupName -Location $location @keyVaultParam
    $certificatePolicy = New-AzKeyVaultCertificatePolicy @certificatePolicyParams
    $null = Add-AzKeyVaultCertificate -VaultName $keyVaultParam.VaultName -Name $certificateName -CertificatePolicy $certificatePolicy
    # Waiting for secret to be ready
    while (1) {
        try {
            $null = Get-AzKeyVaultSecret -VaultName $keyVaultParam.VaultName -Name $certificateName
            break
        } catch {
            Start-Sleep -Seconds 10
        }
    }
} catch {
    Write-Warning -Message "An error occurred while setting up the Azure keyvault: $_"
    return
}


# Creating network and firewall rules
#####################################

$virtualNetworkParam = @{
    Name          = "VirtualNetwork"
    AddressPrefix = "10.0.0.0/16"
}
$virtualNetworkSubnetConfigParam = @{
    Name          = "Default"
    AddressPrefix = "10.0.0.0/24"
}
$networkSecurityGroupParam = @{
    Name = "NetworkSecurityGroup"
}
$networkSecurityRules = @(
    @{
        Name                     = "AllowRdpFromHome"
        Protocol                 = "Tcp"
        Direction                = "Inbound"
        Priority                 = "1001"
        SourceAddressPrefix      = $homeIP
        SourcePortRange          = "*"
        DestinationAddressPrefix = "*"
        DestinationPortRange     = 3389
        Access                   = "Allow"
    }
    @{
        Name                     = "AllowWinRmFromHome"
        Protocol                 = "Tcp"
        Direction                = "Inbound"
        Priority                 = "1002"
        SourceAddressPrefix      = $homeIP
        SourcePortRange          = "*"
        DestinationAddressPrefix = "*"
        DestinationPortRange     = 5986
        Access                   = "Allow"
    }
)

try {
    $virtualNetworkSubnetConfig = New-AzVirtualNetworkSubnetConfig @virtualNetworkSubnetConfigParam
    $null = New-AzVirtualNetwork -ResourceGroupName $resourceGroupName -Location $location @virtualNetworkParam -Subnet $virtualNetworkSubnetConfig
    $securityRules = foreach ($networkSecurityRuleConfigParam in $networkSecurityRules) {
        New-AzNetworkSecurityRuleConfig @networkSecurityRuleConfigParam
    }
    $null = New-AzNetworkSecurityGroup -ResourceGroupName $resourceGroupName -Location $location @networkSecurityGroupParam -SecurityRules $securityRules
} catch {
    Write-Warning -Message "An error occurred while setting up the Azure network: $_"
    return
}


# Creating virtual machines
###########################

$computerName = 'SQL2022'
$vmSize = 'Standard_E4s_v6'

$keyVault = Get-AzKeyVault -ResourceGroupName $resourceGroupName
$certificateUrl = (Get-AzKeyVaultSecret -VaultName $keyVault.VaultName -Name $certificateName).Id
$subnet = (Get-AzVirtualNetwork -ResourceGroupName $resourceGroupName).Subnets[0]
$networkSecurityGroup = Get-AzNetworkSecurityGroup -ResourceGroupName $resourceGroupName

$publicIpAddressParam = @{
    Name             = "$($computerName)_PublicIP"
    AllocationMethod = "Static"
    WarningAction    = "SilentlyContinue"
}
$networkInterfaceParam = @{
    Name                   = "$($computerName)_Interface"
    SubnetId               = $subnet.Id
    NetworkSecurityGroupId = $networkSecurityGroup.Id
}
$vmConfigParam = @{
    VMName              = "$($computerName)_VM"
    VMSize              = $vmSize
}
$secretParam = @{
    SourceVaultId    = $keyVault.ResourceId
    CertificateStore = "My"
    CertificateUrl   = $certificateUrl
}
$operatingSystemParam = @{
    ComputerName        = $computerName
    Windows             = $true
    Credential          = $initCredential
    WinRMHttps          = $true
    WinRMCertificateUrl = $certificateUrl
    ProvisionVMAgent    = $true
}
$sourceImageParam = @{
    PublisherName = "MicrosoftSQLServer"  # Get-AzVMImagePublisher -Location $location | Where-Object PublisherName -like microsoft*
    Offer         = "sql2022-ws2022"      # Get-AzVMImageOffer -Location $location -Publisher $sourceImageParam.PublisherName
    Skus          = "sqldev-gen2"         # Get-AzVMImageSku -Location $location -Publisher $sourceImageParam.PublisherName -Offer $sourceImageParam.Offer | Select Skus
    Version       = "latest"              # Get-AzVMImage -Location $location -Publisher $sourceImageParam.PublisherName -Offer $sourceImageParam.Offer -Skus $sourceImageParam.Skus | Select Version
}
$osDiskParam = @{
    Name         = "$($computerName)_Disk1.vhd"
    CreateOption = "FromImage"
}
$bootDiagnosticParam = @{
    Disable = $true
}

try {
    $publicIpAddress = New-AzPublicIpAddress -ResourceGroupName $resourceGroupName -Location $location @publicIpAddressParam
    $networkInterface = New-AzNetworkInterface -ResourceGroupName $resourceGroupName -Location $location @networkInterfaceParam -PublicIpAddressId $publicIpAddress.Id
    $vmConfig = New-AzVMConfig @vmConfigParam
    $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $networkInterface.Id
    $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig @operatingSystemParam
    $vmConfig = Set-AzVMSourceImage -VM $vmConfig @sourceImageParam
    $vmConfig = Set-AzVMOSDisk -VM $vmConfig @osDiskParam
    $vmConfig = Set-AzVMBootDiagnostic -VM $vmConfig @bootDiagnosticParam
    $vmConfig = Add-AzVMSecret -VM $vmConfig @secretParam
    $vmConfig = Set-AzVmSecurityProfile -VM $vmConfig -SecurityType TrustedLaunch
    $vmConfig = Set-AzVmUefi -VM $vmConfig -EnableVtpm $true -EnableSecureBoot $true 
} catch {
    Write-Warning -Message "An error occurred while setting up the configuration for the Azure virtual maschine: $_"
    return
}

try {
    $result = New-AzVM -ResourceGroupName $resourceGroupName -Location $location -VM $vmConfig
    if (-not $result.IsSuccessStatusCode) {
        Write-Warning -Message "Failed to create the virtual machine. Status code: $($result.StatusCode), Reason: $($result.ReasonPhrase)"
        return
    }
} catch {
    Write-Warning -Message "An error occurred while setting up the Azure virtual maschine: $_"
    if ("$_" -match "An error occurred while sending the request") {
        Write-Warning -Message "But we just hope the best and continue, because most of the time the virtual maschine is successfully created."
    } else {
        return
    }
}


# Create some commands that are needed later
# The currently just use the "global" variables, but they could be made more flexible later

function New-MyAzurePSSession {
    $ipAddress = (Get-AzPublicIpAddress -ResourceGroupName $resourceGroupName -Name "$($computerName)_PublicIP").IpAddress

    $psSessionParam = @{
        ConnectionUri  = "https://$($ipAddress):5986"
        Credential     = $initCredential
        SessionOption  = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
        Authentication = "Negotiate"
    }

    while (1) {
        try {
            New-PSSession @psSessionParam
            break
        } catch {
            Start-Sleep -Seconds 10
        }
    }
}

function New-MyAzureRDPSession {
    $ipAddress = (Get-AzPublicIpAddress -ResourceGroupName $resourceGroupName -Name "$($computerName)_PublicIP").IpAddress

    $user = $initCredential.UserName
    $pass = $initCredential.GetNetworkCredential().Password
    $null = cmdkey /add:TERMSRV/$ipAddress /user:$user /pass:$pass
    mstsc /v:$ipAddress
    $target = [datetime]::Now.AddSeconds(15)
    while ([datetime]::Now -lt $target) {
        Start-Sleep -Milliseconds 100
        if ((Get-Process -Name mstsc -ErrorAction SilentlyContinue).MainWindowTitle -match "^$ipAddress - ") {
            break
        }
    }
    $null = cmdkey /delete:TERMSRV/$ipAddress
}



# Installing PowerShell modules, chocolatey and software
########################################################

$psSession = New-MyAzurePSSession

$null = Invoke-Command -Session $psSession -ScriptBlock {
    # Needed to avoid problems with WinRM when dbatools wants to restart the SQL Server services
    'y' | winrm quickconfig

    $null = Install-PackageProvider -Name Nuget -Force
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

    Install-Module -Name dbatools, PSFramework
    Install-Module -Name Pester -Force -SkipPublisherCheck -MaximumVersion 4.99
    Install-Module -Name Pester -Force -SkipPublisherCheck -MaximumVersion 5.99
    Install-Module -Name PSScriptAnalyzer -Force -SkipPublisherCheck -MaximumVersion 1.18.2

    Set-ExecutionPolicy -ExecutionPolicy Bypass -Force
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1')) *> $null

    choco install git vscode powershell-core notepadplusplus --confirm --limitoutput --no-progress
}

Invoke-Command -Session $psSession -ScriptBlock { Restart-Computer -Force }
Start-Sleep -Seconds 10


# Cloning repositories
######################

$psSession = New-MyAzurePSSession

$null = Invoke-Command -Session $psSession -ScriptBlock {
    $null = New-Item -Path C:\GitHub -ItemType Directory
    Push-Location -Path C:\GitHub
    git clone --quiet https://github.com/dataplat/dbatools.git
    git clone --quiet https://github.com/dataplat/appveyor-lab.git
    git clone --quiet https://github.com/andreasjordan/testing-dbatools.git
    Pop-Location
}

$psSession | Remove-PSSession


# Open RDP connection to the virtual machine
############################################

New-MyAzureRDPSession



# To remove the resource group (asks for confirmation for safety): 
# Remove-AzResourceGroup -Name $resourceGroupName

