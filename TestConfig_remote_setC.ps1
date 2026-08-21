# Alternative set of test instances: "failover cluster".
#
#     .\run_tests.ps1 -ConfigFilename TestConfig_remote_setC.ps1
#
# What this set buys over TestConfig_remote_instances.ps1:
#   - InstanceSingle becomes the failover cluster instance FCI01, so 403 of the 744 test files
#     run against a clustered instance for the first time.
#   - The multi pair spans a standalone and a clustered instance.
#
# Needs no lab preparation: both FCIs are configured by 06_configure_instances.ps1, their default
# backup folder is reachable through the admin share of the cluster network name
# (\\FCI01\S$\... and \\FCI02\T$\...), and the lab expectations below are unchanged.
#
# Expect failures that are not regressions: 30 of the InstanceSingle test files pass the instance
# as a -ComputerName - Get-DbaComputerSystem, Get-DbaOperatingSystem, Get-DbaPowerPlan,
# Get-DbaInstalledPatch, the performance counter tests and others. FCI01 is a cluster network
# name, not a machine, so some of them will not behave. That is worth knowing rather than
# avoiding, but budget time to sort those failures from real ones.
#
# InstanceCopy1 is deliberately not an FCI because of Copy-DbaDbMail, and InstanceRestart is
# deliberately standalone: those tests stop and start the service and change the service account,
# which on an FCI invites a failover.
#
# The SQL Server source paths, the temp folder, the appveyor lab repository and the lab
# expectations come from the main configuration, which is dot-sourced first. Only the roles differ.

. "$PSScriptRoot\TestConfig_remote_instances.ps1"

$config["InstanceSingle"] = "FCI01"
$config["InstanceMulti1"] = "SQL03\SQL2025"
$config["InstanceMulti2"] = "FCI02\SQL2022"
$config["InstanceCopy1"] = "SQL03\SQL2022"   # Source of every copy, so never an FCI and never newer than InstanceCopy2.
$config["InstanceCopy2"] = "SQL04\SQL2025"   # Destination, so its version has to be at least the one of InstanceCopy1.
$config["InstanceHadr"] = "SQL03\SQL2025"    # Needs Hadr enabled and the AG certificate.
$config["InstanceRestart"] = "SQL03\SQL2022" # Stays standalone and keeps the static port 14333.
