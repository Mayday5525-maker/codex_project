# Assistant Mover

便携版 Windows 工具 / Portable Windows tool

将 TRAE CN、WorkBuddy、VS Code、Claude Code 的应用数据以及用户选择的项目工作区迁移到另一块本机 NTFS 磁盘。原路径由 Windows directory junction 指向新位置，应用仍访问原路径，不需要改配置。

Move TRAE CN, WorkBuddy, VS Code, Claude Code data and selected project workspaces to another local NTFS drive. Junctions preserve the original paths, so applications continue to use their existing locations without configuration changes.

## 界面 / GUI

双击 `AssistantMover-GUI.cmd`。选择目标目录，确认自动发现的应用目录，按需通过“添加工作区”选择项目文件夹。

1. 先保持“演练模式”，查看源目录、目标目录和大小。
2. 正式迁移前退出相关应用和终端会话，取消演练模式，再点击“开始迁移”。
3. 迁移完成后重新打开应用。源路径应显示为 junction。
4. 恢复时选择同一目标目录，点击“恢复备份”。

## 命令行 / CLI

```powershell
# 预览默认发现的目录，不写入文件
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\AssistantMover.ps1 -Action Plan -TargetRoot G:\AssistantData

# 对选中应用目录执行演练
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\AssistantMover.ps1 -Action Migrate -TargetRoot G:\AssistantData -Include trae-roaming vscode-roaming -DryRun

# 正式迁移
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\AssistantMover.ps1 -Action Migrate -TargetRoot G:\AssistantData -Include trae-roaming vscode-roaming

# 增加实际项目工作区
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\AssistantMover.ps1 -Action Migrate -TargetRoot G:\AssistantData -Workspace D:\Projects\MyApp

# 恢复同一目标目录保存的迁移
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\AssistantMover.ps1 -Action Restore -TargetRoot G:\AssistantData

# 在 Windows 上验证复制、逐文件哈希和 junction 安全删除
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\AssistantMover.ps1 -Action SelfTest
```

## 自动发现的目录 / Detected data

| 应用 | 默认目录 |
| --- | --- |
| TRAE CN | `%APPDATA%\Trae CN`、`%LOCALAPPDATA%\Trae CN`、`%USERPROFILE%\.trae` |
| WorkBuddy | `%APPDATA%\WorkBuddy`、`%APPDATA%\Tencent\WorkBuddy`、`%LOCALAPPDATA%\WorkBuddy` |
| VS Code | `%APPDATA%\Code`、`%USERPROFILE%\.vscode\extensions` |
| VS Code Insiders | `%APPDATA%\Code - Insiders`、`%USERPROFILE%\.vscode-insiders\extensions` |
| Claude Code | `%USERPROFILE%\.claude` |
| 项目工作区 | GUI 中手动选择，或使用 `-Workspace <目录>` |

VS Code、TRAE 和 WorkBuddy 的工作区位置由用户决定，没有可靠的统一项目根目录；Claude Code 也可以在任意项目目录运行。因此工具不会猜测或搬动整个 `Documents`、`Desktop` 或磁盘上的项目目录。请显式加入真正要迁移的工作区。

## 安全机制 / Safety

- 演练只扫描和预览；正式模式要求退出相关应用，并检查目标是不同分区上的本机 NTFS 固定磁盘。
- 拒绝覆盖同名目标目录、未知 junction、重解析点和目标/源互相包含的路径。
- 先复制，再逐文件校验 SHA-256、文件数、字节数和目录数；全部通过后才将原路径换成 junction。
- 替换路径时将原目录暂存，任何提交步骤失败都会按相反顺序自动回滚；暂存副本只在所有 junction 校验成功后清理。
- 迁移数据本身保留在目标目录中，作为活动数据和恢复副本；状态与日志保存在 `<目标目录>\.assistant-mover\`。
- 恢复前再次复制并逐项校验。失败时尽量重新建立 junction，源与目标副本都保留供排查。
- junction 删除操作会先核对目标，再调用非递归目录删除，避免误删联接指向的数据。

## 注意事项 / Limitations

- 仅支持 Windows PowerShell 5.1+、本机固定 NTFS 磁盘。不能迁移到 exFAT、FAT32、网络盘或可拔除的移动盘。
- 开始前退出 TRAE CN、WorkBuddy、VS Code 和 Claude Code。进行中的编辑器、终端任务或文件写入可能造成复制后的数据变化。
- 默认路径基于各应用常见 Windows 用户目录。如果安装版本使用其他位置，不会自动识别；项目工作区可手动添加。
- 工作区应位于与目标不同的本机分区。用户需确保目标盘始终可用，否则原路径 junction 将无法访问。
- 工具不结束应用进程、不格式化磁盘、不删除目标副本、不上传用户数据。
- 每个文件都做 SHA-256 校验，数据量大时会占用明显时间；迁移期间保持电脑供电并避免强制关机。
- 若系统在路径切换中途断电，保留目标盘 `.assistant-mover`、源路径旁 `.__assistant-mover-*` 暂存目录和日志，不要手动删除，先检查这些副本。

## License

MIT. This project uses an independent implementation. Its folder layout and user-facing workflow are inspired by [ZhaowTao/codex-mover](https://github.com/ZhaowTao/codex-mover).
