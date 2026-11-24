# Bootstrapping ADMIN01 after a lab rebuild

The lab setup (`MyAzureLab\HyperVLab\install_TestingDbatools.ps1`) builds ADMIN01 up to and including
the tooling it can install without a personal identity: chocolatey packages (git, gh, jq, dotnet-sdk,
VS Code, SSMS, ...), the VS Code extensions, Git Bash on the PATH, the PowerShell modules, the git
identity, the public repo clones under
`C:\GitHub` and dbatools.library at the version that the dbatools repo pins, for both PowerShell
editions. Everything below needs interactive authentication and is done once, by hand, in this
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

Claude Code is used as the VS Code extension, not as the standalone app. The setup installs the
extensions `anthropic.claude-code` and `ms-vscode.powershell` and puts Git Bash
(`C:\Program Files\Git\bin`) on the machine PATH, because the hooks of the dbatools repo run `bash`.

Open VS Code and log in to Claude Code in the extension. VS Code may also offer a GitHub sign-in;
skip it, git gets its authentication from gh (step 1).

Then verify the hook environment before relying on the gates. Run it from the repo folder:
anywhere else it reports git as MISSING, because the current folder is no git repository.

```powershell
cd C:\GitHub\dbatools
bash .claude/hooks/hooks-doctor.sh
```

codex is reported as missing; the lab has no codex CLI, so the codex gate of the precommit skill
skips.

## 4. Verify

```powershell
cd C:\GitHub\testing-dbatools
. .\Initialize-LabSession.ps1
Invoke-Pester -Path .\TestEnvironment.Tests.ps1 -Output Detailed
```

A fresh Claude Code session in `C:\GitHub\dbatools` should greet with the restored memory index
loaded (MEMORY.md contents visible in its context).
