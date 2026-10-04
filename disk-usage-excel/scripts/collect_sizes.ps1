<#
.SYNOPSIS
  只读统计磁盘目录大小（第 1~4 层），输出 JSON。
.DESCRIPTION
  阶段零：权限自检。探测当前用户 AppData 等受保护目录是否可读；
          不可读说明会话为受限权限，统计必然偏小，告警并以退出码 2 中止（可用 -Force 强制继续）。
  阶段一：统计 Root 下第一层、第二层文件夹的递归大小。
  阶段二：取第一层中占比最大的前 TopN 个文件夹，统计其第三层、第四层。
  全程仅读取，不写入/删除任何被统计目录中的内容。
.PARAMETER Root
  统计根目录，默认 C:\（本机系统盘盘符，可改为其他盘或目录）。
.PARAMETER OutJson
  JSON 输出路径。省略时由脚本动态推导：优先 $env:DISK_USAGE_OUT_DIR，
  否则取当前工作目录；若该目录位于被统计的盘内，会自动改写到 $env:TEMP。
.PARAMETER TopN
  深度分析的第一层文件夹个数，默认 2。
.PARAMETER Force
  跳过权限自检强制执行（用户已确认接受不完整结果时使用）。
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File collect_sizes.ps1 -Root 'C:\' -OutJson 'C:\tmp\disk_sizes.json'
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File collect_sizes.ps1 -Root 'D:\' -OutJson 'E:\workspace\out\disk_sizes.json'
#>
param(
    [string]$Root = 'C:\',
    [string]$OutJson,
    [int]$TopN = 2,
    [switch]$Force
)

$ErrorActionPreference = 'SilentlyContinue'

# ---- 输出路径动态解析（不写死任何个人工作区路径） ----
function Get-StatDrive {
    param([string]$StatRoot)
    if (-not $StatRoot) { return '' }
    $full = $StatRoot
    try { $full = [IO.Path]::GetFullPath($StatRoot) } catch { }
    if ($full.Length -lt 2 -or $full[1] -ne ':') { return '' }
    return ([string]$full[0]).ToUpperInvariant()
}

