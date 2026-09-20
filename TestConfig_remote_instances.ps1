# Lab description and the default instance set ("set03") of the multi-machine domain lab.
#
# This file has two parts. The first part describes the LAB - source media, shares, clusters, the Azure SQL
# Database and the expectations that TestEnvironment.Tests.ps1 asserts - and is shared by every set: the other
# TestConfig_remote_set*.ps1 files dot-source this file and override only the roles and the temp folder. The
# second part is the default set of roles, which TestConfig_remote_set03.ps1 uses unchanged.
#
# THE SETS (since 2026-09-19). Every set lives on one host, so that two sets can run side by side:
#
#   set03   SQL03:            Single SQL03\SQL2019, Multi1/Copy2/Hadr SQL03\SQL2025, Multi2/Copy1/Restart SQL03\SQL2022
#   set04   SQL04:            Single SQL04\SQL2025, Multi1/Copy2/Hadr SQL04\SQL2022, Multi2/Copy1/Restart SQL04\SQL2019
#   setCS   SQL05:            Single SQL05\SQL2019, Multi1/Copy2/Hadr SQL05\SQL2025, Multi2/Copy1/Restart SQL05\SQL2022
#   setFCI  CLUSTER01, SQL03: Single FCI01, Multi2 FCI02\SQL2022, Copy2 FCI01,
#                             Multi1/Hadr SQL03\SQL2025, Copy1/Restart SQL03\SQL2022
#
# RULES FOR RUNNING TWO SETS SIDE BY SIDE (Start-TestRun.ps1 checks them before it starts anything):
#   1. The hosts have to be disjoint, not only the instances: 41 test files act on the host of an instance through
#      -ComputerName. So set03 and setFCI never run together.
#   2. Only one of the two may have its Hadr instance on a node of CLUSTER02 (SQL03 and SQL04): the Hadr tests create
#      availability groups with fixed names, an availability group is a cluster group, and two runs collide inside
#      the cluster. SQL05 is not clustered, so setCS pairs with every other set. set03 or setFCI beside set04 works
#      only when one of them runs with -ExcludeScenario HADR and its Hadr lane runs afterwards (23 files, 15 minutes).
#   3. ADMIN01 has 12 GB and a full run peaks at about 3.5 GB, so two runs fit and three do not.
# Two waves cover the whole lab: set03 beside setCS, then setFCI beside set04 (one of them without HADR).
#
# RULES EVERY SET OBEYS:
#   - InstanceSingle is never InstanceHadr and nothing restarts it. On 2026-08-31 Enable-DbaAgHadr restarted the
#     Single instance and the connection pool of the run never recovered. A Single instance that is Hadr enabled and
#     carries the AG certificate is fine: setB ran that way, and Enable-DbaDbEncryption takes any master certificate.
#   - InstanceCopy1 is never an FCI (Copy-DbaDbMail) and never newer than InstanceCopy2 (Test-DbaMigrationConstraint).
#   - InstanceRestart is standalone and has a static port, so that Set-DbaTcpPort.Tests.ps1 can put it back.
#   - Every set has its own temp folder below \\fs\Temp. Two runs started together stay in lockstep for the whole
#     day, so they process the same test file at the same moment, and 95 files write fixed names into the temp
#     folder. run_tests.ps1 and Initialize-LabSession.ps1 create the folder when it is missing.

$config['InstanceConfiguration'] = [ordered]@{
    Version          = 2025
}
if (Test-Path -Path 'C:\SQLServerFull') {
    # We are on an Azure virtual maschine with preinstalled SQL Server
    $config['InstanceConfiguration'].SourcePath = 'C:\SQLServerFull'
} elseif (Test-Path -Path '\\dc\Software\SQLServer\ISO\SQLServer2025') {
    # We are on personal setup of Andreas Jordan
    $config['InstanceConfiguration'].SourcePath = '\\dc\Software\SQLServer\ISO\SQLServer2025'
    $config['InstanceConfiguration'].UpdateSourcePath = '\\dc\Software\SQLServer\CU'
} elseif (Test-Path -Path '\\dc\FileServer\SQLServer2025') {
    # We are on personal setup of Andreas Jordan
    $config['InstanceConfiguration'].SourcePath = '\\dc\FileServer\SQLServer2025'
    $config['InstanceConfiguration'].UpdateSourcePath = '\\dc\FileServer\SQLServerCU'
}

