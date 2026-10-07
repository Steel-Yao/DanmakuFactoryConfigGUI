# 贡献指南

感谢你愿意改进 DanmakuFactory 参数配置 GUI。这个项目优先保持“单文件、无额外运行依赖、Windows 开箱即用”的定位，提交改动时请尽量沿用现有实现方式。

## 提交问题

- 先搜索现有 Issue，避免重复报告。
- 报告问题请尽量包含 Windows 版本、PowerShell 版本、DanmakuFactory 版本、复现步骤、实际输出和相关日志。
- 涉及界面布局时，请注明屏幕分辨率和 DPI 缩放比例。

## 参与开发

1. Fork 本仓库并创建分支，分支名建议使用 `codex/` 前缀。
2. 修改 `DanmakuFactoryGUI.ps1` 时保持兼容 Windows PowerShell 5.1。
3. 不把 `DanmakuFactory.exe`、个人配置、日志或转换结果提交进仓库。
4. 新增参数后同步更新 README 中的参数覆盖说明。
5. 提交信息使用中文，说明改了什么以及为什么改。

## 提交前验证

在 Windows PowerShell 5.1 或 PowerShell 7 中至少完成以下检查：

```powershell
# 1. 检查脚本语法
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path .\DanmakuFactoryGUI.ps1),
    [ref]$null,
    [ref]$errors
) | Out-Null
if ($errors.Count -gt 0) { $errors | Format-Table -AutoSize; exit 1 }

# 2. 启动自检并生成截图
$shot = Join-Path $env:TEMP 'DanmakuFactoryConfigGUI-selftest.png'
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass `
    -File .\DanmakuFactoryGUI.ps1 -SelfTestShot $shot

# 3. 用真实 DanmakuFactory.exe 跑一次 XML -> ASS 转换
#    确认日志中显示加载、写入和 Done，且输出文件确实生成。
```

## 界面改动约定

- 控件坐标按 96 DPI 设计，运行时统一乘以 `$script:UiScale`。
- 右侧选项卡控件使用 `Register-Follow`/`Update-FollowLayout` 处理宽度变化。
- 新增按钮优先使用 Windows 标准控件和短文本，避免固定宽度导致中文截断。
- 在不改变现有用户操作习惯的前提下增加功能。

## Pull Request

PR 描述请说明：

- 变更目的和用户可见效果；
- 已验证的 DanmakuFactory 版本；
- 运行过的测试或自检；
- 是否存在兼容性风险。
