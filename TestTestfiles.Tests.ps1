#Requires -Module @{ ModuleName="Pester"; ModuleVersion="6.0"}
param(
    $ModuleName               = "dbatools",
    $PSDefaultParameterValues = $TestConfig.Defaults,
    $TestPath                 = 'C:\GitHub\dbatools\tests'
)

BeforeDiscovery {
    $testFile = Get-ChildItem -Path "$TestPath\*-Dba*.Tests.ps1" | Sort-Object -Property Name
}

Describe "the test file <_.Name>" -ForEach $testFile {
    BeforeAll {
        # Returns the value of -Tag of a Describe block.
        function Get-CommandTag {
            param($CommandAst)
            $elements = $CommandAst.CommandElements
            for ($i = 0; $i -lt $elements.Count - 1; $i++) {
                if ($elements[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $elements[$i].ParameterName -eq 'Tag') {
                    return $elements[$i + 1].Value
                }
            }
        }

        $commandName = $PSItem.Name -replace '\.Tests\.ps1$', ''

        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($PSItem.FullName, [ref]$tokens, [ref]$errors)

        $paramBlockParameters = $ast.ParamBlock.Parameters

        # All statements at the top level of the file have to be commands (Describe or InModuleScope).
        $topLevelCommands = $ast.EndBlock.Statements.PipelineElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandAst] }
        $describeCommands = $topLevelCommands | Where-Object { $_.CommandElements[0].Value -eq 'Describe' }
        $unitTestBlocks = $describeCommands | Where-Object { (Get-CommandTag -CommandAst $_) -eq 'UnitTests' }
        $integrationTestBlocks = $describeCommands | Where-Object { (Get-CommandTag -CommandAst $_) -eq 'IntegrationTests' }

        $content = Get-Content -Path $PSItem.FullName
        $enableCount = ($content -match [regex]::Escape('$PSDefaultParameterValues["*-Dba*:EnableException"] = $true')).Count
        $removeCount = ($content -match [regex]::Escape('$PSDefaultParameterValues.Remove("*-Dba*:EnableException")')).Count
    }

    It "Can be parsed without errors" {
        $errors | Should -BeNullOrEmpty
    }

    It "Has the correct param block" {
        $paramBlockParameters.Count | Should -Be 3
        $paramBlockParameters.Name.VariablePath.UserPath | Should -Contain 'ModuleName'
        $paramBlockParameters.Name.VariablePath.UserPath | Should -Contain 'CommandName'
        $paramBlockParameters.Name.VariablePath.UserPath | Should -Contain 'PSDefaultParameterValues'
        ($paramBlockParameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'ModuleName' }).DefaultValue.Value | Should -Be 'dbatools'
        ($paramBlockParameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'CommandName' }).DefaultValue.Value | Should -Be $commandName
        ($paramBlockParameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'PSDefaultParameterValues' }).DefaultValue.Extent.Text | Should -Be '$TestConfig.Defaults'
    }

    It "Has only Describe blocks at the top level" {
        $ast.EndBlock.Statements.Count | Should -Be $topLevelCommands.Count
        $otherCommands = $topLevelCommands.CommandElements[0].Value | Where-Object { $_ -notin 'Describe', 'InModuleScope' }
        $otherCommands | Should -BeNullOrEmpty
    }

    It "Has at least one Describe block for the unit tests" {
        $unitTestBlocks | Should -Not -BeNullOrEmpty
    }

    # This is one of the goals from README.md and not yet reached by all test files,
    # so it is tagged and can be excluded: Invoke-Pester -ExcludeTagFilter Goal
    It "Enables EnableException for the setup of the integration tests" -Tag Goal {
        if (-not $integrationTestBlocks) {
            Set-ItResult -Skipped -Because "$($PSItem.Name) has no integration tests"
        }

        # The setup of the integration tests has to run with EnableException so that
        # the test fails loudly if the setup fails, instead of testing against a broken state.
        $enableCount | Should -BeGreaterThan 0
    }

    It "Removes EnableException again for every time it is set" {
        if (-not $integrationTestBlocks) {
            Set-ItResult -Skipped -Because "$($PSItem.Name) has no integration tests"
        }

        # We deliberately do not test where the two statements are placed.
        # Both of these are in use and both are fine:
        #   BeforeAll { enable ... remove } and AfterAll { enable ... }
        #   BeforeAll { enable ... }        and AfterAll { ... remove }
        # What always has to hold is that every enable is matched by a remove.
        $removeCount | Should -Be $enableCount
    }
}
