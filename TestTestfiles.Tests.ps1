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
        # No dot sourcing: a private function does not need it, because a checkout has no
        # dbatools.dat and the psm1 then exports every function, private ones included.
        $allowedTopLevel = @('Describe', 'InModuleScope', 'BeforeDiscovery')

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

        # A statement inside an It that computes a comparison and throws the result away. It reads
        # like an assertion, it runs, and it can never fail. Only comparisons are flagged - a bare
        # method call is usually a deliberate side effect.
        $discardedComparison = @()
        foreach ($itCommand in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] -and $args[0].CommandElements[0].Value -eq 'It' }, $true)) {
            $body = $itCommand.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.ScriptBlockExpressionAst] } | Select-Object -First 1
            if (-not $body) { continue }
            foreach ($statement in $body.ScriptBlock.EndBlock.Statements) {
                if ($statement -isnot [System.Management.Automation.Language.PipelineAst]) { continue }
                if ($statement.PipelineElements.Count -ne 1) { continue }
                $element = $statement.PipelineElements[0]
                if ($element -isnot [System.Management.Automation.Language.CommandExpressionAst]) { continue }
                if ($element.Expression -is [System.Management.Automation.Language.BinaryExpressionAst]) {
                    $discardedComparison += $statement
                }
            }
        }

        # -ForEach is read at discovery, so its cases have to be built in a BeforeDiscovery. Fed from
        # a BeforeAll the variable is still empty at discovery and the block produces no tests at all
        # - the same failure as a foreach loop around It, just spelled differently.
        $discoveryVariable = @()
        foreach ($beforeDiscovery in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] -and $args[0].CommandElements[0].Value -eq 'BeforeDiscovery' }, $true)) {
            $discoveryVariable += $beforeDiscovery.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true) |
                ForEach-Object { $PSItem.Left.Extent.Text.TrimStart('$') }
        }
        $forEachNotFromDiscovery = @()
        foreach ($block in $allBlocks) {
            $elements = $block.CommandElements
            for ($i = 0; $i -lt $elements.Count; $i++) {
                if ($elements[$i] -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
                if ($elements[$i].ParameterName -ne 'ForEach') { continue }
                $value = $elements[$i].Argument
                if (-not $value -and $i -lt $elements.Count - 1) { $value = $elements[$i + 1] }
                if ($value -is [System.Management.Automation.Language.VariableExpressionAst] -and $value.VariablePath.UserPath -notin $discoveryVariable) {
                    $forEachNotFromDiscovery += $block
                }
            }
        }

        # An integration Describe that creates objects on the instance but has no AfterAll anywhere.
        # A heuristic - some of these clean up in a way this cannot see - so it only reports.
        $integrationWithoutCleanup = $describeCommands | Where-Object {
            'IntegrationTests' -in (Get-CommandTag -CommandAst $PSItem) -and
            $PSItem.Extent.Text -match 'New-Dba|Backup-Dba|New-Item' -and
            $PSItem.Extent.Text -notmatch 'AfterAll'
        }

        $content = Get-Content -Path $PSItem.FullName
        $enableCount = ($content -match [regex]::Escape('$PSDefaultParameterValues["*-Dba*:EnableException"] = $true')).Count
        $removeCount = ($content -match [regex]::Escape('$PSDefaultParameterValues.Remove("*-Dba*:EnableException")')).Count

        # These read $content, so they have to come after it is filled. Every one is wrapped in
        # @() because -match against $null returns the boolean $false rather than an empty array,
        # and $false is not empty - the check would then fail on every file instead of none.
        $usesTemp = @($content -match [regex]::Escape('$TestConfig.Temp'))
        $usesGetRandom = @($content -match 'Get-Random')
        $underscoreVariable = @($content -match '\$_\.')
        $plainSplat = @($content -match '^\s*\$splat\s*=')
        $backtickContinuation = @($content -match '`\s*$')
        $stringSkip = @($content -match '-Skip:\s*"(true|false)"')
        $quotedCommandName = @($content -match '^\s*(Describe|Context)\s+"\$CommandName"')
        $oldInstanceName = @($content -match '\$TestConfig\.instance[123]\b')
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
        $otherCommands | Should -BeNullOrEmpty -Because 'only Describe, InModuleScope and BeforeDiscovery are allowed at the top level'
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
    # There is deliberately no check that Should -Throw uses a wildcard. It was tried: it flags
    # 13 assertions across 7 files, and every one that can be run passes, because the expected
    # message really is the whole message. An exact expectation is the stronger assertion, and
    # nothing in the syntax distinguishes it from a fragment that can never match. Only running
    # the test tells them apart, so this belongs in a test run and not in a static check.

    It "Uses ModuleName on every Mock outside of InModuleScope" -Tag Goal {
        $mocksWithoutModuleName | ForEach-Object { "line $($PSItem.Extent.StartLineNumber): $($PSItem.Extent.Text.Split([Environment]::NewLine)[0])" } |
            Should -BeNullOrEmpty -Because 'a Mock without -ModuleName never applies to the code inside the module'
    }

    # Real bugs, not style: both describe tests that do not exist or cannot fail. The tree is
    # clean, so they are hard checks.
    It "Has no It block that computes a comparison and throws it away" {
        $discardedComparison | ForEach-Object { "line $($PSItem.Extent.StartLineNumber): $($PSItem.Extent.Text)" } |
            Should -BeNullOrEmpty -Because 'an assertion has to be piped to Should, otherwise it runs and can never fail'
    }

    It "Builds every -ForEach case list in a BeforeDiscovery" {
        $forEachNotFromDiscovery | ForEach-Object { "line $($PSItem.Extent.StartLineNumber): $($PSItem.CommandElements[0].Value) $($PSItem.CommandElements[1].Extent.Text)" } |
            Should -BeNullOrEmpty -Because '-ForEach is read at discovery, so a case list built in BeforeAll is still empty and the block produces no tests'
    }

    # Style and hygiene. These may stay Goal.
    It "Cleans up after an integration test that creates objects" -Tag Goal {
        $integrationWithoutCleanup | ForEach-Object { "line $($PSItem.Extent.StartLineNumber)" } |
            Should -BeNullOrEmpty -Because 'a Describe that creates objects on the instance needs an AfterAll that removes them'
    }

    It "Makes temporary paths unique with Get-Random" -Tag Goal {
        if (-not $usesTemp) {
            Set-ItResult -Skipped -Because "$($PSItem.Name) does not use TestConfig.Temp"
        }
        $usesGetRandom | Should -Not -BeNullOrEmpty -Because 'two test files sharing a temp path collide when they run in the same lab'
    }

    It "Uses PSItem rather than the underscore variable" -Tag Goal {
        $underscoreVariable | Should -BeNullOrEmpty -Because 'the guide asks for $PSItem except where compatibility needs $_'
    }

    It "Names every splat after its purpose" -Tag Goal {
        $plainSplat | Should -BeNullOrEmpty -Because 'a plain $splat collides across scopes, the guide asks for $splat<Purpose>'
    }

    It "Uses no backtick line continuation" -Tag Goal {
        $backtickContinuation | Should -BeNullOrEmpty -Because 'backticks are banned, use splatting or a natural line break'
    }

    # Ratchets. The whole tree already passes these, so they are hard checks that keep it that way.
    It "Uses a boolean and not a string for -Skip" {
        $stringSkip | Should -BeNullOrEmpty -Because 'a non-empty string is always true, so -Skip:"false" skips the test'
    }

    It "Puts no unnecessary quotes around the command name" {
        $quotedCommandName | Should -BeNullOrEmpty -Because 'Describe $CommandName does not need quoting'
    }

    It "Uses the current TestConfig instance names" {
        $oldInstanceName | Should -BeNullOrEmpty -Because 'instance1, instance2 and instance3 no longer exist, see the instance table in tests/CLAUDE.md'
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
