# Instance set "setFCI": the failover cluster instances plus SQL03.
#
#     .\run_tests.ps1 -ConfigFilename TestConfig_remote_setFCI.ps1
#
# What this set buys over set03:
#   - InstanceSingle is the failover cluster instance FCI01, a clustered DEFAULT instance, so 411 of the 749
#     test files run against a clustered instance and against an instance without an instance name.
#   - The multi pair spans two hosts (SQL03\SQL2025 and FCI02\SQL2022), which is the only place the Kerberos
#     double hop of Test-DbaLinkedServerConnection is exercised - the standalone sets pair instances on one host.
#   - The copy pair goes from a standalone source across hosts onto clustered storage: InstanceCopy2 is FCI01,
#     whose files live on the clustered drive S:. New since 2026-09-19 (it was SQL04\SQL2025 before); if it
#     produces FCI-shaped noise, fall back to SQL03\SQL2025 and this set stays host-local all the same.
#
# This was "setC" until 2026-09-19. The SQL04 dependency (InstanceCopy2) is gone, so this set uses the cluster
# and SQL03 only and can run beside set04 or setCS. It shares SQL03 with set03, so those two never run together.
#
# Needs no lab preparation: both FCIs are configured by 06_configure_instances.ps1 and their default backup
# folder is reachable through the admin share of the cluster network name (\\FCI01\S$\... and \\FCI02\T$\...).
#
# About 30 of the InstanceSingle test files pass the instance as a -ComputerName - Get-DbaComputerSystem,
# Get-DbaOperatingSystem, Get-DbaPowerPlan, Get-DbaInstalledPatch, the performance counter tests and others.
# FCI01 is a cluster network name, not a machine; the full runs of 2026-08-26 and 2026-09-16 showed that they
# all pass on the active node anyway, so a failure there is worth a look rather than a shrug.
#
# InstanceCopy1 is deliberately not an FCI because of Copy-DbaDbMail, and InstanceRestart is deliberately
# standalone: those tests stop and start the service and change the service account, which on an FCI invites
# a failover.
#
# The SQL Server source paths, the appveyor lab repository, the cluster and Azure settings and the lab
# expectations come from the main configuration, which is dot-sourced first. Only the roles and the temp
# folder differ.

. "$PSScriptRoot\TestConfig_remote_instances.ps1"

$config["InstanceSingle"] = "FCI01"
$config["InstanceMulti1"] = "SQL03\SQL2025"
$config["InstanceMulti2"] = "FCI02\SQL2022"
$config["InstanceCopy1"] = "SQL03\SQL2022"   # Source of every copy, so never an FCI and never newer than InstanceCopy2.
$config["InstanceCopy2"] = "FCI01"           # Destination, so its version has to be at least the one of InstanceCopy1.
$config["InstanceHadr"] = "SQL03\SQL2025"    # Needs Hadr enabled and the AG certificate.
$config["InstanceRestart"] = "SQL03\SQL2022" # Stays standalone and keeps the static port 14333.

$config["Temp"] = "\\fs\Temp\setFCI"
