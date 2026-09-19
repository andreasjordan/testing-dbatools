# Instance set "set04": everything on SQL04, "2025 bulk".
#
#     .\run_tests.ps1 -ConfigFilename TestConfig_remote_set04.ps1
#
# What this set buys over set03:
#   - InstanceSingle is 2025. That is 411 of the 749 test files, so more than half of the suite runs against the
#     newest version in the lab.
#   - InstanceHadr is 2022, so the availability group commands run on something other than 2025.
#   - InstanceRestart is 2019, so the service, port, certificate and network configuration commands run on the
#     oldest version in the lab.
#   - The copy pair jumps two major versions (2019 -> 2022) on one host.
# It replaces the former setB (Single on SQL04\SQL2025) and setD (Hadr on 2022, Restart on 2019), which could not
# run beside another set because they spread over SQL03 and SQL04.
#
# THIS SET NEEDS LAB PREPARATION, done on 2026-09-19 and part of 06_configure_instances.ps1 since then
# (SQL04\SQL2022 in -HadrInstances, SQL04\SQL2019 in -StaticPorts). On a rebuilt lab either run
# 06_configure_instances.ps1 or do it by hand:
#
#     $null = Enable-DbaAgHadr -SqlInstance "SQL04\SQL2022" -Force
#     $null = Copy-DbaDbCertificate -Source "SQL03\SQL2025" -Destination "SQL04\SQL2022" -Certificate dbatoolsci_AGCert -SharedPath \\fs\Temp -Confirm:$false
#     $null = Set-DbaNetworkConfiguration -SqlInstance "SQL04\SQL2019" -StaticPortForIPAll 14334 -RestartService -Confirm:$false
#
# SQL04\SQL2025 stays Hadr enabled with the AG certificate although it is InstanceSingle here: nothing in this set
# restarts it (the Hadr role is on SQL04\SQL2022), and a master certificate does not disturb the Single tests.
#
# Runs beside setCS without restrictions. Beside set03 or setFCI only with -ExcludeScenario HADR on one of the two,
# because all three have their Hadr instance in CLUSTER02 - see the rules in TestConfig_remote_instances.ps1.
#
# The SQL Server source paths, the appveyor lab repository, the cluster and Azure settings and the lab expectations
# come from the main configuration, which is dot-sourced first. Only the roles and the temp folder differ.

. "$PSScriptRoot\TestConfig_remote_instances.ps1"

$config["InstanceSingle"] = "SQL04\SQL2025"
$config["InstanceMulti1"] = "SQL04\SQL2022"
$config["InstanceMulti2"] = "SQL04\SQL2019"
$config["InstanceCopy1"] = "SQL04\SQL2019"   # Source of every copy, so never an FCI and never newer than InstanceCopy2.
$config["InstanceCopy2"] = "SQL04\SQL2022"   # Destination, so its version has to be at least the one of InstanceCopy1.
$config["InstanceHadr"] = "SQL04\SQL2022"    # Needs Hadr enabled and the AG certificate, see above.
$config["InstanceRestart"] = "SQL04\SQL2019" # Stays standalone and keeps the static port 14334.

$config["Temp"] = "\\fs\Temp\set04"
