# Alternative set of test instances: "2025 bulk, cold hosts".
#
#     .\run_tests.ps1 -ConfigFilename TestConfig_remote_setB.ps1
#
# What this set buys over TestConfig_remote_instances.ps1:
#   - InstanceSingle moves from 2019 to 2025. That is 403 of the 744 test files, so more than
#     half of the suite runs against a version it has never been run against in this lab.
#   - The multi pair moves to SQL04\SQL2019 and SQL04\SQL2022, two instances no role used before.
#   - The copy pair becomes a two major version jump (2019 -> 2022) and runs on a single host
#     for the first time, so it no longer hides a dependency on crossing machines.
#   - InstanceHadr moves to the other availability group replica.
#
# Needs no lab preparation: every instance is already configured by 06_configure_instances.ps1,
# and the lab expectations below are unchanged, so TestEnvironment.Tests.ps1 still passes.
#
# The SQL Server source paths, the temp folder, the appveyor lab repository and the lab
# expectations come from the main configuration, which is dot-sourced first. Only the roles differ.

. "$PSScriptRoot\TestConfig_remote_instances.ps1"

$config["InstanceSingle"] = "SQL04\SQL2025"
$config["InstanceMulti1"] = "SQL04\SQL2019"
$config["InstanceMulti2"] = "SQL04\SQL2022"
$config["InstanceCopy1"] = "SQL03\SQL2019"   # Source of every copy, so never an FCI and never newer than InstanceCopy2.
$config["InstanceCopy2"] = "SQL03\SQL2022"   # Destination, so its version has to be at least the one of InstanceCopy1.
$config["InstanceHadr"] = "SQL03\SQL2025"    # Needs Hadr enabled and the AG certificate.
$config["InstanceRestart"] = "SQL03\SQL2022" # Stays standalone and keeps the static port 14333.