# 目标路径是否落在被统计目录内部（含目录自身）
function Test-PathUnderRoot {
    param([string]$Path, [string]$Root)
    if (-not $Path -or -not $Root) { return $false }
    $pFull = $Path; try { $pFull = [IO.Path]::GetFullPath($Path) } catch { }
    $rFull = $Root; try { $rFull = [IO.Path]::GetFullPath($Root) } catch { }
    if (-not $rFull.EndsWith('\') -and -not $rFull.EndsWith('/')) { $rFull += '\' }
    return $pFull.StartsWith($rFull, [StringComparison]::OrdinalIgnoreCase)
}

# 目录可写 = 不在被统计盘 + 目录存在 + 真实写探测通过
function Test-WritableDir {
    param([string]$Dir, [string]$StatDrive)
    if (-not $Dir) { return $false }
    $full = $Dir
    try { $full = [IO.Path]::GetFullPath($Dir) } catch { }
    if ($full.Length -eq 0) { return $false }
    if ($StatDrive -and $full.Substring(0, 1).ToUpper() -eq $StatDrive) { return $false }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { return $false }
    $probe = Join-Path $full ('.du_probe_' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        New-Item -ItemType File -Path $probe -Force -ErrorAction Stop | Out-Null
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    } catch { return $false }
}

# 优先级：显式 -OutJson > $env:DISK_USAGE_OUT_DIR > 当前工作目录 > $env:TEMP
function Resolve-OutputPath {
    param([string]$Explicit, [string]$StatRoot)
    if ($Explicit) { return $Explicit }
    $statDrive = Get-StatDrive $StatRoot
    $candidates = @()
    if ($env:DISK_USAGE_OUT_DIR) { $candidates += (Join-Path $env:DISK_USAGE_OUT_DIR 'disk_sizes.json') }
    $candidates += (Join-Path (Get-Location).Path 'disk_sizes.json')
    $candidates += (Join-Path $env:TEMP 'disk_sizes.json')
    foreach ($cand in $candidates) {
        $dir = Split-Path -Parent $cand
        if (-not $dir) { $dir = (Get-Location).Path }
        if (Test-WritableDir $dir $statDrive) { return $cand }
    }
    return (Join-Path $env:TEMP 'disk_sizes.json')
}

if (-not $OutJson) { $OutJson = Resolve-OutputPath -Explicit $OutJson -StatRoot $Root }
Write-Host "JSON 输出路径: $OutJson"

# 仅当 Root 不是磁盘根时才做包含判断：统计 C:\ 时任何 C 盘路径都在其下，
# 那属于统计范围而非"写入被统计目录"，不应告警。
$rootIsDriveRoot = ($Root -match '^[A-Za-z]:\\?$')
if (-not $rootIsDriveRoot -and (Test-PathUnderRoot -Path $OutJson -Root $Root)) {
    Write-Host "警告：JSON 输出路径位于被统计目录 $Root 之内，与只读约束冲突，请改用其他位置的路径。"
}

# 判定分两级，避免误伤：
#   硬失败（拦截）= 读不到 1 个文件 / 目录不存在 —— 沙箱白名单拒绝对应的典型表现
#   软告警（放行）= 读到少量文件但不足阈值 —— 真实桌面本来就可能只有十几个文件
$ProbeMinFiles = 200
$probeTargets = @(
    (Join-Path $env:USERPROFILE 'AppData\Local'),
    (Join-Path $env:USERPROFILE 'Documents'),
    (Join-Path $env:USERPROFILE 'Desktop'),
    (Join-Path $env:USERPROFILE 'Downloads')
)
$statDriveLetter = Get-StatDrive $Root
if ($statDriveLetter) {
    $probeTargets += "${statDriveLetter}:\Users"
    $probeTargets += "${statDriveLetter}:\Windows"
}

$probeResults = @()
foreach ($tp in ($probeTargets | Select-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $tp -PathType Container)) {
        $probeResults += [PSCustomObject]@{ Path = $tp; Files = -1; Ok = $false; Hard = $true }
        continue
    }
    $cnt = @(Get-ChildItem -LiteralPath $tp -Recurse -File -Force -ErrorAction SilentlyContinue |
        Select-Object -First $ProbeMinFiles).Count
    $probeResults += [PSCustomObject]@{ Path = $tp; Files = $cnt; Ok = ($cnt -ge $ProbeMinFiles); Hard = ($cnt -lt 1) }
}

foreach ($r in $probeResults) {
    if ($r.Ok) { $mark = 'OK' } elseif ($r.Hard) { $mark = 'BLOCKED' } else { $mark = 'LOW' }
    Write-Host "  权限探测 [$mark] $($r.Path) -> $($r.Files) 个文件"
}

$blockedProbes = @($probeResults | Where-Object { -not $_.Ok -and $_.Hard })
$lowProbes = @($probeResults | Where-Object { -not $_.Ok -and -not $_.Hard })
if ($lowProbes.Count -gt 0) {
    foreach ($lp in $lowProbes) { Write-Host "提示：$($lp.Path) 仅 $($lp.Files) 个文件（低于阈值 $ProbeMinFiles），若确为小目录可忽略。" }
}
if (-not $Force -and $blockedProbes.Count -gt 0) {
    Write-Host ""
    Write-Host "权限自检失败：$($blockedProbes.Count)/$($probeResults.Count) 个探测点完全不可读"
    foreach ($bp in $blockedProbes) {
        $reason = if ($bp.Files -lt 0) { '目录不存在' } else { '读不到任何文件' }
        Write-Host "  - $($bp.Path)：$reason"
    }
    Write-Host "当前会话为受限权限，上述目录统计会严重偏小甚至为 0，结果不可用。"
    Write-Host "请向用户申请完全访问权限（unrestricted file system）后重试；"
    Write-Host "如用户已确认接受不完整结果，加 -Force 强制执行。"
    exit 2
}
if ($Force -and $blockedProbes.Count -gt 0) {
    Write-Host "警告：-Force 已指定，忽略 $($blockedProbes.Count) 个不可读探测点，统计结果将不完整。"
}
Write-Host "权限自检通过：$($probeResults.Count) 个探测点无完全不可读项"

function Get-DirSize {
    param([string]$Path)
    $files = Get-ChildItem -Path $Path -Recurse -File -Force -ErrorAction SilentlyContinue
    $sum = ($files | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { $sum = 0 }
    return [PSCustomObject]@{
        Path      = $Path
        SizeGB    = [math]::Round($sum / 1GB, 2)
        FileCount = $files.Count
    }
}

function Get-SubDirSizes {
    param([string]$Path)
    $result = @()
    Get-ChildItem -Path $Path -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
        ForEach-Object { $result += Get-DirSize $_.FullName }
    return $result | Sort-Object SizeGB -Descending
}

Write-Host "[1/2] 统计第一层、第二层: $Root"
$level1 = @(Get-SubDirSizes $Root)

$level2 = @()
foreach ($d in $level1) {
    Write-Host "  进入 $($d.Path)"
    $level2 += @(Get-SubDirSizes $d.Path)
}
$level2 = @($level2 | Sort-Object SizeGB -Descending)

Write-Host "[2/2] 深度分析前 $TopN 个文件夹（第三层、第四层）"
$deep = @()
$tops = @($level1 | Select-Object -First $TopN)
foreach ($top in $tops) {
    Write-Host "  深入 $($top.Path)"
    $level3 = @(Get-SubDirSizes $top.Path)
    $level4 = @()
    foreach ($d3 in $level3) {
        Write-Host "    进入 $($d3.Path)"
        $level4 += @(Get-SubDirSizes $d3.Path)
    }
    $deep += [PSCustomObject]@{
        TopPath = $top.Path
        Level3  = $level3
        Level4  = @($level4 | Sort-Object SizeGB -Descending)
    }
}

# ---- 阶段三：与磁盘真实占用交叉验证 ----
# 权限退化时脚本仍可能"成功"退出，但统计值远小于真实占用。
# 用 Win32_LogicalDisk 取 Root 所在盘真实已用容量做基准，偏差过大直接判定结果不可用。
$totalGB = [math]::Round((($level1 | Measure-Object -Property SizeGB -Sum).Sum), 2)
$validation = [PSCustomObject]@{
    Checked          = $false
    Level1TotalGB    = $totalGB
    DiskUsedGB       = $null
    CoveragePct      = $null
    Verdict          = 'unknown'
    Note             = ''
}

$statDrive = Get-StatDrive $Root
if ($statDrive) {
    try {
        $drv = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($statDrive):'" -ErrorAction Stop
        if ($drv -and $drv.Size -gt 0) {
            $usedGB = [math]::Round(($drv.Size - $drv.FreeSpace) / 1GB, 2)
            $pct = if ($usedGB -gt 0) { [math]::Round($totalGB / $usedGB * 100, 1) } else { $null }
            $validation.Checked = $true
            $validation.DiskUsedGB = $usedGB
            $validation.CoveragePct = $pct

            if ($null -ne $pct) {
                if ($pct -lt 60 -and $usedGB -gt 10) {
                    $validation.Verdict = 'suspicious-low'
                    $validation.Note = "第一层合计仅占该盘真实已用容量的 $pct%，统计结果很可能不完整"
                } elseif ($pct -gt 105) {
                    $validation.Verdict = 'suspicious-high'
                    $validation.Note = "第一层合计超出该盘真实已用容量（$pct%），可能存在重复统计或硬链接问题"
                } else {
                    $validation.Verdict = 'ok'
                }
            }
        }
    } catch {
        $validation.Note = "无法读取磁盘容量（$($_.Exception.Message)），跳过交叉验证"
    }
}

if ($validation.Checked) {
    Write-Host ""
    Write-Host "[3/3] 交叉验证：第一层合计 $([math]::Round($totalGB,2)) GB / 该盘真实已用 $($validation.DiskUsedGB) GB = $($validation.CoveragePct)%"
    if ($validation.Verdict -eq 'ok') {
        Write-Host "  覆盖率正常，统计结果可信"
    } elseif ($validation.Verdict -eq 'suspicious-low') {
        Write-Host "  数据异常：第一层合计占真实占用不足 60%，判定为权限不足导致的统计残缺。"
        Write-Host "  请勿直接使用本结果，先取得完全访问权限后重跑。"
    } elseif ($validation.Verdict -eq 'suspicious-high') {
        Write-Host "  数据异常：$($validation.Note)"
    } else {
        Write-Host "  $($validation.Note)"
    }
} elseif ($validation.Note) {
    Write-Host "[3/3] 交叉验证跳过：$($validation.Note)"
}

$report = [PSCustomObject]@{
    Root        = $Root
    GeneratedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    Level1      = $level1
    Level2      = $level2
    Deep        = $deep
    Validation  = $validation
}

$outDir = Split-Path -Parent $OutJson
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$report | ConvertTo-Json -Depth 6 | Set-Content -Path $OutJson -Encoding UTF8
Write-Host "JSON 已写入: $OutJson"
if ($validation.Verdict -eq 'suspicious-low') {
    Write-Host "警告：本次统计结果已标记为不完整（Validation.Verdict=suspicious-low），报表须显著标注。"
}
