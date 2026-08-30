# Bootstrapping ADMIN01 after a lab rebuild

The lab setup (`MyAzureLab\HyperVLab\TestingDbatools.ps1`) builds ADMIN01 up to and including the
tooling it can install without a personal identity: chocolatey packages (git, gh, jq, dotnet-sdk,
VS Code, SSMS, ...), the PowerShell modules, the git identity and the public repo clones under
`C:\GitHub`. Everything below needs interactive authentication and is done once, by hand, in this
order.

Keep the repo paths exactly as the setup created them (`C:\GitHub\dbatools`,
`C:\GitHub\testing-dbatools`): the Claude memory store names are derived from these paths, so
identical paths reconnect the restored memory automatically.

## 1. GitHub identity

```powershell
gh auth login
```

Browser device-code flow. This also sets up the git credential helper, so `git push` works in all
cloned repos afterwards.

## 2. Claude memory and settings

```powershell
gh repo clone andreasjordan/claude-memory C:\GitHub\claude-memory
C:\GitHub\claude-memory\restore-memory.ps1
```

The restore brings back the memory stores and the saved Claude Code settings
(`settings.local.json` per repo, user-level settings). See the README of that repo for details.

## 3. Claude Code

```powershell
irm https://claude.ai/install.ps1 | iex
```

Then start `claude` once in `C:\GitHub\dbatools` and log in. Verify the hook environment before
relying on the gates:

```powershell
bash C:\GitHub\dbatools\.claude\hooks\hooks-doctor.sh
```

## 4. dbatools.library at the repo pin

The gallery install of dbatools brings some version of the library; the repo pins an exact one.
Install the pinned version for both PowerShell editions - the editions must not share one install
folder:

```powershell
pwsh -NoProfile -File C:\GitHub\dbatools\.github\scripts\install-dbatools-library.ps1
powershell -NoProfile -File C:\GitHub\dbatools\.github\scripts\install-dbatools-library.ps1
```

## 5. Verify

```powershell
cd C:\GitHub\testing-dbatools
. .\Initialize-LabSession.ps1
Invoke-Pester -Path .\TestEnvironment.Tests.ps1 -Output Detailed
```

A fresh Claude Code session in `C:\GitHub\dbatools` should greet with the restored memory index
loaded (MEMORY.md contents visible in its context).
