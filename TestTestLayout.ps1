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

        $commandName = $test.Name.Replace('.Tests.ps1','')
        $step = 'header and param block (line 1-7)'
        $content[0] | Should -BeExactly '#Requires -Module @{ ModuleName="Pester"; ModuleVersion="5.0" }'
        $content[1] | Should -BeExactly 'param('
        # The alignment of the equals sign is not enforced. 650 files line it up with
        # $CommandName below and 73 do not, and changing those 73 was explicitly not wanted, so
        # both spellings are accepted. Everything else about the param block still has to match.
        $content[2] | Should -BeIn '    $ModuleName  = "dbatools",', '    $ModuleName = "dbatools",'
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

        # The Context does not have to be the very next line. A comment explaining the -Skip: on the
        # Describe belongs there, and a test of a private function has to wrap the Context in an
        # InModuleScope. Both are legitimate, so the Context is searched for instead of being fixed
        # at line 9, and everything after it is measured from wherever it was found.
        $ctx = $null
        for ($i = 8; $i -lt 12; $i++) {
            if ($content[$i] -match '^\s+Context "Parameter validation" \{$') { $ctx = $i; break }
            if ($content[$i] -notmatch '^\s*(#|$)' -and $content[$i] -notmatch '^\s+InModuleScope ') { break }
        }
        $ctx | Should -Not -BeNullOrEmpty -Because 'the first Context has to be "Parameter validation"'
        $indent = ($content[$ctx] -replace '\S.*$', '')

        $content[$ctx+1] | Should -BeExactly ($indent + '    It "Should have the expected parameters" {')
        # A comment may sit anywhere inside this It - the project asks for comments to be kept,
        # and two files need one to explain why they deviate. So each expected line is searched
        # for rather than assumed to be at a fixed offset.
        $hp = $ctx + 2
        while ($content[$hp] -match '^\s*#') { $hp++ }

        # Private commands need no special form: a checkout has no dbatools.dat, so the psm1
        # exports every function and plain Get-Command finds them too.
        $content[$hp] | Should -BeExactly ($indent + '        $hasParameters = (Get-Command $CommandName).Parameters.Values.Name | Where-Object { $PSItem -notin ("WhatIf", "Confirm") }')

        $step = 'list of expected parameters'
        # A comment may sit between $hasParameters and $expectedParameters - the project asks for
        # comments to be kept, and at least one file needs to explain why it wraps the common
        # parameters. So the assignment is searched for rather than assumed to be the next line.
        $exp = $hp + 1
        while ($content[$exp] -match '^\s*#') { $exp++ }

        # Where a list of extra parameters follows, the bare property is fine: the "+= @()" turns it
        # into an array. Where it does not, $TestConfig.CommonParameters has to be wrapped, because
        # it is a HashSet and Compare-Object would treat it as a single object and match nothing.
        $hasExtraParameters = $content[$exp+1] -eq ($indent + '        $expectedParameters += @(')

        # Some commands don't use [CmdletBinding()]
        if ($test.Name -in 'New-DbaReplCreationScriptOptions.Tests.ps1') {
            $content[$exp] | Should -BeExactly ($indent + '        $expectedParameters = @( )  # Command does not use [CmdletBinding()]')
        } elseif ($hasExtraParameters) {
            $content[$exp] | Should -BeExactly ($indent + '        $expectedParameters = $TestConfig.CommonParameters')
        } else {
            $content[$exp] | Should -BeExactly ($indent + '        $expectedParameters = @($TestConfig.CommonParameters)')
        }

        if ($hasExtraParameters) {
            $params = 0
            while ($content[$exp+2+$params] -match '^\s+".+",?$') { $params++ }
            $content[$exp+2+$params] | Should -BeExactly ($indent + '        )')
            $offset = $exp + 3 + $params
        } else {
            $offset = $exp + 1
        }

        $content[$offset] | Should -BeExactly ($indent + '        Compare-Object -ReferenceObject $expectedParameters -DifferenceObject $hasParameters | Should -BeNullOrEmpty')
        $content[$offset+1] | Should -BeExactly ($indent + '    }')
        # The Context is deliberately not required to end here. Several files add a second It for an
        # alias, a mandatory parameter or a parameter set, which is exactly where those belong.
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
