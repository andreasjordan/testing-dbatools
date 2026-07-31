# Testing the PowerShell module dbatools

This repository contains script to setup labs and to run tests for the PowerShell module [dbatools](https://github.com/dataplat/dbatools).

This is not a replacement for the CI tests but an addition. Since July 2026 that CI runs on self-hosted Azure VMSS runners instead of AppVeyor, but the matrix and the `tests\appveyor.*.ps1` scripts were ported over, so the scenario names (SINGLE, MULTI, COPY, HADR, RESTART) still match.

Details about the used cloud vm will follow.

These tests are currently excluded:
* Invoke-DbaDbMirroring.Tests.ps1 ("the partner server name must be distinct")
* Watch-DbaDbLogin.Tests.ps1 (Command does not work)
* Get-DbaWindowsLog.Tests.ps1 (Sometimes failes and gets no data, sometimes takes forever)
* Get-DbaPageFileSetting.Tests.ps1 (Classes Win32_PageFile and Win32_PageFileSetting do not return any information)
* New-DbaSsisCatalog.Tests.ps1 (needs an SSIS server)
* Get-DbaClientProtocol.Tests.ps1 (No ComputerManagement Namespace on CLIENT.dom.local)

These tests are currently excluded for PowerShell 7:
* Add-DbaComputerCertificate.Tests.ps1 (does not work on pwsh because of X509Certificate2)
* Backup-DbaComputerCertificate.Tests.ps1 (does not work on pwsh because of X509Certificate2)
* Enable-DbaFilestream.Tests.ps1 (does not work on pwsh because of WMI-Object not haveing method EnableFilestream)
* Invoke-DbaQuery.Tests.ps1 (does not work on pwsh because "DataReader.GetFieldType(0) returned null." with geometry)


Goals for the future:
* All tests should use a share to write output files like backups or scripts.
* That way we can move the instances away from the test engine. Like in production: You don't run dbatools on the server. Every test should work against a remote instance.
* Using two servers in an active directory domain with a failover cluster (without shared storage) to test Availability Groups, Mirroring, database migrations and other related stuff.
* Test different versions of SQL Server. Currently I use 2022.
* All BeforeAll and AfterAll must use -EnableException to make sure that the test setup is correct.
  Run `Invoke-Pester .\TestTestfiles.Tests.ps1` without excluding the tag `Goal` to see how far this still is.


More documentation will follow...
