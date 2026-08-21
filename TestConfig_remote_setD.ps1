# Alternative set of test instances: "same version copy and an availability group below 2025".
#
#     .\run_tests.ps1 -ConfigFilename TestConfig_remote_setD.ps1
#
# What this set buys over TestConfig_remote_instances.ps1:
#   - The copy pair runs between two instances of the same version (2022 -> 2022) for the first
#     time, so a migration that needs no version upgrade is covered.
#   - InstanceHadr moves off 2025, so the availability group commands are exercised on 2022.
#   - InstanceRestart moves to 2019, so the service, port and certificate commands are exercised
#     on the oldest version in the lab.
#   - InstanceMulti1 becomes an FCI without putting the whole suite on one.
#
# THIS SET NEEDS LAB PREPARATION. Run this once before using it, or TestEnvironment.Tests.ps1
# fails after every single test file:
#
#     $null = Enable-DbaAgHadr -SqlInstance "SQL04\SQL2022" -Force
#     $null = New-DbaDbCertificate -SqlInstance "SQL04\SQL2022" -Name dbatoolsci_AGCert -Subject "AG Certificate"
#     $null = Set-DbaNetworkConfiguration -SqlInstance "SQL04\SQL2019" -StaticPortForIPAll 14333 -RestartService -Confirm:$false
#
# The expectations below already describe the lab as it looks after that preparation. They are
# spelled out in full rather than appended to, so this file always says what it expects.
#
# To go back to the original lab afterwards:
#
#     $null = Disable-DbaAgHadr -SqlInstance "SQL04\SQL2022" -Force
#     $null = Remove-DbaDbCertificate -SqlInstance "SQL04\SQL2022" -Database master -Certificate dbatoolsci_AGCert
#     $null = Set-DbaNetworkConfiguration -SqlInstance "SQL04\SQL2019" -DynamicPortForIPAll -RestartService -Confirm:$false
#
# The SQL Server source paths, the temp folder and the appveyor lab repository come from the main
# configuration, which is dot-sourced first.

. "$PSScriptRoot\TestConfig_remote_instances.ps1"

$config["InstanceSingle"] = "SQL03\SQL2022"
$config["InstanceMulti1"] = "FCI01"
$config["InstanceMulti2"] = "SQL04\SQL2025"
$config["InstanceCopy1"] = "SQL03\SQL2022"   # Source of every copy, so never an FCI and never newer than InstanceCopy2.
$config["InstanceCopy2"] = "SQL04\SQL2022"   # Destination, same version as the source in this set.
$config["InstanceHadr"] = "SQL04\SQL2022"    # Needs the Enable-DbaAgHadr and the certificate from the preparation above.
$config["InstanceRestart"] = "SQL04\SQL2019" # Needs the static port from the preparation above.

# Expectations used by TestEnvironment.Tests.ps1 to verify that the lab is still in its initial state.
# These have to match what 06_configure_instances.ps1 sets up plus the preparation documented above.
$config["ExpectedTcpPort"] = @{
    "SQL03\SQL2022" = 14333
    "SQL04\SQL2019" = 14333
}
$config["HadrInstances"] = @(
    "SQL03\SQL2025"
    "SQL04\SQL2025"
    "SQL04\SQL2022"
)
$config["AgCertificateInstances"] = @(
    "SQL03\SQL2025"
    "SQL04\SQL2025"
    "SQL04\SQL2022"
)
