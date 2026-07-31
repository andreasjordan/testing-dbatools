[CmdletBinding()]
param (
    [string]$TestPath = 'C:\GitHub\dbatools\tests',
    # Opens every failing test file in Visual Studio Code.
    [switch]$OpenFailedInEditor
)

Import-Module -Name dbatools
Import-Module -Name Pester -MinimumVersion 5.0

$tests = Get-ChildItem -Path $TestPath -Filter *-Dba*.Tests.ps1 | Sort-Object -Property Name

$failed = foreach ($test in $tests) {
    # $test = $tests[0]

    # We collect the failures per file instead of stopping at the first one,
    # so that one run shows all the test files that need to be fixed.
    try {
        $content = Get-Content -Path $test.FullName

        # $step is reported with the failure so that it is clear which part of the layout is wrong.
        $step = 'EnableException is set and removed the same number of times'

        # We test if every "$PSDefaultParameterValues["*-Dba*:EnableException"] = $true" has a "$PSDefaultParameterValues.Remove("*-Dba*:EnableException")"
        $eeTrue = ($content -match [regex]::Escape('$PSDefaultParameterValues["*-Dba*:EnableException"] = $true')).Count
        $eeFalse = ($content -match [regex]::Escape('$PSDefaultParameterValues.Remove("*-Dba*:EnableException")')).Count
        $eeTrue | Should -Be $eeFalse

        $step = 'header and param block (line 1-7)'
        $content[0] | Should -BeExactly '#Requires -Module @{ ModuleName="Pester"; ModuleVersion="5.0" }'
        $content[1] | Should -BeExactly 'param('
        $content[2] | Should -BeExactly '    $ModuleName  = "dbatools",'
        $content[3] | Should -BeExactly ('    $CommandName = "{0}",' -f $test.Name.Replace('.Tests.ps1',''))
        $content[4] | Should -BeExactly '    $PSDefaultParameterValues = $TestConfig.Defaults'
        $content[5] | Should -BeExactly ')'
        $content[6] | Should -BeExactly ''

        if ($test.Name -in @(
            # No parameters to test:
            'Get-DbaConnectedInstance.Tests.ps1'
            'Measure-DbatoolsImport.Tests.ps1'
            'New-DbaScriptingOption.Tests.ps1'
            # Needs to be rewritten:
            'Update-DbaInstance.Tests.ps1'
            )) {
            continue
        }

        $step = 'Describe block for the unit tests (line 8-11)'
        $content[7] | Should -BeIn 'Describe $CommandName -Tag UnitTests {', 'Describe $CommandName -Tag UnitTests -Skip:($PSVersionTable.PSVersion.Major -gt 5) {'
        $content[8] | Should -BeExactly '    Context "Parameter validation" {'
        $content[9] | Should -BeExactly '        It "Should have the expected parameters" {'
        $content[10] | Should -BeExactly '            $hasParameters = (Get-Command $CommandName).Parameters.Values.Name | Where-Object { $PSItem -notin ("WhatIf", "Confirm") }'

        $step = 'list of expected parameters'
        # Some commands don't use [CmdletBinding()]
        if ($test.Name -in 'New-DbaReplCreationScriptOptions.Tests.ps1') {
            $content[11] | Should -BeExactly '            $expectedParameters = @( )  # Command does not use [CmdletBinding()]'
        } else {
            $content[11] | Should -BeExactly '            $expectedParameters = $TestConfig.CommonParameters'
        }

        $content[12] | Should -BeExactly '            $expectedParameters += @('

        $params = 0
        while (1) {
            if ($content[13+$params] -match '^                ".+",?$') {
                $params++
            } else {
                break
            }
        }
        $content[13+$params] | Should -BeExactly '            )'
        $content[14+$params] | Should -BeExactly '            Compare-Object -ReferenceObject $expectedParameters -DifferenceObject $hasParameters | Should -BeNullOrEmpty'
        $content[15+$params] | Should -BeExactly '        }'
        $content[16+$params] | Should -BeExactly '    }'
    } catch {
        [PSCustomObject]@{
            TestFileName = $test.Name
            FullName     = $test.FullName
            FailedStep   = $step
            Message      = ($_.Exception.Message -split "`n")[0].Trim()
        }
    }
}

Write-Host "Checked $($tests.Count) test files, $(@($failed).Count) of them do not have the expected layout"
$failed | Group-Object -Property FailedStep -NoElement | Sort-Object -Property Count -Descending | Format-Table -AutoSize
$failed | Format-Table -Property TestFileName, FailedStep -AutoSize

if ($OpenFailedInEditor) {
    foreach ($failure in $failed) {
        code $failure.FullName
    }
}
