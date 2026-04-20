<#
.SYNOPSIS
    Cherry-pick new upstream commits onto the target branch.

.DESCRIPTION
    Reads the last recorded upstream commit ID from a state file, fetches
    all newer commits from the upstream remote, and cherry-picks them one
    by one onto the target branch.  On conflict, the upstream (theirs)
    version is accepted automatically.  The state file is updated after
    every successful cherry-pick.

    On first run (no state file) you will be prompted to enter the
    starting commit ID manually, or pass -StartCommit on the command line.

    IMPORTANT: The starting commit ID must be a commit that exists on the
    upstream branch (e.g. upstream/main), NOT a locally cherry-picked SHA.
    Using a local SHA will cause git to think all upstream history is new
    and will try to cherry-pick thousands of old commits.

.PARAMETER UpstreamRemote
    Name of the upstream git remote.  Default: upstream

.PARAMETER UpstreamBranch
    Branch on the upstream remote to pull from.  Default: main

.PARAMETER TargetBranch
    Local branch to cherry-pick commits onto.  Default: merge/cherry-pick-upstream

.PARAMETER StateFile
    Path (relative to repo root) of the file that stores the last processed
    upstream commit ID.  Default: scripts/.cherry-pick-state

.PARAMETER StartCommit
    Force a specific starting commit ID (overrides the state file).
    Must be a commit that is reachable from upstream/<UpstreamBranch>.

.EXAMPLE
    # First run - will prompt for the starting upstream commit
    .\scripts\cherry-pick-upstream.ps1

.EXAMPLE
    # Force a specific starting commit
    .\scripts\cherry-pick-upstream.ps1 -StartCommit <upstream-sha>

.EXAMPLE
    # Cherry-pick from the nightly branch
    .\scripts\cherry-pick-upstream.ps1 -UpstreamBranch nightly
#>

param(
    [string]$UpstreamRemote = "upstream",
    [string]$UpstreamBranch = "main",
    [string]$TargetBranch   = "merge/cherry-pick-upstream",
    [string]$StateFile      = "scripts/.cherry-pick-state",
    [string]$StartCommit    = ""
)

$ErrorActionPreference = "Continue"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Info([string]$msg)  { Write-Host "[INFO]  $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg)    { Write-Host "[OK]    $msg" -ForegroundColor Green }
function Write-Warn([string]$msg)  { Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Write-Fail([string]$msg)  { Write-Host "[ERROR] $msg" -ForegroundColor Red }

# ---------------------------------------------------------------------------
# Locate repo root
# ---------------------------------------------------------------------------

$repoRoot = (git rev-parse --show-toplevel 2>&1) -join ""
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Not inside a git repository. Please run this script from within the repo."
    exit 1
}
Set-Location $repoRoot
$stateFilePath = Join-Path $repoRoot $StateFile
Write-Info "Repo root : $repoRoot"

# ---------------------------------------------------------------------------
# Resolve the starting commit
# ---------------------------------------------------------------------------

if ($StartCommit -ne "") {
    Write-Info "Using commit supplied via -StartCommit: $StartCommit"
    $lastCommit = $StartCommit.Trim()
}
elseif (Test-Path $stateFilePath) {
    $lastCommit = (Get-Content $stateFilePath -Raw).Trim()
    Write-Info "Loaded last commit from state file: $lastCommit"
}
else {
    Write-Warn "State file not found ($StateFile). First run - please provide the starting commit."
    Write-Host "Cherry-pick will begin from the commit AFTER the one you enter." -ForegroundColor Yellow
    $lastCommit = (Read-Host "Enter starting upstream commit ID").Trim()
    if ($lastCommit -eq "") {
        Write-Fail "No commit ID entered. Exiting."
        exit 1
    }
}

# Validate commit exists locally
$typeResult = (git cat-file -t $lastCommit 2>&1) -join ""
if ($LASTEXITCODE -ne 0 -or $typeResult.Trim() -ne "commit") {
    Write-Fail "Invalid commit ID: $lastCommit"
    Write-Host "  git cat-file returned: $typeResult" -ForegroundColor DarkRed
    exit 1
}
Write-Ok "Commit ID validated: $lastCommit"

# ---------------------------------------------------------------------------
# Fetch upstream
# ---------------------------------------------------------------------------

Write-Info "Fetching $UpstreamRemote ..."
$fetchOut = (git fetch $UpstreamRemote 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0) {
    Write-Fail "git fetch $UpstreamRemote failed: $fetchOut"
    exit 1
}
if ($fetchOut) { Write-Host $fetchOut }
$upstreamRef = "$UpstreamRemote/$UpstreamBranch"
Write-Ok "Fetch complete. Upstream ref: $upstreamRef"

# ---------------------------------------------------------------------------
# Verify the starting commit is an ancestor of the upstream ref
#
# This is the most common mistake: passing a locally cherry-picked SHA
# instead of the original upstream SHA.  If $lastCommit is not in the
# upstream graph then "$lastCommit..$upstreamRef" includes ALL upstream
# history, causing thousands of old commits to be replayed.
# ---------------------------------------------------------------------------

git merge-base --is-ancestor $lastCommit $upstreamRef 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Starting commit [$lastCommit] is NOT an ancestor of $upstreamRef !"
    Write-Host ""
    Write-Host "  Most likely cause: you provided a locally cherry-picked SHA." -ForegroundColor Yellow
    Write-Host "  The state file must always contain an UPSTREAM commit SHA." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Find the correct SHA with:" -ForegroundColor Cyan
    Write-Host "    git log --oneline $upstreamRef | head -20" -ForegroundColor Cyan
    Write-Host "  Then re-run:" -ForegroundColor Cyan
    Write-Host "    .\scripts\cherry-pick-upstream.ps1 -StartCommit <upstream-sha>" -ForegroundColor Cyan
    exit 1
}
Write-Ok "Starting commit is a valid ancestor of $upstreamRef."

