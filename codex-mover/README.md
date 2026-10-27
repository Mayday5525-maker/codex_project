# Dev Mover v1.1

便携版 Windows 工具 / Portable Windows tool

将 **OpenAI Codex、TRAE CN、WorkBuddy、VS Code、Claude Code** 的数据及选定工作区迁移到另一块本机 NTFS 固定磁盘。原路径保留为 directory junction，应用继续通过原路径访问数据。

## 启动和使用

下载完整的 `codex-mover/` 文件夹，解压后双击 **`AssistantMover-GUI.cmd`**。不要只下载单个启动器或脚本。

界面采用 Dev Mover 布局：浅灰背景、白色圆角设置卡片、紫蓝渐变主按钮、右侧操作区和底部日志。

1. 勾选需要迁移的目录。不在本机的目录禁用；已有联接显示 `[已迁移(联接)]` 并默认取消勾选，悬停可查看联接目标。
2. 自定义工作区可粘贴完整目录路径后点击“添加自定义目录”；留空点击可打开文件夹选择器。“清空自定义目录”只清除列表，不删除文件。
3. “刷新大小”在后台统计大小，不跟随内部联接。
4. 选择目标盘和文件夹名称，例如 `G:\DevData`。下拉框显示固定 NTFS 盘及剩余空间，优先 G 盘，再优先其他非系统盘。
5. 默认开启“演练模式”，“开始演练”只预览勾选目录及目标。
6. 正式迁移前退出相关应用和终端，向下滚动到执行选项，取消演练模式，点击“开始迁移”。
7. 恢复时选择当时的目标盘和文件夹，点击“回滚 / 恢复”，把当前数据复制回原路径；目标盘数据保留。迁移提交失败时的自动回滚由引擎执行。

来自其他工具的已有联接也会显示状态，但只有本工具保存了状态清单的迁移才能自动恢复。

### 双击没有打开

确认已解压完整目录，包含 GUI 的 `.cmd`、`.ps1`、`.xaml` 和引擎 `AssistantMover.ps1`。启动器在脚本报错时保留错误窗口。中文 `.ps1` 使用 UTF-8 BOM，兼容 Windows PowerShell 5.1。

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\AssistantMover-GUI.ps1
```

## 自动发现的目录

| 应用 | 候选目录（仅存在的路径可选） |
| --- | --- |
| OpenAI Codex | `%USERPROFILE%\.codex`、`%USERPROFILE%\.cache\codex-runtimes`、`%LOCALAPPDATA%\OpenAI\Codex`、`%APPDATA%\Codex`、系统 Documents 下的 `Codex` |
| Codex 自定义数据 | 已设置且不同于上述路径的 `%CODEX_HOME%` |
| TRAE CN | `%APPDATA%\Trae CN`、`%LOCALAPPDATA%\Trae CN`、`%USERPROFILE%\.trae` |
| WorkBuddy | `%APPDATA%\WorkBuddy`、`%APPDATA%\Tencent\WorkBuddy`、`%LOCALAPPDATA%\WorkBuddy` |
| VS Code | `%APPDATA%\Code`、`%USERPROFILE%\.vscode\extensions` |
| VS Code Insiders | `%APPDATA%\Code - Insiders`、`%USERPROFILE%\.vscode-insiders\extensions` |
| Claude Code | `%USERPROFILE%\.claude` |
| 自定义目录 / 工作区 | 用户显式添加，或通过 CLI 的 `-Workspace` 传入 |

这些是候选位置，不保证所有应用版本都使用相同目录。清单默认 16 项；检测到不同的 `CODEX_HOME` 时增加一项。GUI 和 CLI 共用清单。任意位置的项目工作区都可手动添加；不会扫描整个磁盘寻找项目。不要同时选择父目录及其子目录。

## 命令行

多个数组参数请在 PowerShell 会话中用 `&` 调用脚本，避免 `powershell.exe -File` 的数组参数限制。

```powershell
# 目录清单
& .\AssistantMover.ps1 -Action Sources

# 预览默认目录
& .\AssistantMover.ps1 -Action Plan -TargetRoot G:\DevData

# 只演练指定目录
& .\AssistantMover.ps1 -Action Migrate -TargetRoot G:\DevData -Include @('codex-home','vscode-roaming') -ExplicitSelection -DryRun

# 正式迁移：先退出相关应用
& .\AssistantMover.ps1 -Action Migrate -TargetRoot G:\DevData -Include @('codex-home','vscode-roaming') -ExplicitSelection

# 只演练工作区，不加入默认应用目录
& .\AssistantMover.ps1 -Action Migrate -TargetRoot G:\DevData -Workspace @('C:\Projects\My App') -ExplicitSelection -DryRun

# 恢复
& .\AssistantMover.ps1 -Action Restore -TargetRoot G:\DevData
```

GUI 通过临时 JSON 请求传递选中 ID 和路径，支持中文、空格及多选；只选择工作区不会选中全部应用。临时请求和 GUI 日志在关闭后清理；正式操作日志保留在目标目录。

## 校验和恢复

- 正式迁移检查相关进程已退出，目标为不同分区上的本机 NTFS 固定磁盘；工具不会结束进程。
- 拒绝覆盖同名目标、未知联接、重复或互相包含的源目录，以及源与目标互相包含的路径。
- 先复制，再逐文件校验 SHA-256、文件数、字节数及目录结构，并确认复制期间源数据未变化。
- 所有副本准备好后才切换路径；原目录先改名暂存，创建 junction 后再校验。
- 提交失败时反向回滚；全部成功后清理原目录暂存。
- 恢复复制的是**当前数据**，包含迁移后新增或修改的文件；恢复期间发现并发写入则拒绝切换。
- 恢复中途失败时尝试恢复原有联接，保留目标数据及已准备的恢复副本。
- 删除 junction 前核对目标，只删除联接本身。
- 状态和正式日志保存在 `<目标目录>\.assistant-mover\`，状态更新保留 `.previous` 副本。

**目标盘目录是正在使用的数据，不是独立历史备份。** 原目录暂存用于迁移提交阶段的回滚，成功后清理。长期历史备份需额外保存独立副本。

## 限制

- 需要 Windows PowerShell 5.1、WPF 和 robocopy，适用于 Windows 10 / 11 本机固定 NTFS 盘。不支持网络盘、exFAT、FAT32 或可拔除移动盘。
- 目标盘需持续可用；目录联接不等于把整个应用安装程序变成 U 盘软件。
- 正式操作前退出相关编辑器、Codex、后台任务和终端。文件锁或权限问题会使复制失败。
- 数据量大时逐文件 SHA-256 可能耗时较长。
- 路径切换期间断电时，请保留目标盘 `.assistant-mover`、源路径旁 `.__assistant-mover-*` / `.__assistant-restore-*` 和日志，先检查副本，勿直接删除。
- 每个目标根目录保存一组迁移清单。已有清单时使用新的文件夹名称，避免覆盖已有记录。

## 开发验证

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

覆盖 Windows PowerShell 解析与 BOM、WPF 控件和初始化、GUI 子进程演练与错误显示、中文/空格路径、明确勾选、Codex 清单、复制/哈希/junction、修改后数据恢复，以及注入迁移/恢复提交失败后的回滚。

事务测试只用临时目录，替换了进程与跨盘预检；不迁移真实应用数据，也不代表已验证断电等所有故障。

## License

MIT. Independent implementation. Folder structure and workflow inspired by [ZhaowTao/codex-mover](https://github.com/ZhaowTao/codex-mover).
