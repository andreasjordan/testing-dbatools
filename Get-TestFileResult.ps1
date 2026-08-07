# Turns the Pester result of a single test file into the flat result object that both runners log.
#
# Has to be dot-sourced, it only defines a function:
#     . .\Get-TestFileResult.ps1
#
# This is a pure function of the result objects on purpose. Invoke-Pester itself stays in the
# calling script, because the test files look up $TestConfig through the scope chain of their
# caller and running them from inside a function would change that chain.

function Get-TestFileResult {
    [CmdletBinding()]
    param (
        # The result of Invoke-Pester -PassThru for one test file.
        [Parameter(Mandatory)]
        [object]$PesterResult,
        # The test file that was run, used to look up the source line of a failure.
        [Parameter(Mandatory)]
        [string]$Path,
        # The result of Invoke-Pester -PassThru for TestEnvironment.Tests.ps1, if it was run.
        [object]$EnvironmentResult,
        # Warnings the test file wrote, collected by the caller.
        [string[]]$Warning,
        # Values only run_tests.ps1 measures. They are always part of the output, so that both
        # runners write the same set of keys and one analysis works for both log files.
        [object]$UsedMemoryMB,
        [object]$UsedInstances,
        [object]$SleepingProcs
    )

    $content = Get-Content -Path $Path -ErrorAction SilentlyContinue

    # Pester reports the details of a failure in three different places, depending on where it
    # happened, and only the first one is on the test itself:
    #   It fails            -> the test has the message, the line and the line text
    #   BeforeAll throws    -> the test is failed but its ErrorRecord is empty, the message is on the block
    #   Discovery throws    -> there are no tests at all, the message is on the container
    # Collecting only $PesterResult.Failed therefore loses every broken setup and every broken file.

    function Get-FailureInfo {
        param (
            [object]$ErrorRecord,
            [string]$Source,
            [string]$Name
        )

        $line     = $ErrorRecord.TargetObject.Line
        $lineText = $ErrorRecord.TargetObject.LineText

        # Block and container errors have no TargetObject, so we take the first stack frame instead
        # and read the line from the file - as long as the frame is really in this test file.
        if (-not $line) {
            $firstFrame = @($ErrorRecord.ScriptStackTrace -split "`r?`n" | Where-Object { $_ })[0]
            if ($firstFrame -match ",\s*(?<file>.+):\s*line\s*(?<line>\d+)\s*$") {
                if ((Split-Path -Path $Matches["file"] -Leaf) -eq (Split-Path -Path $Path -Leaf)) {
                    $line = [int]$Matches["line"]
                } else {
                    $lineText = "in $($Matches["file"]) line $($Matches["line"])"
                }
            }
        }

        if (-not $lineText -and $line -and $line -le $content.Count) {
            $lineText = $content[$line - 1]
        }

        $message = ($ErrorRecord.Exception.Message -split "`n" | ForEach-Object { $_.Trim() }) -join " "
        if (-not $message) {
            $message = "(no error record on the test, see the failures of type Block below)"
        }

        [PSCustomObject]@{
            Source   = $Source
            Name     = $Name
            Line     = $line
            LineText = "$lineText".Trim()
            Message  = $message
        }
    }

    function Get-BlockFailure {
        param (
            [object[]]$Block
        )

        foreach ($singleBlock in $Block) {
            foreach ($errorRecord in $singleBlock.ErrorRecord) {
                Get-FailureInfo -ErrorRecord $errorRecord -Source "Block" -Name $singleBlock.ExpandedPath
            }
            # Describe can contain Context can contain Describe, so we have to walk all of them.
            if ($singleBlock.Blocks) {
                Get-BlockFailure -Block $singleBlock.Blocks
            }
        }
    }

    $failures = @(
        foreach ($failedTest in $PesterResult.Failed) {
            Get-FailureInfo -ErrorRecord $failedTest.ErrorRecord -Source "Test" -Name $failedTest.ExpandedPath
        }
        foreach ($container in $PesterResult.Containers) {
            foreach ($errorRecord in $container.ErrorRecord) {
                Get-FailureInfo -ErrorRecord $errorRecord -Source "Container" -Name (Split-Path -Path $Path -Leaf)
            }
            Get-BlockFailure -Block $container.Blocks
        }
    )

    # A test file must not leave dbatools imported, because the next test file has to start with
    # the module in a defined state. We import from the psm1 file, so our own import has version 0.0
    # and does not count.
    $moduleLeftLoaded = [bool](Get-Module -Name dbatools | Where-Object { $_.Version.Major -gt 0 })

    [PSCustomObject]@{
        Type              = "TestFile"
        TestFileName      = Split-Path -Path $Path -Leaf
        Result            = "$($PesterResult.Result)"
        DurationSeconds   = [math]::Round($PesterResult.Duration.TotalSeconds, 1)
        TotalCount        = $PesterResult.TotalCount
        PassedCount       = $PesterResult.PassedCount
        FailedCount       = $PesterResult.FailedCount
        SkippedCount      = $PesterResult.SkippedCount
        FailureCount      = $failures.Count
        TestsFailed       = $failures
        # Filtered, because @($null) is an array with one empty element, not an empty array,
        # and that shows up in every single line of the log file.
        EnvironmentFailed = @($EnvironmentResult.Failed.ExpandedPath | Where-Object { $_ })
        ModuleLeftLoaded  = $moduleLeftLoaded
        Warnings          = @($Warning | Where-Object { $_ })
        UsedMemoryMB      = $UsedMemoryMB
        UsedInstances     = @($UsedInstances | Where-Object { $_ })
        SleepingProcs     = $SleepingProcs
    }
}
