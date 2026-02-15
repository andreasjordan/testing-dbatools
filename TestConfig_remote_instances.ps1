# Modify the $config hashtable to include configuration for the local instances.

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

$config['InstanceSingle'] = "SQL03\SQL2019"
$config['InstanceMulti1'] = "SQL03\SQL2025"
$config['InstanceMulti2'] = "SQL03\SQL2022"
$config['InstanceCopy1'] = "SQL03\SQL2022"  # No FCI becaue of Copy-DbaDbMail
$config['InstanceCopy2'] = "SQL04\SQL2025"
$config['InstanceHadr'] = "SQL04\SQL2025"
$config['InstanceRestart'] = "SQL03\SQL2022"

<#
$config['InstanceSingle'] = "FCI01"
$config['InstanceMulti1'] = "SQL03\SQL2025"
$config['InstanceMulti2'] = "FCI02\SQL2022"
$config['InstanceCopy1'] = "SQL03\SQL2022"
$config['InstanceCopy2'] = "SQL04\SQL2025"
$config['InstanceHadr'] = "SQL03\SQL2025"
$config['InstanceRestart'] = "SQL03\SQL2022"
#>

# Path to your local AppVeyor lab repository (if applicable)
$config['appveyorlabrepo'] = "\\fs\appveyor-lab"

$config['Temp'] = "\\fs\Temp"
