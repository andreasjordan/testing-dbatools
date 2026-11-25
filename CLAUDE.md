# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A collection of standalone PowerShell scripts (no module, no build step, no CI) that:

1. **Build the lab** — Windows failover clusters, SQL Server FCIs, and standalone instances in a Windows domain.
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

# Keep going after a failing test, and treat any Pester warning as a failure
.\run_tests.ps1 -ContinueOnFailure -TestForWarnings

# Override or add single config values without touching the config file
.\run_tests.ps1 -Config @{ InstanceSingle = 'SQL03\SQL2019' }

# Count connections the tests did not close (one query per instance and test file)
.\run_tests.ps1 -CheckSleepingConnections

# Everything except one scenario group, and the files from Z to A (both exist for running beside another set)
.\run_tests.ps1 -ConfigFilename TestConfig_remote_set04.ps1 -ExcludeScenario HADR -ReverseOrder

# Two sets side by side, each in its own process; the pairing rules are checked before anything starts
.\Start-TestRun.ps1 -ConfigFilename TestConfig_remote_set03.ps1, TestConfig_remote_set04.ps1 -ExcludeScenario '', HADR -Edition Desktop, Core -ContinueOnFailure -TestForWarnings
```

`run_tests.ps1` is the entry point for everything test-related. Per test file it:

1. Runs `Invoke-Pester` on that one file (isolation between test files is deliberate — dbatools tests leak state).
2. Re-runs `TestEnvironment.Tests.ps1` afterwards to verify the lab was left clean.
3. Fails the run if dbatools is still loaded afterwards (a test file must not leave the module imported).
4. Appends one compressed JSON line per test file to `logs\results_<Scenario>_<timestamp>.txt`.

By default it stops at the first failure. `logs\` is gitignored except for its README.

### Running two sets side by side

Every file a run writes carries the run's timestamp, including the per-test-file warnings capture `logs\<Test>.Tests.ps1.warnings_<timestamp>.txt` (kept only when that file wrote warnings), and every set has its own temp folder below `\\fs\Temp`. So two runs can share the lab as long as they share nothing else. The rules, with the reasons, are in the header of `TestConfig_remote_instances.ps1`; `Start-TestRun.ps1` checks them before it starts anything:

1. **Disjoint hosts, not only disjoint instances** - 41 test files act on the host of an instance through `-ComputerName`.
2. **At most one Hadr instance inside CLUSTER02** (SQL03 and SQL04) - the Hadr tests create availability groups with fixed names, and an availability group is a cluster group. The other set runs with `-ExcludeScenario HADR` and its `-Scenario HADR` afterwards.
3. **One run at a time for now** - ADMIN01 has 9 GB, and a full run on Windows PowerShell 5.1 peaks at about 5.8 GB (2026-11-25, every set). Two runs side by side still finished that night, but they grew the page file from 2 to 6.3 GB. Rules 1 and 2 matter again once ADMIN01 has room for two runs. `Start-TestRun.ps1` does not check this rule.

Two runs started together stay in lockstep for the whole day, so they process the same test file at the same moment. `Start-TestRun.ps1` therefore gives every second run `-ReverseOrder`, and the per-set temp folders keep the fixed fixture names apart. Start it from a PowerShell console: a runner started from Git Bash inherits a PATH whose `whoami` answers `Admin` instead of `ORDIX\Admin` and two tests fail on that alone; a Windows PowerShell runner started from pwsh needs the module path of Windows PowerShell, which the launcher sets.

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

It is a working scratch script meant to be stepped through in an editor, not run unattended. Which `$TestConfig.Instance*` a dbatools test file uses, and so which instances a change can affect, `Get-TestInstanceUsage` reports (a private dbatools command, available after importing `dbatools.psm1`).

## Configuration model

`Get-TestConfig` lives in dbatools (`private\testing\Get-TestConfig.ps1`). It builds a `$config` hashtable with defaults (`CommonParameters`, `Defaults` with `Confirm = $false` and `WarningVariable = 'WarnVar'`, `Temp`), then **dot-sources the file passed as `-LocalConfigPath`**, which mutates `$config` in place. The `TestConfig_*.ps1` files in this repo are exactly those local config files — they are not standalone scripts and only make sense when dot-sourced by `Get-TestConfig`.

If the path does not exist, `Get-TestConfig` silently falls back to AppVeyor/Codespaces/GitHub-Actions detection. A typo in a config filename therefore produces confusing results rather than an error — worth checking first when instances look wrong.

`TestConfig_remote_instances.ps1` uses the instance names `InstanceSingle`, `InstanceMulti1/2`, `InstanceCopy1/2`, `InstanceHadr`, `InstanceRestart`. These are the same keys the CI matrix in `dbatools\.github\workflows\ci-azure.yml` sets per lane, and they map onto the scenario groups in `dbatools\tests\pester.groups.ps1`, which `run_tests.ps1 -Scenario` uses via `Get-TestsForScenario`. Several entries deliberately point at the same instance. This file holds the lab description (shares, clusters, Azure, expectations) plus the default set of roles, which is `set03`. The other sets - `TestConfig_remote_set04.ps1`, `TestConfig_remote_setFCI.ps1` and the alias `TestConfig_remote_set03.ps1` - dot-source it and override only the roles and `Temp`. Each set lives on one host (SQL03, SQL04, or CLUSTER01 plus SQL03), so that two of them can run side by side; the header of the base file lists them and the rules.

It detects the SQL Server source media location by probing the shares on `\\dc`, and carries the expectations that `TestEnvironment.Tests.ps1` asserts against: `ExpectedTcpPort`, `HadrInstances` and `AgCertificateInstances`. Those must be kept in step with what `06_configure_instances.ps1` actually configures.

Anything that discovers instances — the environment test, `Reset-TestEnvironment.ps1`, `Initialize-LabSession.ps1` — derives them from the `Instance*` properties of the loaded config rather than hard-coding names.

## Lab building scripts

The lab is a Windows domain on the Hyper-V host BASE in Azure. `MyAzureLab\HyperVLab\install_TestingDbatools.ps1` builds the machines and then runs these scripts in order on ADMIN01:

| Script | Purpose |
| --- | --- |
| `01_install_windows_cluster01.ps1` | iSCSI target on the storage server, shared disks, `CLUSTER01` on SQL01/SQL02 (with shared storage, for FCIs) |
| `02_install_windows_cluster02.ps1` | `CLUSTER02` on SQL03/SQL04, no shared storage (for AGs) |
| `03_install_alwayson_fci.ps1` | FCI `FCI01` (default instance) on CLUSTER01 |
| `04_install_alwayson_fci2.ps1` | FCI `FCI02\SQL2022` on CLUSTER01 |
| `05_install_remote_instances.ps1` | Standalone instances SQL2025/2022/2019 on SQL03 and SQL04 |
| `06_configure_instances.ps1` | Post-install config across all instances: remote DAC, master key, EKM provider, Hadr + AG certificate, static port |
| `07_configure_certificate_authority.ps1` | What the lab CA needs beyond the AutomatedLab role `CaRoot`: the flag `EDITF_ATTRIBUTEENDDATE` (short-lived certificates) and the template `WebServerPendingApproval` (requests held as pending) |
| `c2_remove.ps1`, `c3_remove.ps1` | Remove FCI nodes (`ACTION = RemoveNode`) to tear a cluster instance back down |

Scripts 02–07 take everything as parameters with defaults; 01 uses an inline `$config` hashtable instead. They log progress with `Write-PSFMessage -Level Host` and `throw` on failure. Domain names, IPs, the `ORDIX\Admin` credential and the `ORDIX\gMSA-SQLServer$` service account are hard-coded — adapt them for another environment.

Until 2026-11-24 there was also a single-machine lab: `setup_azure.ps1` built one Azure VM with SQL Server 2022 preinstalled, and `install_local_instances.ps1` added and configured two more instances on it. The idea was that someone who reports a bug can build the same lab to reproduce it as the one used to fix it. Its configuration still used the instance names `instance1/2/3`, which no dbatools test reads any more, so it was removed; `git log -- setup_azure.ps1` finds it for a rebuild.

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
