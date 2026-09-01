# Alternative set of test instances: "everything case sensitive".
#
#     .\run_tests.ps1 -ConfigFilename TestConfig_remote_setCS.ps1
#
# SQL05 was installed with SQL_Latin1_General_CP1_CS_AS so that case sensitive behaviour can be tested
# at all - see the case sensitivity finding on dbatools PR #10579. The instances on SQL03 and SQL04 use
# the setup default, SQL_Latin1_General_CP1_CI_AS, where two databases whose names differ only in case
# cannot exist and the tests that need them skip themselves.
#
# Until 2026-08-31 only InstanceSingle moved to SQL05 (as SQL05\SQL2025). Since then every role lives on
# SQL05, so the MULTI, COPY, HADR and RESTART lanes run against case sensitive instances as well. The
# roles overlap exactly like in the main configuration: InstanceSingle is the instance nothing else
# touches, Hadr shares the 2025 instance with Multi1 and Copy2, Restart shares the 2022 instance with
# Multi2 and Copy1. The copy pair is 2022 -> 2025 on one host.
#
# RULE, learned the hard way on 2026-08-31: InstanceSingle must not be InstanceHadr and nothing may
# restart it. The first all-SQL05 run had Single = Hadr = SQL05\SQL2025: Enable-DbaAgHadr restarted the
# Single instance, Enable-DbaDbEncryption found two certificates in master (the AG certificate), and
# from then on every connection of the run process failed with a connection pool timeout - 130 files
# of noise. Single is therefore the 2019 instance, which no test restarts and which carries no AG
# certificate; the 2025 CS Single was covered by the run of 2026-08-30.
#
# THIS SET NEEDS LAB PREPARATION, done on 2026-08-31 and part of 06_configure_instances.ps1 since
# then (SQL05\SQL2025 in -HadrInstances, SQL05\SQL2022 in -StaticPorts). On a rebuilt lab either run
# 06_configure_instances.ps1 or do it by hand:
#
#     $null = Enable-DbaAgHadr -SqlInstance "SQL05\SQL2025" -Force
#     $null = New-DbaDbCertificate -SqlInstance "SQL05\SQL2025" -Name dbatoolsci_AGCert -Subject "AG Certificate"
#     $null = Set-DbaNetworkConfiguration -SqlInstance "SQL05\SQL2022" -StaticPortForIPAll 14335 -RestartService -Confirm:$false
#
# The SQL Server source paths, the temp folder, the appveyor lab repository, the cluster and Azure
# settings and the lab expectations come from the main configuration, which is dot-sourced first.
# The expectations there already contain the SQL05 entries, so nothing is overridden below.

. "$PSScriptRoot\TestConfig_remote_instances.ps1"

$config["InstanceSingle"] = "SQL05\SQL2019"
$config["InstanceMulti1"] = "SQL05\SQL2025"
$config["InstanceMulti2"] = "SQL05\SQL2022"
$config["InstanceCopy1"] = "SQL05\SQL2022"   # Source of every copy, so never an FCI and never newer than InstanceCopy2.
$config["InstanceCopy2"] = "SQL05\SQL2025"   # Destination, so its version has to be at least the one of InstanceCopy1.
$config["InstanceHadr"] = "SQL05\SQL2025"    # Needs Hadr enabled and the AG certificate, see above.
$config["InstanceRestart"] = "SQL05\SQL2022" # Stays standalone and keeps the static port 14335.
