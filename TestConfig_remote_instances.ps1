# Modify the $config hashtable to include configuration for the local instances.


# Configuration items for the local instances:

$config['host1'] = 'SQL01'
$config['host2'] = 'SQL02'
$config['host3'] = 'SQL03'

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

# Configuration items from constants.local.ps1.example:

# Define your local SQL Server instances
$config['instance1'] = "$($config['host1'])"                 # Replace with your first SQL Server instance
# Should be a default instance that listens on 1433 because of:
# Test-DbaConnection.Tests.ps1
$config['instance2'] = "$($config['host2'])\SQLInstance2"    # Replace with your second SQL Server instance
$config['instance3'] = "$($config['host3'])\SQLInstance3"    # Replace with your third SQL Server instance

# Array of SQL Server instances (used in the tests of Test-DbaNetworkLatency and Get-DbaTopResourceUsage)
$config['instances'] = @($config['instance1'], $config['instance2'])

# SQL Server credentials
# Replace 'YourPassword' with your actual password and 'sa' with your username if different
$securePassword = ConvertTo-SecureString "P#ssw0rd" -AsPlainText -Force
$config['SqlCred'] = New-Object System.Management.Automation.PSCredential ("sa", $securePassword)

<# Default parameter values for the tests
$config['Defaults'] = [System.Management.Automation.DefaultParameterDictionary]@{
    "*:SqlCredential"            = $config['SqlCred']
    "*:SourceSqlCredential"      = $config['SqlCred']
    "*:DestinationSqlCredential" = $config['SqlCred']
}
#>

# Additional configurations (needed for the test of Test-DbaDiskAlignment)
$config['dbatoolsci_computer'] = $config['host1']    # Replace if your CI computer is different

# If using SQL authentication for Instance2, specify the username and password (is used by the tests of Test-DbaDiskSpeed and Invoke-DbaDbDecryptObject)
#$config['instance2SQLUserName'] = $null        # Replace with username if applicable
#$config['instance2SQLPassword'] = $null        # Replace with password if applicable

# Detailed instance name for Instance2 (needed only for the test of Restore-DbaDatabase)
$config['instance2_detailed'] = "$($config['host1']),14333\SQLInstance2"  # Adjust port and instance name as necessary

# Path to your local AppVeyor lab repository (if applicable)
$config['appveyorlabrepo'] = "\\fs\appveyor-lab"

$config['Temp'] = "\\fs\Temp"