# Path to your local AppVeyor lab repository (if applicable)
$config['appveyorlabrepo'] = "\\fs\appveyor-lab"

# The Windows failover clusters of the lab, used by the Get-DbaWsfc* tests.
# Leave these empty in a configuration whose lab has no cluster - the tests skip themselves then.
$config['ClusterStorage'] = "CLUSTER01"   # shared storage: disk witness, one CSV, one available disk, two FCIs
$config['ClusterWitness'] = "CLUSTER02"   # no shared storage: file share witness, availability groups
$config['ClusterWitnessPath'] = "\\fs\ClusterWitness02"
# The nodes of the availability group cluster. An availability group created on an instance on one of these hosts
# becomes a group of that cluster, which is what rule 2 above is about. Start-TestRun.ps1 reads this.
$config['ClusterWitnessNodes'] = @(
    "SQL03"
    "SQL04"
)

# Expectations used by TestEnvironment.Tests.ps1 to verify that the lab is still in its initial state.
# These have to match what 06_configure_instances.ps1 sets up.
$config['ExpectedTcpPort'] = @{
    "SQL03\SQL2022" = 14333
    "SQL04\SQL2019" = 14334
    "SQL05\SQL2022" = 14335
}
$config['HadrInstances'] = @(
    "SQL03\SQL2025"
    "SQL04\SQL2025"
    "SQL04\SQL2022"
    "SQL05\SQL2025"
)
$config['AgCertificateInstances'] = @(
    "SQL03\SQL2025"
    "SQL04\SQL2022"
    "SQL05\SQL2025"
)

# The Azure SQL Database that the Azure code paths of Connect-DbaInstance need. Azure SQL Database is
# the only engine that refuses to switch the database of a connection it has already opened, so it is
# the only place that branch can be covered. Leave these empty in a configuration that has no Azure
# SQL Database - the tests skip themselves then.
# The password is the same throwaway one that setup_azure.ps1 uses for the whole lab.
$config['AzureSqlDbServer'] = "sqllab1198641298.database.windows.net"
$config['AzureSqlDbName'] = "sqllabdb"
$config['AzureSqlDbCred'] = [PSCredential]::new('initialAdmin', (ConvertTo-SecureString -String 'initialP#ssw0rd' -AsPlainText -Force))


# The default set: "set03", everything on SQL03.
#
# The baseline that resembles the CI lanes most: InstanceSingle on 2019, the multi pair 2025 and 2022, a same-host
# copy 2022 -> 2025. Until 2026-09-19 InstanceCopy2 and InstanceHadr were SQL04\SQL2025; they moved to SQL03 so that
# this set touches one host only and can run beside set04.

$config['InstanceSingle'] = "SQL03\SQL2019"
$config['InstanceMulti1'] = "SQL03\SQL2025"
$config['InstanceMulti2'] = "SQL03\SQL2022"
$config['InstanceCopy1'] = "SQL03\SQL2022"   # Source of every copy, so never an FCI and never newer than InstanceCopy2.
$config['InstanceCopy2'] = "SQL03\SQL2025"   # Destination, so its version has to be at least the one of InstanceCopy1.
$config['InstanceHadr'] = "SQL03\SQL2025"    # Needs Hadr enabled and the AG certificate.
$config['InstanceRestart'] = "SQL03\SQL2022" # Stays standalone and keeps the static port 14333.

$config['Temp'] = "\\fs\Temp\set03"
