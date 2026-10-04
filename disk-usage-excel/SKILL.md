---
name: disk-usage-excel
description: 统计本地磁盘（默认 C 盘）文件夹大小并生成 Excel 报表。第零步权限自检，没有完全访问权限则主动申请用户授权；第一步统计第一层和第二层文件夹的递归大小；第二步仅对占比前 2 的文件夹统计第三层和第四层；第三步生成带样式的 Excel。当用户要求统计磁盘/文件夹占用空间、分析 C 盘空间、生成磁盘空间 Excel 报表时使用。全程仅读取，严禁对被统计磁盘做任何写入、编辑、删除操作。
---

# 磁盘占用统计 Excel

## 硬性约束

- 全程只读：禁止对被统计磁盘执行任何写入、移动、删除、清理操作。
- JSON 和 Excel 一律输出到工作区目录，绝不写入被统计的磁盘（默认 C 盘）。

## 第零步：权限自检（必须先做）

执行 `scripts/collect_sizes.ps1` 前确认会话拥有完全访问权限（unrestricted file system）。脚本内置多点探测：`AppData\Local`、`Documents`、`Desktop`、`<盘符>:\Users`、`<盘符>:\Windows`，任一探测点读不到 200 个文件即以退出码 2 中止。

- 退出码 2 = 受限权限。此时主动告知用户："当前会话为受限权限，用户目录等受保护位置无法读取，统计会严重偏小。请授权完全访问权限后重试。"不要静默产出残缺报表。
- **不要因为想让脚本跑通就自行加 `-Force`。** 只有用户明确表示接受不完整结果时才加，且必须在报告中醒目标注数据不完整。
- 单点探测曾导致假通过：沙箱按路径白名单放行，`AppData\Local` 可读而 `C:\Users` 不可读，统计漏掉 75%。多点探测就是为堵这个洞，不要改回单点。

## 三步工作流

1. 统计第一层和第二层文件夹大小（`scripts/collect_sizes.ps1` 阶段一）。
2. 仅对第一层占比前 2 的文件夹，统计第三层和第四层（同脚本阶段二）。
3. 用 `scripts/gen_excel.py` 把 JSON 渲染成 Excel（JSON 中的 `Validation` 字段会被渲染成"数据完整性告警"工作表）。

## 执行命令

```powershell
# 步骤 1+2：收集（只读，扫全盘约 2~5 分钟）
# 不传 -OutJson：脚本按 DISK_USAGE_OUT_DIR -> 当前工作目录 -> TEMP 依次选一个非被统计盘的位置
powershell -ExecutionPolicy Bypass -File scripts/collect_sizes.ps1 -Root 'C:\'

# 需要指定输出位置时（务必用非被统计盘的工作区路径）
powershell -ExecutionPolicy Bypass -File scripts/collect_sizes.ps1 -Root 'C:\' -OutJson '<工作区>\disk_sizes.json'

# 步骤 3：生成 Excel（Python 需有 openpyxl；优先用 Codex 捆绑运行时，见下）
# 省略第二个参数时，Excel 与 JSON 同目录，文件名由 JSON 名 + 根盘符推导
python scripts/gen_excel.py '<工作区>\disk_sizes.json'
python scripts/gen_excel.py '<工作区>\disk_sizes.json' '<工作区>\磁盘空间统计.xlsx'
```

- 输出目录：脚本会打印实际使用的 `JSON 输出路径`，交报表时以它为准。若没给工作区且当前目录在被统计盘上，会自动落到 `$env:TEMP`。统计盘根目录（如 `C:\`）本身不会触发"写入被统计目录"告警。
- Python 解释器：先调用 `load_workspace_dependencies` 取捆绑 Python（自带 openpyxl）；不可用时退回系统 `python`，缺 openpyxl 时提示用户安装，不要自行 pip install 到被统计盘。
- PowerShell 5.1 控制台管道传中文会乱码：Python 代码一律从 .py 文件运行，不要经管道喂给 `python -`。
- 统计其他盘/目录改 `-Root`；深度分析的个数改 `-TopN`。

## 统计口径与坑点

- 跳过 junction/symlink（ReparsePoint），否则 `C:\Users\All Users`（→ ProgramData）、`C:\Documents and Settings`（→ Users）会重复统计。
- 文件夹大小 = 递归所有子孙文件 Length 之和；`-ErrorAction` 必须 `SilentlyContinue`，用 `Stop` 会在第一个无权限文件处提前终止，导致 Windows 等大目录严重偏小。
- `System Volume Information` 等系统目录即使完全权限也可能读不到，结果为 0 属正常，报表中如实呈现。
- 脚本逐目录递归，第二层合计应约等于对应第一层值；若明显偏小，先怀疑权限而非脚本。
- 脚本末尾会用 `Win32_LogicalDisk` 做交叉验证：第一层合计 / 该盘真实已用容量。低于 60% 判 `suspicious-low`，超出 105% 判 `suspicious-high`，两者都会写进 JSON 的 `Validation` 字段。**交付前必须看这个字段**：非 `ok` 就不能把报表当有效结果给用户。

## 交付

- Excel 工作表：第一层、第二层、第三层(深度分析)、第四层(深度分析)、汇总（根目录、生成时间、总大小、目录数）。
- 报告时用中文给出 Top 占用列表和分类解读（如 AI 模型、浏览器缓存、开发工具），并附 Excel 文件链接。
