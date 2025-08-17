$tests = Get-ChildItem .\tests -Filter *-Dba*.Tests.ps1

try {
    foreach ($test in $tests) {
        # $test = $tests[0]

        $content = Get-Content -Path $test.FullName

        if ($content[0] -ne '#Requires -Module @{ ModuleName="Pester"; ModuleVersion="5.0" }') {
            continue
        }
        $content[0] | Should -BeExactly '#Requires -Module @{ ModuleName="Pester"; ModuleVersion="5.0" }' 
        $content[1] | Should -BeExactly 'param('
        $content[2] | Should -BeExactly '    $ModuleName  = "dbatools",'
        $content[3] | Should -BeExactly ('    $CommandName = "{0}",' -f $test.Name.Replace('.Tests.ps1',''))
        $content[4] | Should -BeExactly '    $PSDefaultParameterValues = $TestConfig.Defaults'
        $content[5] | Should -BeExactly ')'
        $content[6] | Should -BeExactly ''
        $content[7] | Should -BeExactly 'Describe $CommandName -Tag UnitTests {'
        $content[8] | Should -BeExactly '    Context "Parameter validation" {'
        $content[9] | Should -BeExactly '        It "Should have the expected parameters" {'
        $content[10] | Should -BeExactly '            $hasParameters = (Get-Command $CommandName).Parameters.Values.Name | Where-Object { $PSItem -notin ("WhatIf", "Confirm") }'
        $content[11] | Should -BeExactly '            $expectedParameters = $TestConfig.CommonParameters'
        $content[12] | Should -BeExactly '            $expectedParameters += @('

    }
} catch {
    Write-Warning -Message "Failed test: $test`n$_"
    code $test.FullName
}


<# Find pester 4 tests:
    foreach ($test in $tests) {
        # $test = $tests[0]

        $content = Get-Content -Path $test.FullName

        if ($content[0] -ne '#Requires -Module @{ ModuleName="Pester"; ModuleVersion="5.0" }') {
            $test
        }
    }
#>