[CmdletBinding()]
param (
    # The enterprise root CA that the AutomatedLab role CaRoot installs on the domain controller.
    [string]$CaComputerName = "DC",
    [string]$CaName = "LabRootCA1",
    # A copy of WebServer that holds every request as pending until a CA manager approves it. The certificate request
    # tests of New-DbaComputerCertificate use it; TestConfig_remote_instances.ps1 names it as ApprovalTemplate.
    [string]$ApprovalTemplateName = "WebServerPendingApproval",
    [string]$ApprovalTemplateDisplayName = "Web Server Pending Approval"
)

# The settings of the lab CA that the AutomatedLab role CaRoot does not make. In the first lab they were made by hand
# (the flag on 2026-08-31, the template on 2026-09-30) and were lost with the domain controller. The script can run
# again: whatever is there already is left alone.

$ErrorActionPreference = "Stop"

Import-Module -Name PSFramework

Write-PSFMessage -Level Host -Message "Configuring the certificate authority $CaName on $CaComputerName"

$caState = Invoke-Command -ComputerName $CaComputerName -ArgumentList $CaName, $ApprovalTemplateName, $ApprovalTemplateDisplayName -ScriptBlock {
    param($CaName, $TemplateName, $DisplayName)

    $ErrorActionPreference = "Stop"
    Import-Module -Name ActiveDirectory

    $restartCertSvc = $false

    # EDITF_ATTRIBUTEENDDATE lets a request carry the attributes ValidityPeriod and ValidityPeriodUnits, which is how the
    # lab gets trusted certificates that expire within minutes. certutil lists the flags that are set by their names.
    $editFlags = certutil -getreg policy\EditFlags
    if ($LASTEXITCODE -ne 0) {
        throw "certutil -getreg policy\EditFlags failed: $editFlags"
    }
    if ($editFlags -match "EDITF_ATTRIBUTEENDDATE") {
        $flagState = "already set"
    } else {
        $setResult = certutil -setreg policy\EditFlags +EDITF_ATTRIBUTEENDDATE
        if ($LASTEXITCODE -ne 0) {
            throw "certutil -setreg policy\EditFlags +EDITF_ATTRIBUTEENDDATE failed: $setResult"
        }
        $flagState = "set"
        $restartCertSvc = $true
    }

    $configurationDn = (Get-ADRootDSE).configurationNamingContext
    $pkiDn = "CN=Public Key Services,CN=Services,$configurationDn"
    $templateContainerDn = "CN=Certificate Templates,$pkiDn"
    $oidContainerDn = "CN=OID,$pkiDn"
    $templateDn = "CN=$TemplateName,$templateContainerDn"

    if (Get-ADObject -SearchBase $templateContainerDn -SearchScope OneLevel -Filter "Name -eq '$TemplateName'") {
        $templateState = "already there"
    } else {
        $source = Get-ADObject -Identity "CN=WebServer,$templateContainerDn" -Properties *

        # A template of schema version 2 needs an OID of its own: the OID of the forest plus two random numbers, with an
        # object in the OID container, the way the Certificate Templates console creates it.
        $random = New-Object -TypeName System.Random
        $forestOid = (Get-ADObject -Identity $oidContainerDn -Properties "msPKI-Cert-Template-OID")."msPKI-Cert-Template-OID"
        $templateOid = "$forestOid.$($random.Next(10000000, 100000000)).$($random.Next(10000000, 100000000))"
        $oidObjectName = "$($random.Next(10000000, 100000000)).$([guid]::NewGuid().ToString("N").ToUpper())"
        $oidAttributes = @{
            displayName               = $DisplayName
            flags                     = 1
            "msPKI-Cert-Template-OID" = $templateOid
        }
        $null = New-ADObject -Name $oidObjectName -Type "msPKI-Enterprise-Oid" -Path $oidContainerDn -OtherAttributes $oidAttributes

        # Everything else is copied from WebServer. What differs is what the Certificate Templates console wrote for the
        # copy of 2026-09-30: schema version 2 with an application policy, revision 100.2, the flag "modified" (0x20000)
        # instead of "default" (0x10000), and CT_FLAG_PEND_ALL_REQUESTS (2) in the enrollment flags.
        $templateAttributes = @{
            displayName                            = $DisplayName
            flags                                  = ($source.flags -band (-bnot 0x10000)) -bor 0x20000
            revision                               = 100
            showInAdvancedViewOnly                 = $true
            "msPKI-Template-Schema-Version"        = 2
            "msPKI-Template-Minor-Revision"        = 2
            "msPKI-Enrollment-Flag"                = $source."msPKI-Enrollment-Flag" -bor 2
            "msPKI-Cert-Template-OID"              = $templateOid
            "msPKI-Certificate-Application-Policy" = [string[]]$source.pKIExtendedKeyUsage
            "msPKI-Certificate-Name-Flag"          = $source."msPKI-Certificate-Name-Flag"
            "msPKI-Minimal-Key-Size"               = $source."msPKI-Minimal-Key-Size"
            "msPKI-Private-Key-Flag"               = $source."msPKI-Private-Key-Flag"
            "msPKI-RA-Signature"                   = $source."msPKI-RA-Signature"
            pKICriticalExtensions                  = [string[]]$source.pKICriticalExtensions
            pKIDefaultCSPs                         = [string[]]$source.pKIDefaultCSPs
            pKIDefaultKeySpec                      = $source.pKIDefaultKeySpec
            pKIExpirationPeriod                    = [byte[]]$source.pKIExpirationPeriod
            pKIExtendedKeyUsage                    = [string[]]$source.pKIExtendedKeyUsage
            pKIKeyUsage                            = [byte[]]$source.pKIKeyUsage
            pKIMaxIssuingDepth                     = $source.pKIMaxIssuingDepth
            pKIOverlapPeriod                       = [byte[]]$source.pKIOverlapPeriod
        }
        $null = New-ADObject -Name $TemplateName -Type pKICertificateTemplate -Path $templateContainerDn -OtherAttributes $templateAttributes

        # The same permissions as WebServer: Authenticated Users may read, Domain Admins and Enterprise Admins may enroll.
        $sourceAcl = Get-Acl -Path "AD:\CN=WebServer,$templateContainerDn"
        $templateAcl = Get-Acl -Path "AD:\$templateDn"
        $templateAcl.SetSecurityDescriptorSddlForm($sourceAcl.GetSecurityDescriptorSddlForm("Access"), "Access")
        Set-Acl -Path "AD:\$templateDn" -AclObject $templateAcl
        $templateState = "created with OID $templateOid"
    }

    # A template is published on a CA by adding its name to the certificateTemplates of the CA object. The CA picks up
    # the change at the latest when it starts again.
    $enrollmentServiceDn = "CN=$CaName,CN=Enrollment Services,$pkiDn"
    $publishedTemplates = (Get-ADObject -Identity $enrollmentServiceDn -Properties certificateTemplates).certificateTemplates
    if ($publishedTemplates -contains $TemplateName) {
        $publishState = "already published"
    } else {
        Set-ADObject -Identity $enrollmentServiceDn -Add @{ certificateTemplates = $TemplateName }
        $publishState = "published"
        $restartCertSvc = $true
    }

    # The policy module reads EditFlags only when the service starts.
    if ($restartCertSvc) {
        Restart-Service -Name CertSvc
    }

    [PSCustomObject]@{
        EditFlag         = $flagState
        Template         = $templateState
        Published        = $publishState
        CertSvcRestarted = $restartCertSvc
    }
}

Write-PSFMessage -Level Host -Message "EDITF_ATTRIBUTEENDDATE: $($caState.EditFlag)"
Write-PSFMessage -Level Host -Message "Template $($ApprovalTemplateName): $($caState.Template)"
Write-PSFMessage -Level Host -Message "Template $ApprovalTemplateName on $($CaName): $($caState.Published)"
Write-PSFMessage -Level Host -Message "CertSvc restarted: $($caState.CertSvcRestarted)"

Write-PSFMessage -Level Host -Message "Finished"
