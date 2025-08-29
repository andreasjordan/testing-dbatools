Import-Module -Name dbatools

$tests = Get-ChildItem .\tests -Filter *-Dba*.Tests.ps1

try {
    foreach ($test in $tests) {
        # $test = $tests[0]

        $content = Get-Content -Path $test.FullName

        # We test if every "$PSDefaultParameterValues["*-Dba*:EnableException"] = $true" has a "$PSDefaultParameterValues.Remove("*-Dba*:EnableException")"
        $eeTrue = ($content -match [regex]::Escape('$PSDefaultParameterValues["*-Dba*:EnableException"] = $true')).Count
        $eeFalse = ($content -match [regex]::Escape('$PSDefaultParameterValues.Remove("*-Dba*:EnableException")')).Count
        $eeTrue | Should -Be $eeFalse

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

        $content[7] | Should -BeIn 'Describe $CommandName -Tag UnitTests {', 'Describe $CommandName -Tag UnitTests -Skip:($PSVersionTable.PSVersion.Major -gt 5) {'
        $content[8] | Should -BeExactly '    Context "Parameter validation" {'
        $content[9] | Should -BeExactly '        It "Should have the expected parameters" {'
        $content[10] | Should -BeExactly '            $hasParameters = (Get-Command $CommandName).Parameters.Values.Name | Where-Object { $PSItem -notin ("WhatIf", "Confirm") }'
        
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

    }
} catch {
    Write-Warning -Message "Failed test: $test`n$_"
    code $test.FullName
}
