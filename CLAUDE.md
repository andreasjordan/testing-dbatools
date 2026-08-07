# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A collection of standalone PowerShell scripts (no module, no build step, no CI) that:

1. **Build lab environments** — Azure VMs, Windows failover clusters, SQL Server FCIs, and standalone instances.
2. **Run the Pester test suite of the [dbatools](https://github.com/dataplat/dbatools) module** against those labs, one test file at a time, and analyse the results.

This is an *addition* to the dbatools CI, not a replacement. That CI moved off AppVeyor onto self-hosted Azure VMSS runners in July 2026, but the AppVeyor matrix and its `tests\appveyor.*.ps1` scripts were ported rather than rewritten — so the scenario names below still line up with the CI lanes. `README.md` tracks which dbatools tests are currently excluded and the longer-term goals.

Every script assumes a Windows host with PowerShell and the `dbatools` and `PSFramework` modules available. There is nothing to build, lint, or install for this repo itself.

## Hard-coded sibling repository layout

Most scripts hard-code `$githubBase = 'C:\GitHub'` and derive:

- `C:\GitHub\dbatools` — the module under test (imported directly from `dbatools.psm1`, not from the gallery)
- `C:\GitHub\testing-dbatools` — this repo
- `C:\GitHub\appveyor-lab` — test fixture data referenced by the config as `appveyorlabrepo`

Changing paths means editing the scripts; there is no central settings file.

## Working on a single command

This is the loop for fixing a bug or building a feature in dbatools:

```powershell
# Set up the session: imports dbatools from source and loads $TestConfig.
# Must be dot-sourced.
. .\Initialize-LabSession.ps1

# Run the tests of one command and get the failing line and message for each failure
.\Invoke-DbatoolsTest.ps1 Get-DbaDatabase
.\Invoke-DbatoolsTest.ps1 Get-DbaDatabase, New-DbaDatabase -Tag IntegrationTests
.\Invoke-DbatoolsTest.ps1 'Get-DbaDb*' -SkipEnvironmentTest

# Clean up after a run that failed halfway through
.\Reset-TestEnvironment.ps1 -WhatIf     # always look first, this drops databases
.\Reset-TestEnvironment.ps1
```

`Invoke-DbatoolsTest.ps1` reports, per test file: the Pester counts, every failed test with its line and message, any leftovers the test caused in the lab, and whether the test file left the dbatools module loaded. Results also go to `logs\command_<timestamp>.txt` as JSON.

## Running the whole suite

```powershell
# Everything, using the default config (TestConfig_remote_instances.ps1)
.\run_tests.ps1

# A single command's test file (and everything alphabetically after it)
.\run_tests.ps1 -CommandToStartWith Get-DbaDatabase -NumberOfTestsToTest 1

# One scenario group (keys of $TestsRunGroups in dbatools\tests\pester.groups.ps1)
.\run_tests.ps1 -Scenario SINGLE

# Against the local-instance lab instead
.\run_tests.ps1 -ConfigFilename TestConfig_local_instances.ps1

# Keep going after a failing test, and treat any Pester warning as a failure
.\run_tests.ps1 -ContinueOnFailure -TestForWarnings

# Override or add single config values without touching the config file
.\run_tests.ps1 -Config @{ InstanceSingle = 'SQL03\SQL2019' }

# Count connections the tests did not close (one query per instance and test file)
.\run_tests.ps1 -CheckSleepingConnections
```

`run_tests.ps1` is the entry point for everything test-related. Per test file it:

1. Runs `Invoke-Pester` on that one file (isolation between test files is deliberate — dbatools tests leak state).
2. Re-runs `TestEnvironment.Tests.ps1` afterwards to verify the lab was left clean.
3. Fails the run if dbatools is still loaded afterwards (a test file must not leave the module imported).
4. Appends one compressed JSON line per test file to `logs\results_<Scenario>_<timestamp>.txt`.

By default it stops at the first failure. `logs\` is gitignored except for its README.

### The result file format

A result file is JSON lines with three kinds of line, told apart by their `Type`:

- `RunStart` (first line) — start time, machine, the dbatools branch, commit and whether the working
  tree was dirty, the Pester version, the config file, the scenario, the instances and the parameters
  the run was started with. Without it a result file cannot be attributed to anything afterwards.
- `TestFile` (one per test file) — the Pester counts, the flattened failures, the lab leftovers,
  whether the module was left loaded, and the memory, instances and sleeping connections.
- `RunEnd` (last line) — how the run ended: completed count, duration and `StopReason`. It is also
  written when the run stops at a failure or dies with an error, so a short result file can be told
  apart from a run that is still going.

Both runners build the `TestFile` line through `Get-TestFileResult.ps1`, which is dot-sourced for
that single function. It is a pure function of the Pester result objects on purpose: `Invoke-Pester`
stays in the calling script, because the test files look up `$TestConfig` through the scope chain of
their caller and running them from inside a function would change that chain.

Every failure in `TestsFailed` carries a `Source` that says where Pester recorded the detail, and all
three have to be collected or failures are silently lost:

| Source | Happens when | Where the message is |
| --- | --- | --- |
| `Test` | an `It` fails | on the test, with line and line text |
| `Block` | a `BeforeAll` throws | on the block - the test is failed with a completely empty `ErrorRecord` |
| `Container` | discovery throws | on the container - there are no tests at all, so `FailedCount` is 0 |

Serialize these lines with `-Depth 6`. The `ConvertTo-Json` default of 2 truncates every failure to
`@{TargetObject=; Exception=}`, which produces a log that says what failed but not why.

### Analysing results

- `analyse_test_results.ps1` — loads the newest `logs\results_*.txt`, prints the run header and footer, groups passed/failed, and shows every failure with its source, line and message, plus lab leftovers, a module left loaded and warnings. Result files written before the header existed still work, because a line without a `Type` is treated as a test file. Has a deliberate `break` partway through; the lines after it are meant to be run interactively (`Out-GridView` pickers). Note that the `break` also ends the script that called it.
- `analyse_local_tests.ps1` — same idea, but loads all result files and sets up `$TestConfig` first.
- `analyse_tests.ps1` — static analysis over the dbatools test files: which `$TestConfig.Instance*` each test uses, grouped summary to the clipboard, `-PassThru` for objects. Useful for deciding which instances a change can affect.

The two `analyse_*_tests.ps1` scripts are working scratch scripts meant to be stepped through in an editor, not run unattended.

## Configuration model

`Get-TestConfig` lives in dbatools (`private\testing\Get-TestConfig.ps1`). It builds a `$config` hashtable with defaults (`CommonParameters`, `Defaults` with `Confirm = $false` and `WarningVariable = 'WarnVar'`, `Temp`), then **dot-sources the file passed as `-LocalConfigPath`**, which mutates `$config` in place. The `TestConfig_*.ps1` files in this repo are exactly those local config files — they are not standalone scripts and only make sense when dot-sourced by `Get-TestConfig`.

If the path does not exist, `Get-TestConfig` silently falls back to AppVeyor/Codespaces/GitHub-Actions detection. A typo in a config filename therefore produces confusing results rather than an error — worth checking first when instances look wrong.

Two config generations coexist:

- `TestConfig_remote_instances.ps1` — current naming: `InstanceSingle`, `InstanceMulti1/2`, `InstanceCopy1/2`, `InstanceHadr`, `InstanceRestart`. These are the same keys the CI matrix in `dbatools\.github\workflows\ci-azure.yml` sets per lane, and they map onto the scenario groups in `dbatools\tests\pester.groups.ps1`, which `run_tests.ps1 -Scenario` uses via `Get-TestsForScenario`. Several entries deliberately point at the same instance.
- `TestConfig_local_instances.ps1` — older naming: `instance1/2/3` on one host, plus `SqlCred`, `instance2_detailed`, and commented-out Azure/SSIS entries. The local install/uninstall scripts use this generation.

Both detect the SQL Server source media location by probing paths (`C:\SQLServerFull` on an Azure image, or shares on `\\dc`), and both carry the expectations that `TestEnvironment.Tests.ps1` asserts against: `ExpectedTcpPort`, `HadrInstances` and `AgCertificateInstances`. Those must be kept in step with what `06_configure_instances.ps1` (remote) or `install_local_instances.ps1` (local) actually configures.

Anything that discovers instances — the environment test, `Reset-TestEnvironment.ps1`, `Initialize-LabSession.ps1` — derives them from the `Instance*` properties of the loaded config rather than hard-coding names, so both generations work.

## Lab building scripts

Two independent lab flavours; pick one, they are not meant to be combined.

**Single-machine / Azure lab (older, config-driven):**

- `setup_azure.ps1` — creates the resource group, key vault + self-signed cert, vnet/NSG (RDP + WinRM opened to the caller's current public IP only), a SQL Server VM image, installs modules and chocolatey packages over WinRM, clones the three GitHub repos, then opens RDP. Rerunnable with `-Continue`.
- `install_local_instances.ps1` / `uninstall_local_instances.ps1` — install or remove `instance1/2/3` on the local machine via `Install-DbaInstance`, then apply the extra configuration the tests assume: master key, CLR, EKM cryptographic provider, Hadr + `dbatoolsci_AGCert`, static ports 14333/14334. Installs may require a reboot and the script tells you to rerun after restarting.

**Multi-machine domain lab (current, numbered scripts run in order):**

| Script | Purpose |
| --- | --- |
| `01_install_windows_cluster01.ps1` | iSCSI target on the storage server, shared disks, `CLUSTER01` on SQL01/SQL02 (with shared storage, for FCIs) |
| `02_install_windows_cluster02.ps1` | `CLUSTER02` on SQL03/SQL04, no shared storage (for AGs) |
| `03_install_alwayson_fci.ps1` | FCI `FCI01` (default instance) on CLUSTER01 |
| `04_install_alwayson_fci2.ps1` | FCI `FCI02\SQL2022` on CLUSTER01 |
| `05_install_remote_instances.ps1` | Standalone instances SQL2025/2022/2019 on SQL03 and SQL04 |
| `06_configure_instances.ps1` | Post-install config across all instances: remote DAC, master key, EKM provider, Hadr + AG certificate, static port |
| `c2_remove.ps1`, `c3_remove.ps1` | Remove FCI nodes (`ACTION = RemoveNode`) to tear a cluster instance back down |

Scripts 02–06 take everything as parameters with defaults; 01 uses an inline `$config` hashtable instead. They log progress with `Write-PSFMessage -Level Host` and `throw` on failure. Domain names, IPs, the `ORDIX\Admin` credential and the `ORDIX\gMSA-SQLServer$` service account are hard-coded — adapt them for another environment.

## Test-shape enforcement scripts

The dbatools test files follow a strict layout, and two scripts here check it. They overlap on purpose — one is strict about formatting, the other about structure:

- `TestTestLayout.ps1` — line-exact assertions (`$content[7] | Should -BeExactly ...`) over every test file, including whitespace alignment. Reports every deviating file grouped by which step failed; `-OpenFailedInEditor` opens them in VS Code. Has an allow-list of files exempt from the parameter checks.
- `TestTestfiles.Tests.ps1` — a Pester run over every test file that checks structure via the PowerShell AST, so formatting differences don't matter: the 3-parameter `param` block, only `Describe`/`InModuleScope` at the top level, at least one `UnitTests` Describe, and that every `EnableException` enable is matched by a remove.

The one rule that is *not* enforced by default is that integration test setup must enable `EnableException` — that is a goal from `README.md` that most files don't meet yet, so it is tagged `Goal`. Run `Invoke-Pester -ExcludeTagFilter Goal` for current-state compliance, and drop the filter to see how far the goal still is.

Do not tighten these checks without first measuring against the whole tree. Several plausible-sounding rules are wrong: files legitimately have more than one `UnitTests` Describe, integration Describes don't have to start with `BeforeAll`, and the enable/remove pair is spread across `BeforeAll` and `AfterAll` in some files while sitting entirely inside `BeforeAll` in others.

`TestEnvironment.Tests.ps1` is different in kind: it asserts the *lab* is clean (no temp files, no leftover backups, no user databases, no leftover logins/endpoints, correct TCP ports, correct Hadr state, certificate only where expected). `run_tests.ps1` and `Invoke-DbatoolsTest.ps1` run it after every test file unless `-SkipEnvironmentTest`. Default backup folders of remote instances are reached through the admin share (`\\SQL03\C$\...`).

## Facts about the environment that are easy to get wrong

- **Pester 6 is the default since July 2026.** The dbatools CI pins `-RequiredVersion 6.0.0` in `tests\appveyor.prep.ps1`, and the runners here require `-MinimumVersion 6.0`. All 723 dbatools test files still declare `ModuleVersion="5.0"` in their `#Requires` line, which means "5.0 or newer" — so `TestTestLayout.ps1` still asserts `5.0` there. When dbatools bumps those lines, that assertion is the thing to update.
- **`Connect-DbaInstance` has no `-EnableException`.** It uses `-DisableException` and throws by default. Other `*-Dba*` commands still take `-EnableException`.
- **`Import-Module dbatools.psm1` reports version 0.0.** This is deliberate and load-bearing: it lets the runners detect a test file that left the *installed* module loaded, by checking for a dbatools module with a major version above 0.
- **`Get-TestConfig` fails silently.** A wrong `-LocalConfigPath` does not error, it falls back to AppVeyor/Codespaces/GitHub-Actions autodetection and you end up testing against empty instance names. `Initialize-LabSession.ps1` throws instead.

## Conventions

- `$ErrorActionPreference = 'Stop'` at the top of anything meant to run unattended.
- `Import-Module -Name dbatools` for lab scripts; `Import-Module "$dbatoolsBase\dbatools.psm1" -Force` in `run_tests.ps1` so the working copy is tested rather than an installed version.
- Splatting hashtables (`$instanceParams`, `$paramsAddNode`, …) rather than long call lines.
- Commented-out `# $test = $tests[0]` style lines inside loops are intentional — they let a loop body be run interactively.
- Test setup and teardown in dbatools must use `-EnableException` so a broken setup fails loudly rather than silently skewing results.

## Working on dbatools itself

`C:\GitHub\dbatools` is a real checkout tracking `development`. Changes there get their own feature branch per fix or feature; nothing is committed to `development` directly and nothing is pushed without review.
