# Instance set "set03": everything on SQL03.
#
#     .\run_tests.ps1 -ConfigFilename TestConfig_remote_set03.ps1
#
# This is the default set and is defined in TestConfig_remote_instances.ps1 together with the lab description.
# This file exists so that every set can be named by its file, for example in Start-TestRun.ps1, and so that the
# result files say which set they belong to.

. "$PSScriptRoot\TestConfig_remote_instances.ps1"
