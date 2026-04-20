<#
.SYNOPSIS
    从 upstream 拉取新提交并 cherry-pick 到目标分支。

.DESCRIPTION
    读取上次记录的 commit ID，将 upstream 中其后的所有新提交
    按顺序 cherry-pick 到目标分支，并将最后成功的 commit ID 写回状态文件。
    首次运行时若无状态文件，会提示手动输入起始 commit ID。

.PARAMETER UpstreamRemote
    上游远程名称，默认 upstream

.PARAMETER UpstreamBranch
    上游分支名称，默认 main

.PARAMETER TargetBranch
    cherry-pick 目标分支，默认 merge/cherry-pick-upstream

.PARAMETER StateFile
    保存最后一次 commit ID 的状态文件名（相对仓库根目录）

.PARAMETER StartCommit
    强制指定起始 commit ID（非空时覆盖状态文件记录）

.EXAMPLE
    # 首次运行 - 会提示输入起始 commit
    .\scripts\cherry-pick-upstream.ps1

.EXAMPLE
    # 强制指定起始 commit
    .\scripts\cherry-pick-upstream.ps1 -StartCommit abc1234

.EXAMPLE
    # 从 nightly 分支 cherry-pick
    .\scripts\cherry-pick-upstream.ps1 -UpstreamBranch nightly
#>

param(
    [string]$UpstreamRemote = "upstream",
    [string]$UpstreamBranch = "main",
    [string]$TargetBranch   = "merge/cherry-pick-upstream",
    [string]$StateFile      = ".cherry-pick-state",
    [string]$StartCommit    = ""
)

$ErrorActionPreference = "Continue"

# ─── 辅助输出函数 ──────────────────────────────────────────────────────────────

function Write-Info([string]$msg) {
    Write-Host "[INFO]  $msg" -ForegroundColor Cyan
}
function Write-Ok([string]$msg) {
    Write-Host "[OK]    $msg" -ForegroundColor Green
}
function Write-Warn([string]$msg) {
    Write-Host "[WARN]  $msg" -ForegroundColor Yellow
}
function Write-Fail([string]$msg) {
    Write-Host "[ERROR] $msg" -ForegroundColor Red
}

# ─── 确认在仓库根目录 ─────────────────────────────────────────────────────────

$repoRoot = (git rev-parse --show-toplevel 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) {
    Write-Fail "当前目录不在 git 仓库中，请在仓库目录下运行此脚本。"
    exit 1
}
Set-Location $repoRoot
$stateFilePath = Join-Path $repoRoot $StateFile
Write-Info "仓库根目录: $repoRoot"

# ─── 读取 / 确定起始 commit ───────────────────────────────────────────────────

if ($StartCommit -ne "") {
    Write-Info "使用命令行指定的起始 commit: $StartCommit"
    $lastCommit = $StartCommit.Trim()
}
elseif (Test-Path $stateFilePath) {
    $lastCommit = (Get-Content $stateFilePath -Raw).Trim()
    Write-Info "从状态文件读取上次 commit: $lastCommit"
}
else {
    Write-Warn "未找到状态文件 ($StateFile)，首次运行需要手动输入起始 commit ID。"
    Write-Host "cherry-pick 将从该 commit 的下一个提交开始。" -ForegroundColor Yellow
    $lastCommit = (Read-Host "请输入起始 commit ID").Trim()
    if ($lastCommit -eq "") {
        Write-Fail "未输入 commit ID，退出。"
        exit 1
    }
}

# 校验 commit 是否存在
$typeResult = (git cat-file -t $lastCommit 2>&1) -join ""
if ($LASTEXITCODE -ne 0 -or $typeResult.Trim() -ne "commit") {
    Write-Fail "无效的 commit ID: $lastCommit (git cat-file 返回: $typeResult)"
    exit 1
}
Write-Ok "起始 commit 校验通过: $lastCommit"

# ─── fetch upstream ───────────────────────────────────────────────────────────

Write-Info "正在 fetch $UpstreamRemote ..."
$fetchOut = (git fetch $UpstreamRemote 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0) {
    Write-Fail "git fetch $UpstreamRemote 失败: $fetchOut"
    exit 1
}
if ($fetchOut) { Write-Host $fetchOut }
$upstreamRef = "$UpstreamRemote/$UpstreamBranch"
Write-Ok "fetch 完成，upstream ref: $upstreamRef"

# ─── 获取待 cherry-pick 的 commit 列表 ───────────────────────────────────────

$range = "${lastCommit}..${upstreamRef}"
Write-Info "计算提交范围: $range"

$rawLog = (git log --reverse --pretty=format:"%H" $range 2>&1)
if ($LASTEXITCODE -ne 0) {
    Write-Fail "获取提交列表失败: $rawLog"
    exit 1
}

$commitList = @($rawLog | Where-Object { $_ -match "^[0-9a-f]{40}$" })

if ($commitList.Count -eq 0) {
    Write-Ok "没有新的提交需要 cherry-pick，已是最新。"
    exit 0
}

Write-Info "共找到 $($commitList.Count) 个新提交，目标分支: $TargetBranch"

# 预览提交列表（最多显示 8 条）
$previewLines = git log --reverse --oneline $range 2>&1 | Select-Object -First 8
foreach ($line in $previewLines) {
    Write-Host "    $line" -ForegroundColor DarkCyan
}
if ($commitList.Count -gt 8) {
    Write-Host "    ... 以及另外 $($commitList.Count - 8) 个提交" -ForegroundColor DarkCyan
}

# ─── 切换到目标分支 ───────────────────────────────────────────────────────────

$currentBranch = (git rev-parse --abbrev-ref HEAD 2>&1 | Out-String).Trim()
if ($currentBranch -ne $TargetBranch) {
    Write-Info "切换分支: $currentBranch -> $TargetBranch"
    git checkout $TargetBranch 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "切换到分支 $TargetBranch 失败"
        exit 1
    }
}
Write-Ok "当前分支: $TargetBranch"

# ─── 逐个 cherry-pick ────────────────────────────────────────────────────────

$successCount   = 0
$lastGoodCommit = $lastCommit

foreach ($sha in $commitList) {
    $subject = (git log -1 --pretty=format:"%s" $sha 2>&1 | Out-String).Trim()
    $idx     = $successCount + 1
    Write-Info "[$idx/$($commitList.Count)] cherry-pick $sha"
    Write-Host "         $subject" -ForegroundColor DarkGray

    $cpOut = (git cherry-pick $sha 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "cherry-pick 失败: $sha"
        Write-Host $cpOut -ForegroundColor DarkRed

        # 中止以恢复干净状态
        git cherry-pick --abort 2>&1 | Out-Null

        if ($successCount -gt 0) {
            Write-Warn "已成功处理 $successCount 个提交，在此处遇到冲突。"
            Write-Warn "上次成功的 commit: $lastGoodCommit"
        }

        # 保存进度
        Set-Content -Path $stateFilePath -Value $lastGoodCommit -NoNewline
        Write-Info "状态文件已更新至: $lastGoodCommit"
        Write-Warn "请手动解决冲突后重新运行脚本继续。"
        exit 1
    }

    $lastGoodCommit = $sha
    $successCount++
    Write-Ok "    OK  $sha"
}

# ─── 保存最后 commit ID ───────────────────────────────────────────────────────

Set-Content -Path $stateFilePath -Value $lastGoodCommit -NoNewline

Write-Ok "========================================================"
Write-Ok "全部完成！cherry-pick 了 $successCount 个提交。"
Write-Ok "最后 commit: $lastGoodCommit"
Write-Ok "状态文件:   $stateFilePath"
Write-Ok "========================================================"