# ---------------------------------------------------------------------------
# Build the list of commits to cherry-pick
# ---------------------------------------------------------------------------

$range = "${lastCommit}..${upstreamRef}"
Write-Info "Commit range: $range"

$rawLog = (git log --reverse --pretty=format:"%H" $range 2>&1)
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Failed to list commits: $rawLog"
    exit 1
}

$commitList = @($rawLog | Where-Object { $_ -match "^[0-9a-f]{40}$" })

if ($commitList.Count -eq 0) {
    Write-Ok "Nothing to cherry-pick - already up to date."
    exit 0
}

Write-Info "Found $($commitList.Count) new commit(s) to cherry-pick onto $TargetBranch"

# Preview (up to 8 lines)
$previewLines = git log --reverse --oneline $range 2>&1 | Select-Object -First 8
foreach ($line in $previewLines) { Write-Host "    $line" -ForegroundColor DarkCyan }
if ($commitList.Count -gt 8) {
    Write-Host "    ... and $($commitList.Count - 8) more" -ForegroundColor DarkCyan
}

# ---------------------------------------------------------------------------
# Switch to the target branch
# ---------------------------------------------------------------------------

$currentBranch = (git rev-parse --abbrev-ref HEAD 2>&1) -join ""
if ($currentBranch.Trim() -ne $TargetBranch) {
    Write-Info "Switching branch: $currentBranch -> $TargetBranch"
    git checkout $TargetBranch 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Failed to checkout $TargetBranch"
        exit 1
    }
}
Write-Ok "On branch: $TargetBranch"

# ---------------------------------------------------------------------------
# Cherry-pick loop
# ---------------------------------------------------------------------------

$successCount   = 0
$lastGoodCommit = $lastCommit

foreach ($sha in $commitList) {
    $subject    = (git log -1 --pretty=format:"%s" $sha 2>&1) -join ""
    $parentCount = ((git log -1 --pretty=format:"%P" $sha 2>&1) -join "" -split "\s+" |
                    Where-Object { $_ -match "\S" }).Count
    $isMerge    = $parentCount -gt 1
    $idx        = $successCount + 1
    Write-Info "[$idx/$($commitList.Count)] $sha$(if ($isMerge) { ' [merge]' })"
    Write-Host "         $subject" -ForegroundColor DarkGray

    # Merge commits require -m 1 to specify the mainline parent
    if ($isMerge) {
        git cherry-pick -m 1 $sha 2>&1 | Out-Null
    } else {
        git cherry-pick $sha 2>&1 | Out-Null
    }

    if ($LASTEXITCODE -ne 0) {

        # Check whether this is a conflict or some other failure
        $conflicted = @(git diff --name-only --diff-filter=U 2>&1 |
                        Where-Object { $_ -match "\S" })

        if ($conflicted.Count -eq 0) {
            # No conflict files - unrecoverable error
            git cherry-pick --abort 2>&1 | Out-Null
            Write-Fail "cherry-pick failed (non-conflict error): $sha"
            Set-Content -Path $stateFilePath -Value $lastGoodCommit -NoNewline
            Write-Info "State file saved at: $lastGoodCommit"
            exit 1
        }

        # Conflict: accept upstream (theirs) for every conflicted file
        Write-Warn "    Conflict detected - auto-resolving with upstream version (theirs)..."
        foreach ($f in $conflicted) {
            git checkout --theirs -- $f 2>&1 | Out-Null
            git add          -- $f 2>&1 | Out-Null
            Write-Host "        [theirs] $f" -ForegroundColor DarkYellow
        }

        # Stage any remaining unmerged paths (e.g. added/deleted conflicts)
        git add -A 2>&1 | Out-Null

        # Continue cherry-pick without opening an editor
        $env:GIT_EDITOR = "true"
        git cherry-pick --continue 2>&1 | Out-Null
        $env:GIT_EDITOR = ""

        if ($LASTEXITCODE -ne 0) {
            Write-Fail "cherry-pick --continue failed: $sha"
            git cherry-pick --abort 2>&1 | Out-Null
            Set-Content -Path $stateFilePath -Value $lastGoodCommit -NoNewline
            Write-Info "State file saved at: $lastGoodCommit"
            exit 1
        }
        Write-Warn "    Conflict auto-resolved (upstream version kept)."
    }

    $lastGoodCommit = $sha
    $successCount++
    Write-Ok "    done  $sha"
}

# ---------------------------------------------------------------------------
# Save final state
# ---------------------------------------------------------------------------

Set-Content -Path $stateFilePath -Value $lastGoodCommit -NoNewline

Write-Ok "========================================================"
Write-Ok "Finished!  $successCount commit(s) cherry-picked."
Write-Ok "Last commit : $lastGoodCommit"
Write-Ok "State file  : $stateFilePath"
Write-Ok "========================================================"
