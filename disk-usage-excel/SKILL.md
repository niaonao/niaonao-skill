---
name: disk-usage-excel
description: 统计本地磁盘（默认 C 盘）文件夹大小并生成 Excel 报表。第零步权限自检，没有完全访问权限则主动申请用户授权；第一步统计第一层和第二层文件夹的递归大小；第二步仅对占比前 2 的文件夹统计第三层至第六层，每个父目录仅保留大小前 10 的子目录；第三步生成带样式的 Excel。当用户要求统计磁盘/文件夹占用空间、分析 C 盘空间、生成磁盘空间 Excel 报表时使用。全程仅读取，严禁对被统计磁盘做任何写入、编辑、删除操作。
---

# 磁盘占用统计 Excel

## 硬性约束

- 全程只读：禁止对被统计磁盘执行任何写入、移动、删除、清理操作。
- JSON 和 Excel 一律输出到工作区目录，绝不写入被统计的磁盘（默认 C 盘）。

## 第零步：权限自检（必须先做）

执行 `scripts/collect_sizes.ps1` 前确认会话拥有完整文件读取权限；受限会话通过平台的权限申请机制运行。脚本内置多点探测：当前用户的 `AppData\Local`、`Documents`、`Desktop`、`Downloads`，以及 `<盘符>:\Users`、`<盘符>:\Windows`。每点最多读取 200 个文件：达到 200 标为 `OK`，读到 1–199 个标为 `LOW` 并提示，目录不存在或完全读不到文件标为 `BLOCKED`。存在 `BLOCKED` 时以退出码 2 中止；`LOW` 不会单独阻止扫描。

- 退出码 2 表示权限自检未通过，不一定是沙箱限制，也可能是探测目录不存在或为空。先核对脚本列出的失败路径和原因；确认为权限问题时，通过平台申请完整读取权限后重试。不要静默产出残缺报表。
- **不要因为想让脚本跑通就自行加 `-Force`。** 只有用户明确表示接受不完整结果时才加，且必须在报告中醒目标注数据不完整。
- 单点探测曾导致假通过：沙箱按路径白名单放行，`AppData\Local` 可读而 `C:\Users` 不可读，统计漏掉 75%。多点探测就是为堵这个洞，不要改回单点。

## 三步工作流

1. 递归收集全部文件夹大小，第一层保留 Top10；对保留的第一层目录，分别展示其第二层子目录 Top10（`scripts/collect_sizes.ps1` 阶段一）。
2. 仅对第一层占比前 2 的文件夹，统计第三层至第六层，每个父目录仅保留大小前 10 的子目录（同脚本阶段二）。
3. 用 `scripts/gen_excel.py` 把 JSON 渲染成 Excel（`Validation.Verdict` 为 `suspicious-low` 或 `suspicious-high` 时新增"数据完整性告警"工作表；`unknown` 需在交付说明中明确标注尚未通过完整性校验）。

## 执行命令

```powershell
# 在 Skill 目录中执行；输出工作区必须位于非被统计盘。
# 示例：统计 C 盘，输出到 E 盘；请按本机实际盘符替换。
New-Item -ItemType Directory -Path 'E:\disk-reports' -Force | Out-Null
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/collect_sizes.ps1 -Root 'C:\' -OutJson 'E:\disk-reports\disk_sizes.json'

# 步骤 3：生成 Excel（Python 需有 openpyxl；优先用 Codex 捆绑运行时，见下）
# 省略第二个参数时，Excel 与 JSON 同目录，文件名由 JSON 名 + 根盘符推导
python scripts/gen_excel.py 'E:\disk-reports\disk_sizes.json'
python scripts/gen_excel.py 'E:\disk-reports\disk_sizes.json' 'E:\disk-reports\磁盘空间统计.xlsx'
```

- 输出目录：优先显式指定 `-OutJson`，执行前确认 JSON 和 Excel 都在非被统计盘。脚本会打印实际 `JSON 输出路径`。自动选择顺序为 `DISK_USAGE_OUT_DIR` → 当前目录 → `TEMP`，但所有候选都不可用时仍会回退到 `TEMP`；显式路径也不会被强制拦截。因此不能把自动选择或无告警视为满足只读约束。没有合适的非统计盘输出位置时先确定输出位置，不直接运行扫描。
- Python 解释器：先调用 `load_workspace_dependencies` 取捆绑 Python（自带 openpyxl）；不可用时退回系统 `python`，缺 openpyxl 时提示用户安装，不要自行 pip install 到被统计盘。
- PowerShell 5.1 控制台管道传中文会乱码：Python 代码一律从 .py 文件运行，不要经管道喂给 `python -`。
- 统计其他盘/目录改 `-Root`；深度分析的个数改 `-TopN`。

## 统计口径与坑点

- 跳过 junction/symlink（ReparsePoint），否则 `C:\Users\All Users`（→ ProgramData）、`C:\Documents and Settings`（→ Users）会重复统计。
- 文件夹大小 = 递归所有子孙文件 Length 之和；`-ErrorAction` 必须 `SilentlyContinue`，用 `Stop` 会在第一个无权限文件处提前终止，导致 Windows 等大目录严重偏小。
- `System Volume Information` 等系统目录即使完全权限也可能读不到，结果为 0 属正常，报表中如实呈现。
- 各层按每个父目录分别筛选 Top10，沿保留目录继续展开；第一层 TopN（默认 2）展开至第六层。层数相对于 Root，Root 本身为第零层。TopN 取值 1–10。
- 排名使用未舍入的 SizeBytes，大小相同按路径排序。父目录包含全部子孙文件，实际大小大于等于直接子目录 Top10 的大小合计；GB 四舍五入后可能出现显示合计误差，应核对 Excel 的实际大小(Bytes)列。
- 单次递归扫描缓存大小，所有深度复用同一次扫描结果；递归所有层级都跳过 ReparsePoint。Top10 限制的是展示和展开范围，不会将父目录大小截断为 Top10 合计。
- 汇总和覆盖率使用筛选前第一层全量总大小，不能对展示的 Top10 求和代替；JSON 保存 Level1TotalBytes 和 Level1FolderCount。
- GB 列按 `1 GB = 1024³ Bytes` 换算。统计的是文件逻辑长度，未包含 Root 下直接文件，不等同于文件系统实际分配空间；硬链接、压缩等也可能造成差异。
- 脚本末尾会用 `Win32_LogicalDisk` 做交叉验证：第一层全量合计 / 该盘真实已用容量。覆盖率低于 60% 且已用容量大于 10 GB 时判 `suspicious-low`，超出 105% 判 `suspicious-high`。**交付前必须看 `Validation`**：非 `ok` 要说明原因与限制，不当作完整有效结果。此校验适用于整盘；`-Root` 指向子目录时，脚本仍与所在整盘比较，不能据此认定目录扫描不完整。

## 交付

- Excel 工作表：第一层、第二层、第三层至第六层(深度分析)、汇总（根目录、生成时间、总大小、目录数）。
- 报告时用中文给出 Top 占用列表和分类解读（如 AI 模型、浏览器缓存、开发工具），并附 Excel 文件链接。
- 交付前逐父目录检查子目录数不超过 10、层级相对 Root 正确，以及父目录 `SizeBytes` 大于等于直接子目录 Top10 的字节合计。检查 Excel 行数与 JSON 一致；旧版 JSON 可生成报表，但缺失字节字段时对应列为空。
