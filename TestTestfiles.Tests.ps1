#Requires -Module @{ ModuleName="Pester"; ModuleVersion="6.0"}
param(
    $ModuleName               = "dbatools",
    $PSDefaultParameterValues = $TestConfig.Defaults,
    $TestPath                 = 'C:\GitHub\dbatools\tests',
    $ManifestPath             = 'C:\GitHub\dbatools\dbatools.psd1'
)

BeforeDiscovery {
    # Every test file is checked, not just the *-Dba* ones. The four below are the only files in
    # tests\ that are not the test of a single command, so they cannot follow the layout.
    # Everything else - including the tests of private functions like Stop-Function - can and does.
    $notACommandTest = @(
        'appveyor.common.Tests.ps1'
        'dbatools.Tests.ps1'
        'InModule.Commands.Tests.ps1'
        'InModule.Help.Tests.ps1'
    )
    $testFile = Get-ChildItem -Path "$TestPath\*.Tests.ps1" |
        Where-Object { $PSItem.Name -notin $notACommandTest } |
        Sort-Object -Property Name
}

Describe "the test file <_.Name>" -ForEach $testFile {
    BeforeAll {
        # Returns every tag of a Describe/Context/It block.
        # Handles -Tag and its alias -Tags, the -Tag:Value form, and both a single value and an
        # array literal, so that a block cannot hide from the checks below through the way its tags
        # happen to be written. Reading only "-Tag <bareword>" used to miss "-Tags IntegrationTests"
        # and "-Tag UnitTests, 'Something'", and a block missed here silently skipped the
        # EnableException checks instead of running them.
        function Get-CommandTag {
            param($CommandAst)
            $elements = $CommandAst.CommandElements
            for ($i = 0; $i -lt $elements.Count; $i++) {
                if ($elements[$i] -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
                if ($elements[$i].ParameterName -notin 'Tag', 'Tags') { continue }
                # -Tag:Value binds the value to the parameter itself, -Tag Value puts it next
                $value = $elements[$i].Argument
                if (-not $value -and $i -lt $elements.Count - 1) { $value = $elements[$i + 1] }
                if ($value -is [System.Management.Automation.Language.ArrayLiteralAst]) {
                    return @($value.Elements.Value)
                }
                return @($value.Value)
            }
        }

        # Returns every Describe command in the file, at any depth. A Describe nested in a top level
        # InModuleScope is still a Describe, and looking only at the top level would report a file
        # that keeps all of its unit tests in one as having none.
        function Get-DescribeCommand {
            param($Ast)
            $Ast.FindAll({
                    $args[0] -is [System.Management.Automation.Language.CommandAst] -and
                    $args[0].CommandElements[0].Value -eq 'Describe'
                }, $true)
        }

        $commandName = $PSItem.Name -replace '\.Tests\.ps1$', ''

        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($PSItem.FullName, [ref]$tokens, [ref]$errors)

        $paramBlockParameters = $ast.ParamBlock.Parameters

        # All statements at the top level of the file have to be commands, and only a few of them.
        $topLevelCommands = $ast.EndBlock.Statements.PipelineElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandAst] }
        # Note the ForEach-Object: $topLevelCommands.CommandElements flattens the elements of all
        # commands into a single list, so indexing [0] into that returns the first element of the
        # first command and nothing else. Written that way the check only ever looked at one
        # statement per file, and a top level Write-Host passed it.
        $topLevelNames = $topLevelCommands | ForEach-Object { $PSItem.CommandElements[0].Value }
        # Dot sourcing is how the tests of a private function get at the function under test.
        $dotSourced = $topLevelCommands | Where-Object { $PSItem.InvocationOperator -eq 'Dot' } | ForEach-Object { $PSItem.CommandElements[0].Value }
        $allowedTopLevel = @('Describe', 'InModuleScope', 'BeforeDiscovery') + $dotSourced

        $describeCommands = Get-DescribeCommand -Ast $ast
        $unitTestBlocks = $describeCommands | Where-Object { 'UnitTests' -in (Get-CommandTag -CommandAst $PSItem) }
        $integrationTestBlocks = $describeCommands | Where-Object { 'IntegrationTests' -in (Get-CommandTag -CommandAst $PSItem) }

        # Loops that build test blocks. The loop runs while Pester discovers the tests and the
        # bodies run afterwards, so the loop variables no longer exist by then. The generated tests
        # are either missing entirely or assert nothing, and in both cases the test report looks
        # healthy. Use -ForEach with cases built in BeforeDiscovery instead.
        $loopStatements = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.LoopStatementAst] }, $true)
        $loopsBuildingTests = $loopStatements | Where-Object {
            $PSItem.FindAll({
                    $args[0] -is [System.Management.Automation.Language.CommandAst] -and
                    $args[0].CommandElements[0].Value -in 'It', 'Context', 'Describe'
                }, $true)
        }

        # Blocks switched off with a bare -Skip, so no condition can ever switch them back on.
        $allBlocks = $ast.FindAll({
                $args[0] -is [System.Management.Automation.Language.CommandAst] -and
                $args[0].CommandElements[0].Value -in 'Describe', 'Context', 'It'
            }, $true)
        $unconditionallySkipped = $allBlocks | Where-Object {
            $PSItem.CommandElements | Where-Object {
                $_ -is [System.Management.Automation.Language.CommandParameterAst] -and
                $_.ParameterName -in 'Skip', 'skip' -and -not $_.Argument
            }
        }

        # Should -Throw compares the expected message with -like. Without a wildcard the assertion
        # can only pass if the command reports nothing but that exact string, which is almost never
        # true. These were a substring match in Pester 4 and passed there.
        $throwWithoutWildcard = @()
        foreach ($command in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] -and $args[0].CommandElements[0].Value -eq 'Should' }, $true)) {
            $elements = $command.CommandElements
            for ($i = 1; $i -lt $elements.Count; $i++) {
                if ($elements[$i] -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
                if ($elements[$i].ParameterName -notin 'Throw', 'ExpectedMessage') { continue }
                $value = $elements[$i].Argument
                if (-not $value -and $i -lt $elements.Count - 1 -and $elements[$i + 1] -isnot [System.Management.Automation.Language.CommandParameterAst]) {
                    $value = $elements[$i + 1]
                }
                if ($value -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $value.Value -notmatch '[\*\?]') {
                    $throwWithoutWildcard += $command
                }
            }
        }

        # A Mock without -ModuleName does not apply to the code inside the module, so the command
        # under test runs unmocked while the test looks like it is isolated. Only mocks inside an
        # InModuleScope are already in the right scope.
        $mocksWithoutModuleName = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] -and $args[0].CommandElements[0].Value -eq 'Mock' }, $true) |
            Where-Object {
                $hasModuleName = $PSItem.CommandElements | Where-Object {
                    $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'ModuleName'
                }
                if ($hasModuleName) { return $false }
                $parent = $PSItem.Parent
                while ($parent) {
                    if ($parent -is [System.Management.Automation.Language.CommandAst] -and $parent.CommandElements[0].Value -eq 'InModuleScope') { return $false }
                    $parent = $parent.Parent
                }
                return $true
            }

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
        $notACommand = $ast.EndBlock.Statements | Where-Object { $_.PipelineElements[0] -isnot [System.Management.Automation.Language.CommandAst] }
        $notACommand.Extent.Text | Should -BeNullOrEmpty -Because 'only commands are allowed at the top level of a test file'

        $otherCommands = $topLevelNames | Where-Object { $_ -notin $allowedTopLevel }
        $otherCommands | Should -BeNullOrEmpty -Because 'only Describe, InModuleScope, BeforeDiscovery and dot sourcing are allowed at the top level'
    }

    It "Has at least one Describe block for the unit tests" {
        $unitTestBlocks | Should -Not -BeNullOrEmpty
    }

    It "Does not build test blocks in a loop" {
        # See the comment on $loopsBuildingTests above.
        $loopsBuildingTests | ForEach-Object { "line $($PSItem.Extent.StartLineNumber): $($PSItem.Extent.Text.Split([Environment]::NewLine)[0])" } |
            Should -BeNullOrEmpty -Because 'a loop around It runs at discovery and its variables are gone when the body runs - use -ForEach with cases from BeforeDiscovery'
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

    # Also goals. These are small numbers across the tree, but each one needs a look at the
    # individual test before it can be changed, so they are reported and not enforced yet.
    It "Passes a wildcard to every Should -Throw that expects a message" -Tag Goal {
        $throwWithoutWildcard | ForEach-Object { "line $($PSItem.Extent.StartLineNumber): $($PSItem.Extent.Text)" } |
            Should -BeNullOrEmpty -Because 'Should -Throw matches with -like, so a message without a wildcard never matches'
    }

    It "Uses ModuleName on every Mock outside of InModuleScope" -Tag Goal {
        $mocksWithoutModuleName | ForEach-Object { "line $($PSItem.Extent.StartLineNumber): $($PSItem.Extent.Text.Split([Environment]::NewLine)[0])" } |
            Should -BeNullOrEmpty -Because 'a Mock without -ModuleName never applies to the code inside the module'
    }

    It "Has no block switched off with a bare -Skip" -Tag Goal {
        # A bare -Skip is not wrong in itself, but nothing makes it visible afterwards. This test
        # exists so that a permanently skipped block stays a conscious decision - Update-DbaInstance
        # hid 69 unit tests behind one for two years.
        $unconditionallySkipped | ForEach-Object { "line $($PSItem.Extent.StartLineNumber): $($PSItem.CommandElements[0].Value) $($PSItem.CommandElements[1].Extent.Text)" } |
            Should -BeNullOrEmpty -Because 'a block skipped without a condition can never run again'
    }
}

Describe "the test files as a whole" {
    BeforeAll {
        $manifest = Import-PowerShellDataFile -Path $ManifestPath
        $testedCommands = (Get-ChildItem -Path "$TestPath\*.Tests.ps1").Name -replace '\.Tests\.ps1$', ''
    }

    It "Has a test file for every public command" {
        $missing = $manifest.FunctionsToExport | Where-Object { $PSItem -notin $testedCommands }
        $missing | Should -BeNullOrEmpty -Because 'every exported command has to have a test file'
    }
}
