<#
.SYNOPSIS
  将工程内可再生的缓存、日志与构建目录重定向到工程外缓存根。

.DESCRIPTION
  默认缓存根为 D:\huawei\harlgram。工程内保留同名目录入口，实际内容通过
  Windows 目录联接（junction）存放在缓存根，因此 DevEco、hvigor、ohpm、
  测试与脚本仍使用原有相对路径。

  重复执行是幂等的：已指向正确目标的联接保持不动；缺失的入口会新建；
  空目录会替换为联接；非空真实目录不会被自动删除，除非使用 -Repair。

  注意：DevEco 的 clean 或重新安装依赖可能删除联接并在工程内重建真实目录。
  出现这种情况后重新运行本脚本即可修复（构建脚本也会尝试自动修复）。

.PARAMETER ProjectRoot
  工程根目录，默认是本脚本的上一级目录。

.PARAMETER CacheHome
  缓存根目录，默认 D:\huawei\harlgram。

.PARAMETER Repair
  修复模式：联接指向错误目标时删除旧联接后重建；遇到非空真实目录只警告，
  不终止。构建脚本使用该模式，避免因为尚未迁移的数据阻断构建。

.PARAMETER Quiet
  不输出逐项结果，只输出警告与错误。

.PARAMETER MigrateUserHome
  把 %USERPROFILE%\.hvigor 复制到缓存根的 user-home（源目录保留）。
  scripts/env.sh 会导出 HVIGOR_USER_HOME 指向该位置，只影响本仓库脚本。

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\cache-layout.ps1

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\cache-layout.ps1 -MigrateUserHome

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\cache-layout.ps1 -CacheHome 'D:\huawei\harlgram' -Repair
#>
[CmdletBinding()]
param(
  [string]$ProjectRoot = '',
  [string]$CacheHome = 'D:\huawei\harlgram',
  [switch]$Repair,
  [switch]$Quiet,
  [switch]$MigrateUserHome
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
  $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
if ([string]::IsNullOrWhiteSpace($CacheHome)) {
  throw '缓存根不能为空。'
}

$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/')
$CacheHome = [System.IO.Path]::GetFullPath($CacheHome).TrimEnd('\', '/')

# 工程内入口 -> 缓存根下的实际目录
$layout = [ordered]@{
  '.local'        = 'local'
  'artifacts'     = 'artifacts'
  '.hvigor'       = 'project-cache'
  '.appanalyzer'  = 'appanalyzer'
  'entry\build'   = 'build'
  'entry\.cxx'    = 'cxx'
  'entry\.preview' = 'preview'
  'entry\.test'   = 'test'
  'oh_modules'    = 'oh_modules'
  'node_modules'  = 'node_modules'
}

function Write-Step {
  param([string]$Message)
  if (-not $Quiet) { Write-Host $Message }
}

function Get-ExistingItem {
  param([string]$Path)
  return Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}

function Test-ReparsePoint {
  param($Item)
  if ($null -eq $Item) { return $false }
  return [bool]($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

function Get-ReparseTarget {
  param($Item)
  $target = $Item.Target
  if ($target -is [array]) { $target = $target[0] }
  if ([string]::IsNullOrWhiteSpace($target)) { return '' }
  return [System.IO.Path]::GetFullPath([string]$target).TrimEnd('\', '/')
}

New-Item -ItemType Directory -Path $CacheHome -Force | Out-Null

if ($MigrateUserHome) {
  $userSource = Join-Path $env:USERPROFILE '.hvigor'
  $userTarget = Join-Path $CacheHome 'user-home'
  New-Item -ItemType Directory -Path $userTarget -Force | Out-Null
  if (Test-Path -LiteralPath $userSource) {
    # robocopy 处理超过 MAX_PATH 的 hvigor 依赖路径，Copy-Item 会在长路径处失败。
    $robocopy = Get-Command robocopy.exe -ErrorAction SilentlyContinue
    if ($null -eq $robocopy) { throw '找不到 robocopy.exe，无法迁移用户级 hvigor 缓存。' }
    $arguments = @($userSource, $userTarget, '/E', '/COPY:DAT', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS')
    $process = Start-Process -FilePath $robocopy.Source -ArgumentList $arguments -Wait -PassThru -NoNewWindow
    if ($process.ExitCode -ge 8) {
      throw "robocopy 迁移用户级 hvigor 缓存失败，退出码 $($process.ExitCode)。"
    }
    Write-Step "已复制用户级 hvigor 缓存：$userSource -> $userTarget（源目录保留）"
  } else {
    Write-Step "用户级 hvigor 缓存不存在，跳过：$userSource"
  }
}

$hadError = $false
foreach ($entry in $layout.GetEnumerator()) {
  $linkPath = Join-Path $ProjectRoot $entry.Key
  $targetPath = Join-Path $CacheHome $entry.Value
  New-Item -ItemType Directory -Path $targetPath -Force | Out-Null

  $existing = Get-ExistingItem -Path $linkPath
  if ($null -eq $existing) {
    New-Item -ItemType Junction -Path $linkPath -Target $targetPath | Out-Null
    Write-Step "[新建] $($entry.Key) -> $targetPath"
    continue
  }

  if (Test-ReparsePoint -Item $existing) {
    $current = Get-ReparseTarget -Item $existing
    if ($current -eq $targetPath) {
      Write-Step "[保持] $($entry.Key) -> $targetPath"
      continue
    }
    if (-not $Repair) {
      throw "$($entry.Key) 已是指向 $current 的联接，与目标 $targetPath 不一致。确认后使用 -Repair 重建。"
    }
    Remove-Item -LiteralPath $linkPath -Force
    New-Item -ItemType Junction -Path $linkPath -Target $targetPath | Out-Null
    Write-Step "[重建] $($entry.Key) -> $targetPath（原目标 $current 未改动）"
    continue
  }

  $children = @(Get-ChildItem -LiteralPath $linkPath -Force -ErrorAction SilentlyContinue)
  if ($children.Count -eq 0) {
    Remove-Item -LiteralPath $linkPath -Force
    New-Item -ItemType Junction -Path $linkPath -Target $targetPath | Out-Null
    Write-Step "[替换空目录] $($entry.Key) -> $targetPath"
    continue
  }

  if ($Repair) {
    Write-Warning "$($entry.Key) 是真实目录且非空，未重定向。请先迁移到 $targetPath，删除该目录后重跑本脚本。"
    continue
  }

  $hadError = $true
  Write-Error "$($entry.Key) 是真实目录且非空，未自动删除。请先把它迁移到 $targetPath，删除工程内目录后重跑本脚本。" -ErrorAction Continue
}

if ($hadError) { exit 1 }
Write-Step "缓存根：$CacheHome"
Write-Step '缓存目录布局检查完成。'