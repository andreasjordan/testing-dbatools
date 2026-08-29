# A configuration whose InstanceSingle is case sensitive.
#
# SQL05 was installed with SQL_Latin1_General_CP1_CS_AS so that case sensitive behaviour can be tested
# at all - see the case sensitivity finding on dbatools PR #10579. The instances on SQL03 and SQL04 use
# the setup default, SQL_Latin1_General_CP1_CI_AS, where two databases whose names differ only in case
# cannot exist and the tests that need them skip themselves.
#
# Only InstanceSingle moves, because that is the instance those tests use.

$config['InstanceConfiguration'] = [ordered]@{
    Version          = 2025
}

$config['InstanceSingle'] = "SQL05\SQL2025"
$config['InstanceMulti1'] = "SQL03\SQL2025"
$config['InstanceMulti2'] = "SQL03\SQL2022"
$config['InstanceCopy1'] = "SQL03\SQL2022"
$config['InstanceCopy2'] = "SQL04\SQL2025"
$config['InstanceHadr'] = "SQL04\SQL2025"
$config['InstanceRestart'] = "SQL03\SQL2022"

$config['appveyorlabrepo'] = "\\fs\appveyor-lab"

$config['Temp'] = "\\fs\Temp"
