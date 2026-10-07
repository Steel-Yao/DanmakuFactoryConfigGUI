#Requires -Version 5.1
<#
    DanmakuFactory 参数配置 GUI
    ===========================
    Copyright (c) 2026 Steel-Yao and contributors
    SPDX-License-Identifier: MIT
    Project: https://github.com/Steel-Yao/DanmakuFactoryConfigGUI

    图形化地修改、生成和保存 DanmakuFactory CLI 参数。

    功能：
      * 添加/移除输入文件，逐条设置时间偏移（-t）
      * 修改常用命令行参数（分辨率、字体、消息框、屏蔽、黑名单等）
      * 实时生成完整命令行，可一键复制
      * 加载/保存 JSON 配置（与 DanmakuFactoryConfig.json 格式完全兼容）
      * 一键保存为 exe 同目录的默认配置 DanmakuFactoryConfig.json
      * 生成双击即可运行的 .bat 脚本
      * 直接在 GUI 内运行 DanmakuFactory.exe 并查看输出

    用法：
      双击 DanmakuFactoryGUI.cmd
      或：
      powershell -NoProfile -STA -ExecutionPolicy Bypass -File DanmakuFactoryGUI.ps1
#>
param(
    [string]$SelfTestShot = ''
)

$ErrorActionPreference = 'Stop'

# 启动阶段的兜底：任何错误都写入日志文件并弹窗提示（避免隐藏控制台时静默失败）
trap {
    $errText = $_.Exception.ToString()
    try {
        if ($script:ScriptDir) {
            [System.IO.File]::WriteAllText(
                [System.IO.Path]::Combine($script:ScriptDir, 'DanmakuFactoryGUI-error.log'),
                $errText,
                (New-Object System.Text.UTF8Encoding($true)))
        }
    } catch { }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        [void][System.Windows.Forms.MessageBox]::Show(
            ('脚本启动失败：' + $_.Exception.Message + "`r`n`r`n详细信息已写入 DanmakuFactoryGUI-error.log"),
            'DanmakuFactory 参数配置', 'OK', 'Error')
    } catch { }
    exit 1
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 声明进程为 DPI 感知：按真实 DPI 渲染，避免 Windows 位图拉伸造成的模糊
try {
    if (-not ('Native.DpiAwareness' -as [type])) {
        Add-Type -Namespace Native -Name DpiAwareness -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
    }
    [void][Native.DpiAwareness]::SetProcessDPIAware()
} catch { }

# 计算 DPI 缩放系数（96 DPI = 1.0）。所有控件坐标按 96 DPI 设计，创建时统一换算，
# 这样高 DPI 下界面清晰、比例正确，且不依赖 WinForms 自动缩放的时序行为。
$script:UiScale = 1.0
try {
    $screenDpi = 0
    try {
        if (-not ('Native.DpiQuery' -as [type])) {
            Add-Type -Namespace Native -Name DpiQuery -MemberDefinition '[DllImport("user32.dll")] public static extern uint GetDpiForSystem();'
        }
        $screenDpi = [int][Native.DpiQuery]::GetDpiForSystem()
    } catch { }
    if ($screenDpi -le 0) {
        $screenGraphics = [System.Drawing.Graphics]::FromHwnd([System.IntPtr]::Zero)
        $screenDpi = [int]$screenGraphics.DpiX
        $screenGraphics.Dispose()
    }
    if ($screenDpi -gt 0) { $script:UiScale = $screenDpi / 96.0 }
} catch { }

function Scaled {
    param([double]$Value)
    return [int][Math]::Round($Value * $script:UiScale)
}

try {
    [System.Windows.Forms.Application]::EnableVisualStyles()
    [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
} catch {
    # 已初始化过视觉样式时忽略（例如在交互式会话中重复加载脚本）
}

$script:Inv = [System.Globalization.CultureInfo]::InvariantCulture
$script:AppTitle = 'DanmakuFactory 参数配置'
$script:InitDone = $false
$script:Proc = $null
$script:RunTimer = $null
$script:RunOutFile = ''
$script:RunErrFile = ''
$script:RunExitFile = ''
$script:RunBatFile = ''
$script:RunOutShown = 0
$script:RunErrShown = 0
$script:RunOutTail = ''
$script:RunErrTail = ''
$script:RunOutputPath = ''
$script:RunOutputStamp = $null

$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---------------------------------------------------------------------------
# 通用小工具
# ---------------------------------------------------------------------------

function Fmt {
    param([double]$Value, [int]$Decimals)
    return $Value.ToString('F' + $Decimals, $script:Inv)
}

function Try-ParseDouble {
    param([string]$Text, [ref]$Result)
    $d = 0.0
    if ([double]::TryParse($Text, [System.Globalization.NumberStyles]::Float, $script:Inv, [ref]$d)) {
        $Result.Value = $d
        return $true
    }
    if ([double]::TryParse($Text, [ref]$d)) {
        $Result.Value = $d
        return $true
    }
    return $false
}

function Try-ParseCoord {
    param([string]$Text, [ref]$Result)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $m = [regex]::Match($Text.Trim(), '^(\d+)\s*[^\d]+\s*(\d+)$')
    if (-not $m.Success) { return $false }
    $Result.Value = @([int]$m.Groups[1].Value, [int]$m.Groups[2].Value)
    return $true
}

function Get-DisplayFormat {
    param([string]$Path)
    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.xml' { return 'xml' }
        '.json' { return 'json' }
        '.ass' { return 'ass' }
        default { return '' }
    }
}

function Quote-Arg {
    # 按 Windows 命令行引用规则加引号，供 ProcessStartInfo.Arguments / cmd 使用
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    # 一律加引号：.bat 里未加引号的 & ^ ( ) < > | 等会被 cmd 当作特殊字符
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $bs = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') { $bs++; continue }
        if ($ch -eq '"') {
            [void]$sb.Append(('\' * ($bs * 2 + 1)) + '"')
            $bs = 0
            continue
        }
        if ($bs -gt 0) { [void]$sb.Append('\' * $bs); $bs = 0 }
        [void]$sb.Append($ch)
    }
    if ($bs -gt 0) { [void]$sb.Append('\' * ($bs * 2)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ToBool {
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return [bool]$Value }
    $s = ([string]$Value).Trim().ToLowerInvariant()
    return ($s -eq 'true' -or $s -eq '1' -or $s -eq 'yes')
}

function Write-SelfTest {
    param([string]$Text)
    try { [Console]::Out.WriteLine($Text) } catch { }
    try {
        if ($SelfTestShot -ne '') {
            [System.IO.File]::AppendAllText($SelfTestShot + '.log', $Text + "`r`n")
        }
    } catch { }
}

function Normalize-Newlines {
    param([string]$Text)
    return $Text.Replace("`r`n", "`n").Replace("`r", "`n").Replace("`n", "`r`n")
}

function Get-CoordArg {
    # 返回 WxH 形式；无法解析时原样返回
    param([string]$Text)
    $coord = @(0, 0)
    if (Try-ParseCoord -Text $Text -Result ([ref]$coord)) {
        return $coord[0].ToString($script:Inv) + 'x' + $coord[1].ToString($script:Inv)
    }
    return $Text.Trim()
}

function Get-CoordJsonArray {
    # 返回 [w, h] 形式（与 DanmakuFactory 配置格式一致）
    param([string]$Text, [int]$DefaultX, [int]$DefaultY)
    $coord = @($DefaultX, $DefaultY)
    $null = Try-ParseCoord -Text $Text -Result ([ref]$coord)
    return '[' + $coord[0].ToString($script:Inv) + ', ' + $coord[1].ToString($script:Inv) + ']'
}

# ---------------------------------------------------------------------------
# 默认参数
# ---------------------------------------------------------------------------

$script:Defaults = [ordered]@{
    Resolution      = '1920x1080'
    DisplayArea     = 1.00
    ScrollArea      = 1.00
    ScrollTime      = 12.0
    FixTime         = 5.0
    Density         = 0
    LineSpacing     = 0
    TopMargin       = 0
    BottomMargin    = 0
    Fontsize        = 38
    Fontname        = 'Microsoft YaHei'
    Opacity         = 180
    Outline         = 0
    OutlineBlur     = 0
    OutlineOpacity  = 255
    Shadow          = 1
    Bold            = $false
    FontSizeMode    = 'default'
    SaveBlocked     = $true
    ShowUsernames   = $false
    ShowMsgbox      = $true
    MsgboxSize      = '500x1080'
    MsgboxPos       = '20x0'
    MsgboxFontsize  = 38
    MsgboxDuration  = 0.0
    GiftMinPrice    = 0.0
    Blocked         = @()
    Stat            = @()
    Blacklist       = ''
    BlacklistRegex  = $false
    IgnoreWarnings  = $true
    Force           = $true
}

# ---------------------------------------------------------------------------
# 控件构造工具
# ---------------------------------------------------------------------------

function New-LabelEx {
    param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H = 21)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Text
    $lbl.Location = [System.Drawing.Point]::new((Scaled $X), (Scaled ($Y + 3)))
    $lbl.Size = [System.Drawing.Size]::new((Scaled $W), (Scaled $H))
    $lbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    return $lbl
}

function New-Hint {
    param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H = 20)
    $lbl = New-LabelEx -Text $Text -X $X -Y $Y -W $W -H $H
    $lbl.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 110)
    return $lbl
}

function New-TxtBox {
    param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H = 23, [bool]$ReadOnly = $false)
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Text = $Text
    $tb.Location = [System.Drawing.Point]::new((Scaled $X), (Scaled $Y))
    $tb.Size = [System.Drawing.Size]::new((Scaled $W), (Scaled $H))
    $tb.ReadOnly = $ReadOnly
    return $tb
}

function New-NumBox {
    param(
        [decimal]$Value, [decimal]$Min, [decimal]$Max,
        [decimal]$Increment, [int]$Decimals,
        [int]$X, [int]$Y, [int]$W = 110
    )
    if ($Value -lt $Min) { $Value = $Min }
    if ($Value -gt $Max) { $Value = $Max }
    $num = New-Object System.Windows.Forms.NumericUpDown
    $num.Location = [System.Drawing.Point]::new((Scaled $X), (Scaled $Y))
    $num.Size = [System.Drawing.Size]::new((Scaled $W), (Scaled 23))
    $num.Minimum = $Min
    $num.Maximum = $Max
    $num.DecimalPlaces = $Decimals
    $num.Increment = $Increment
    $num.Value = $Value
    $num.TextAlign = [System.Windows.Forms.HorizontalAlignment]::Center
    return $num
}

function New-Check {
    param([string]$Text, [int]$X, [int]$Y, [int]$W, [bool]$Checked = $false)
    $chk = New-Object System.Windows.Forms.CheckBox
    $chk.Text = $Text
    $chk.Location = [System.Drawing.Point]::new((Scaled $X), (Scaled ($Y + 2)))
    $chk.Size = [System.Drawing.Size]::new((Scaled $W), (Scaled 21))
    $chk.Checked = $Checked
    return $chk
}

function New-Radio {
    param([string]$Text, [int]$X, [int]$Y, [int]$W, [bool]$Checked = $false)
    $rdo = New-Object System.Windows.Forms.RadioButton
    $rdo.Text = $Text
    $rdo.Location = [System.Drawing.Point]::new((Scaled $X), (Scaled ($Y + 2)))
    $rdo.Size = [System.Drawing.Size]::new((Scaled $W), (Scaled 21))
    $rdo.Checked = $Checked
    $rdo.UseVisualStyleBackColor = $true
    return $rdo
}

function New-Button {
    param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H = 30)
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $Text
    $btn.Location = [System.Drawing.Point]::new((Scaled $X), (Scaled $Y))
    $btn.Size = [System.Drawing.Size]::new((Scaled $W), (Scaled $H))
    $btn.UseVisualStyleBackColor = $true
    return $btn
}

function New-Group {
    param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H)
    $grp = New-Object System.Windows.Forms.GroupBox
    $grp.Text = $Text
    $grp.Location = [System.Drawing.Point]::new((Scaled $X), (Scaled $Y))
    $grp.Size = [System.Drawing.Size]::new((Scaled $W), (Scaled $H))
    return $grp
}

# ---------------------------------------------------------------------------
# TabPage 内控件的宽度跟随
# TabPage 的锚点会在页面拿到真实尺寸（默认 200px）之前被捕获，导致右列控件跑出可视区。
# 这里改为显式布局：记录设计坐标，按父级实际宽度重新计算位置。
# ---------------------------------------------------------------------------

$script:PageDesignWidth = 589.0
$script:FollowControls = New-Object System.Collections.ArrayList

function Register-Follow {
    param($Control, [double]$DesignX, [double]$DesignW, [bool]$Stretch = $false)
    [void]$script:FollowControls.Add([pscustomobject]@{
        Control = $Control
        X       = $DesignX
        W       = $DesignW
        Stretch = $Stretch
    })
    $Control.Anchor = 'Top,Left'
}

function Update-FollowLayout {
    foreach ($item in $script:FollowControls) {
        try {
            $c = $item.Control
            $parent = $c.Parent
            if ($null -eq $parent) { continue }
            $pageW = $parent.ClientSize.Width
            $rightMargin = $script:PageDesignWidth - ($item.X + $item.W)
            if ($item.Stretch) {
                $left = Scaled $item.X
                $w = $pageW - $left - (Scaled $rightMargin)
                if ($w -lt (Scaled 60)) { $w = Scaled 60 }
            } else {
                $w = Scaled $item.W
                $left = $pageW - (Scaled $rightMargin) - $w
                if ($left -lt (Scaled 12)) { $left = Scaled 12 }
            }
            $c.SetBounds($left, $c.Top, $w, $c.Height)
        } catch { }
    }
}

# 主区域宽度分配：左侧三个分组限制在 [最小, 最大] 宽度内，
# 多余的宽度全部给右侧参数区，避免控件被无限拉伸或挤压重叠。
function Update-MainLayout {
    try {
        $margin = Scaled 12
        $gap = Scaled 12
        # 左列窄于 600 时组内控件（按钮与提示文字等）会重叠，故最小值取设计宽度
        $leftMin = Scaled 600
        $leftMax = Scaled 720
        $tabMin = Scaled 600

        $avail = $form.ClientSize.Width - ($margin * 2) - $gap
        $leftW = $avail - $tabMin
        if ($leftW -lt $leftMin) { $leftW = $leftMin }
        if ($leftW -gt $leftMax) { $leftW = $leftMax }
        $tabW = $avail - $leftW
        if ($tabW -lt (Scaled 200)) { $tabW = Scaled 200 }

        foreach ($g in @($grpInputs, $grpOutput, $grpActions)) {
            $g.Left = $margin
            $g.Width = $leftW
        }
        $tabs.Left = $margin + $leftW + $gap
        $tabs.Width = $tabW
    } catch { }
}

# ---------------------------------------------------------------------------
# 主窗体
# ---------------------------------------------------------------------------

$form = New-Object System.Windows.Forms.Form
$form.Text = $script:AppTitle
$form.ClientSize = [System.Drawing.Size]::new((Scaled 1230), (Scaled 724))
$form.MinimumSize = [System.Drawing.Size]::new((Scaled 1256), (Scaled 620))
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$form.KeyPreview = $true

$uiFont = $null
foreach ($name in @('Microsoft YaHei UI', 'Microsoft YaHei', 'Segoe UI')) {
    try {
        $uiFont = New-Object System.Drawing.Font($name, 9)
        break
    } catch {
        $uiFont = $null
    }
}
if ($null -ne $uiFont) { $form.Font = $uiFont }

# ---------------------------------------------------------------------------
# 左侧：输入文件
# ---------------------------------------------------------------------------

$grpInputs = New-Group -Text '输入弹幕文件' -X 12 -Y 12 -W 600 -H 210
$grpInputs.Anchor = 'Top,Left'
$form.Controls.Add($grpInputs)

$gridInputs = New-Object System.Windows.Forms.DataGridView
$gridInputs.Location = [System.Drawing.Point]::new((Scaled 12), (Scaled 22))
$gridInputs.Size = [System.Drawing.Size]::new((Scaled 576), (Scaled 144))
$gridInputs.Anchor = 'Top,Left,Right,Bottom'
$gridInputs.AllowUserToAddRows = $false
$gridInputs.AllowUserToDeleteRows = $false
$gridInputs.AllowUserToResizeRows = $false
$gridInputs.RowHeadersVisible = $false
$gridInputs.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$gridInputs.MultiSelect = $true
$gridInputs.BackgroundColor = [System.Drawing.Color]::White
$gridInputs.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$gridInputs.ColumnHeadersHeightSizeMode = [System.Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::DisableResizing
$gridInputs.ColumnHeadersHeight = (Scaled 28)
$colShift = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colShift.HeaderText = '时间偏移(秒)'
$colShift.Width = (Scaled 100)
$colShift.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::NotSortable
$colFmt = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colFmt.HeaderText = '格式'
$colFmt.Width = (Scaled 60)
$colFmt.ReadOnly = $true
$colFmt.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::NotSortable
$colFile = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colFile.HeaderText = '输入文件'
$colFile.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
$colFile.ReadOnly = $true
$colFile.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::NotSortable
[void]$gridInputs.Columns.Add($colShift)
[void]$gridInputs.Columns.Add($colFmt)
[void]$gridInputs.Columns.Add($colFile)
$grpInputs.Controls.Add($gridInputs)

$btnAddInput = New-Button -Text '添加输入文件…' -X 12 -Y 172 -W 130 -H 28
$btnRemoveInput = New-Button -Text '移除所选' -X 150 -Y 172 -W 90 -H 28
$btnClearInputs = New-Button -Text '清空列表' -X 248 -Y 172 -W 90 -H 28
$lblInputHint = New-Hint -Text '时间偏移可直接在表格第一列中修改' -X 348 -Y 175 -W 240 -H 20
$lblInputHint.Anchor = 'Top,Right'
$grpInputs.Controls.Add($btnAddInput)
$grpInputs.Controls.Add($btnRemoveInput)
$grpInputs.Controls.Add($btnClearInputs)
$grpInputs.Controls.Add($lblInputHint)

# ---------------------------------------------------------------------------
# 左侧：输出文件与程序路径
# ---------------------------------------------------------------------------

$grpOutput = New-Group -Text '输出与程序' -X 12 -Y 232 -W 600 -H 108
$grpOutput.Anchor = 'Top,Left'
$form.Controls.Add($grpOutput)

$lblOutput = New-LabelEx -Text '输出文件' -X 12 -Y 24 -W 70
$txtOutput = New-TxtBox -Text '' -X 88 -Y 24 -W 382
$btnBrowseOutput = New-Button -Text '浏览…' -X 478 -Y 23 -W 108 -H 25
$lblOutputHint = New-Hint -Text '输出格式按扩展名自动识别（.ass / .xml / .json）' -X 88 -Y 50 -W 498 -H 20
$lblExe = New-LabelEx -Text '程序 exe' -X 12 -Y 72 -W 70
$txtExe = New-TxtBox -Text '' -X 88 -Y 72 -W 382
$btnBrowseExe = New-Button -Text '浏览…' -X 478 -Y 71 -W 108 -H 25
$txtOutput.Anchor = 'Top,Left,Right'
$btnBrowseOutput.Anchor = 'Top,Right'
$lblOutputHint.Anchor = 'Top,Left,Right'
$txtExe.Anchor = 'Top,Left,Right'
$btnBrowseExe.Anchor = 'Top,Right'
$grpOutput.Controls.Add($lblOutput)
$grpOutput.Controls.Add($txtOutput)
$grpOutput.Controls.Add($btnBrowseOutput)
$grpOutput.Controls.Add($lblOutputHint)
$grpOutput.Controls.Add($lblExe)
$grpOutput.Controls.Add($txtExe)
$grpOutput.Controls.Add($btnBrowseExe)

# ---------------------------------------------------------------------------
# 左侧：配置操作按钮
# ---------------------------------------------------------------------------

$grpActions = New-Group -Text '配置操作' -X 12 -Y 350 -W 600 -H 140
$grpActions.Anchor = 'Top,Left'
$form.Controls.Add($grpActions)

$btnLoadConfig = New-Button -Text '加载配置…' -X 12 -Y 20 -W 282 -H 34
$btnSaveConfig = New-Button -Text '保存配置为…（JSON）' -X 306 -Y 20 -W 282 -H 34
$btnSaveDefault = New-Button -Text '保存为默认配置（exe 同目录）' -X 12 -Y 60 -W 282 -H 34
$btnMakeBat = New-Button -Text '生成运行脚本…（.bat）' -X 306 -Y 60 -W 282 -H 34
$btnReset = New-Button -Text '重置为默认参数' -X 12 -Y 100 -W 282 -H 30
$btnOpenDir = New-Button -Text '打开程序所在目录' -X 306 -Y 100 -W 282 -H 30
$grpActions.Controls.Add($btnLoadConfig)
$grpActions.Controls.Add($btnSaveConfig)
$grpActions.Controls.Add($btnSaveDefault)
$grpActions.Controls.Add($btnMakeBat)
$grpActions.Controls.Add($btnReset)
$grpActions.Controls.Add($btnOpenDir)

# ---------------------------------------------------------------------------
# 右侧：参数选项卡
# ---------------------------------------------------------------------------

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = [System.Drawing.Point]::new((Scaled 624), (Scaled 12))
$tabs.Size = [System.Drawing.Size]::new((Scaled 594), (Scaled 478))
$tabs.Anchor = 'Top,Left'
$form.Controls.Add($tabs)

$pageBasic = New-Object System.Windows.Forms.TabPage
$pageBasic.Text = '基本参数'
$pageBasic.UseVisualStyleBackColor = $true
$pageStyle = New-Object System.Windows.Forms.TabPage
$pageStyle.Text = '样式'
$pageStyle.UseVisualStyleBackColor = $true
$pageMsg = New-Object System.Windows.Forms.TabPage
$pageMsg.Text = '消息框'
$pageMsg.UseVisualStyleBackColor = $true
$pageBlock = New-Object System.Windows.Forms.TabPage
$pageBlock.Text = '屏蔽与统计'
$pageBlock.UseVisualStyleBackColor = $true
$pageAdv = New-Object System.Windows.Forms.TabPage
$pageAdv.Text = '其他'
$pageAdv.UseVisualStyleBackColor = $true
[void]$tabs.Controls.Add($pageBasic)
[void]$tabs.Controls.Add($pageStyle)
[void]$tabs.Controls.Add($pageMsg)
[void]$tabs.Controls.Add($pageBlock)
[void]$tabs.Controls.Add($pageAdv)

# ---- 基本参数 ----
$txtResolution = New-TxtBox -Text '1920x1080' -X 134 -Y 14 -W 160
$lblResHint = New-Hint -Text '宽x高，例如 1920x1080（也可用空格分隔）' -X 302 -Y 17 -W 240
$lblResHint.Anchor = 'Top,Left,Right'
$pageBasic.Controls.Add((New-LabelEx -Text '分辨率' -X 12 -Y 14 -W 118))
$pageBasic.Controls.Add($txtResolution)
$pageBasic.Controls.Add($lblResHint)

$numDisplayArea = New-NumBox -Value 1.00 -Min 0 -Max 1 -Increment 0.05 -Decimals 2 -X 134 -Y 44
$numScrollArea = New-NumBox -Value 1.00 -Min 0 -Max 1 -Increment 0.05 -Decimals 2 -X 420 -Y 44 -W 110
$lblScrollArea = New-LabelEx -Text '滚动区域(0.0-1.0)' -X 288 -Y 44 -W 128
$lblScrollArea.Anchor = 'Top,Right'
$numScrollArea.Anchor = 'Top,Right'
$pageBasic.Controls.Add((New-LabelEx -Text '显示区域(0.0-1.0)' -X 12 -Y 44 -W 118))
$pageBasic.Controls.Add($numDisplayArea)
$pageBasic.Controls.Add($lblScrollArea)
$pageBasic.Controls.Add($numScrollArea)

$numScrollTime = New-NumBox -Value 12.0 -Min 0.1 -Max 600 -Increment 0.5 -Decimals 1 -X 134 -Y 74
$numFixTime = New-NumBox -Value 5.0 -Min 0.1 -Max 600 -Increment 0.5 -Decimals 1 -X 420 -Y 74 -W 110
$lblFixTime = New-LabelEx -Text '固定时间(秒)' -X 288 -Y 74 -W 128
$lblFixTime.Anchor = 'Top,Right'
$numFixTime.Anchor = 'Top,Right'
$pageBasic.Controls.Add((New-LabelEx -Text '滚动时间(秒)' -X 12 -Y 74 -W 118))
$pageBasic.Controls.Add($numScrollTime)
$pageBasic.Controls.Add($lblFixTime)
$pageBasic.Controls.Add($numFixTime)

$numDensity = New-NumBox -Value 0 -Min -1 -Max 9999 -Increment 1 -Decimals 0 -X 134 -Y 104
$numLineSpacing = New-NumBox -Value 0 -Min -300 -Max 300 -Increment 1 -Decimals 0 -X 420 -Y 104 -W 110
$lblLineSpacing = New-LabelEx -Text '行间距(像素)' -X 288 -Y 104 -W 128
$lblLineSpacing.Anchor = 'Top,Right'
$numLineSpacing.Anchor = 'Top,Right'
$pageBasic.Controls.Add((New-LabelEx -Text '弹幕密度(条)' -X 12 -Y 104 -W 118))
$pageBasic.Controls.Add($numDensity)
$pageBasic.Controls.Add($lblLineSpacing)
$pageBasic.Controls.Add($numLineSpacing)

$numTopMargin = New-NumBox -Value 0 -Min 0 -Max 10000 -Increment 1 -Decimals 0 -X 134 -Y 134
$numBottomMargin = New-NumBox -Value 0 -Min 0 -Max 10000 -Increment 1 -Decimals 0 -X 420 -Y 134 -W 110
$lblBottomMargin = New-LabelEx -Text '底部间距(像素)' -X 288 -Y 134 -W 128
$lblBottomMargin.Anchor = 'Top,Right'
$numBottomMargin.Anchor = 'Top,Right'
$pageBasic.Controls.Add((New-LabelEx -Text '顶部间距(像素)' -X 12 -Y 134 -W 118))
$pageBasic.Controls.Add($numTopMargin)
$pageBasic.Controls.Add($lblBottomMargin)
$pageBasic.Controls.Add($numBottomMargin)

$hintBasic1 = New-Hint -Text '密度 -1 = 不重叠，0 = 不限制；区域取 0.0-1.0，1.00 为全屏' -X 12 -Y 168 -W 530 -H 34
$hintBasic1.Anchor = 'Top,Left,Right'
$hintBasic2 = New-Hint -Text '滚动/固定时间为弹幕通过或停留在屏幕上的秒数' -X 12 -Y 198 -W 530 -H 20
$hintBasic2.Anchor = 'Top,Left,Right'
$pageBasic.Controls.Add($hintBasic1)
$pageBasic.Controls.Add($hintBasic2)

# ---- 样式 ----
$numFontsize = New-NumBox -Value 38 -Min 1 -Max 1000 -Increment 1 -Decimals 0 -X 134 -Y 14
$chkBold = New-Check -Text '粗体 (-B)' -X 420 -Y 14 -W 120
$chkBold.Anchor = 'Top,Right'
$pageStyle.Controls.Add((New-LabelEx -Text '字号(像素)' -X 12 -Y 14 -W 118))
$pageStyle.Controls.Add($numFontsize)
$pageStyle.Controls.Add($chkBold)

$cmbFont = New-Object System.Windows.Forms.ComboBox
$cmbFont.Location = [System.Drawing.Point]::new((Scaled 134), (Scaled 44))
$cmbFont.Size = [System.Drawing.Size]::new((Scaled 396), (Scaled 23))
$cmbFont.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
try {
    $fontNames = (New-Object System.Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name }
    [void]$cmbFont.Items.AddRange([object[]]($fontNames | Sort-Object))
} catch { }
$cmbFont.Text = $script:Defaults.Fontname
$cmbFont.Anchor = 'Top,Left,Right'
$pageStyle.Controls.Add((New-LabelEx -Text '字体' -X 12 -Y 44 -W 118))
$pageStyle.Controls.Add($cmbFont)

$rdoFontDefault = New-Radio -Text '默认' -X 134 -Y 74 -W 70 -Checked $true
$rdoFontStrict = New-Radio -Text '严格保持字号' -X 210 -Y 74 -W 120
$rdoFontNorm = New-Radio -Text '自动修正字号' -X 336 -Y 74 -W 140
$pageStyle.Controls.Add((New-LabelEx -Text '字号处理' -X 12 -Y 74 -W 118))
$pageStyle.Controls.Add($rdoFontDefault)
$pageStyle.Controls.Add($rdoFontStrict)
$pageStyle.Controls.Add($rdoFontNorm)

$numOpacity = New-NumBox -Value 180 -Min 1 -Max 255 -Increment 1 -Decimals 0 -X 134 -Y 104
$numOutlineOpacity = New-NumBox -Value 255 -Min 0 -Max 255 -Increment 1 -Decimals 0 -X 420 -Y 104 -W 110
$lblOutlineOpacity = New-LabelEx -Text '描边不透明度(0-255)' -X 288 -Y 104 -W 128
$lblOutlineOpacity.Anchor = 'Top,Right'
$numOutlineOpacity.Anchor = 'Top,Right'
$pageStyle.Controls.Add((New-LabelEx -Text '不透明度(1-255)' -X 12 -Y 104 -W 118))
$pageStyle.Controls.Add($numOpacity)
$pageStyle.Controls.Add($lblOutlineOpacity)
$pageStyle.Controls.Add($numOutlineOpacity)

$numOutline = New-NumBox -Value 0 -Min 0 -Max 4 -Increment 1 -Decimals 1 -X 134 -Y 134
$numOutlineBlur = New-NumBox -Value 0 -Min 0 -Max 100 -Increment 1 -Decimals 1 -X 420 -Y 134 -W 110
$lblOutlineBlur = New-LabelEx -Text '描边模糊半径' -X 288 -Y 134 -W 128
$lblOutlineBlur.Anchor = 'Top,Right'
$numOutlineBlur.Anchor = 'Top,Right'
$pageStyle.Controls.Add((New-LabelEx -Text '描边宽度(0-4)' -X 12 -Y 134 -W 118))
$pageStyle.Controls.Add($numOutline)
$pageStyle.Controls.Add($lblOutlineBlur)
$pageStyle.Controls.Add($numOutlineBlur)

$numShadow = New-NumBox -Value 1 -Min 0 -Max 4 -Increment 1 -Decimals 1 -X 134 -Y 164
$pageStyle.Controls.Add((New-LabelEx -Text '阴影深度(0-4)' -X 12 -Y 164 -W 118))
$pageStyle.Controls.Add($numShadow)
$hintStyle = New-Hint -Text '不透明度越小越透明；描边模糊半径 0 表示关闭' -X 12 -Y 198 -W 530 -H 34
$hintStyle.Anchor = 'Top,Left,Right'
$pageStyle.Controls.Add($hintStyle)

# ---- 消息框 ----
$chkShowUsernames = New-Check -Text '显示用户名' -X 134 -Y 14 -W 130
$chkShowMsgbox = New-Check -Text '显示礼物框' -X 420 -Y 14 -W 130 -Checked $true
$chkShowMsgbox.Anchor = 'Top,Right'
$pageMsg.Controls.Add((New-LabelEx -Text '用户名/礼物框' -X 12 -Y 14 -W 118))
$pageMsg.Controls.Add($chkShowUsernames)
$pageMsg.Controls.Add($chkShowMsgbox)

$txtMsgboxSize = New-TxtBox -Text '500x1080' -X 134 -Y 44 -W 160
$hintMsgboxSize = New-Hint -Text '宽x高，例如 500x1080' -X 302 -Y 47 -W 240
$hintMsgboxSize.Anchor = 'Top,Left,Right'
$pageMsg.Controls.Add((New-LabelEx -Text '礼物框尺寸' -X 12 -Y 44 -W 118))
$pageMsg.Controls.Add($txtMsgboxSize)
$pageMsg.Controls.Add($hintMsgboxSize)

$txtMsgboxPos = New-TxtBox -Text '20x0' -X 134 -Y 74 -W 160
$hintMsgboxPos = New-Hint -Text '左上角坐标 XxY，例如 20x0' -X 302 -Y 77 -W 240
$hintMsgboxPos.Anchor = 'Top,Left,Right'
$pageMsg.Controls.Add((New-LabelEx -Text '礼物框位置' -X 12 -Y 74 -W 118))
$pageMsg.Controls.Add($txtMsgboxPos)
$pageMsg.Controls.Add($hintMsgboxPos)

$numMsgboxFontsize = New-NumBox -Value 38 -Min 1 -Max 1000 -Increment 1 -Decimals 0 -X 134 -Y 104
$numMsgboxDuration = New-NumBox -Value 0 -Min 0 -Max 3600 -Increment 0.5 -Decimals 2 -X 420 -Y 104 -W 110
$lblMsgboxDuration = New-LabelEx -Text '消息框时长(秒)' -X 288 -Y 104 -W 128
$lblMsgboxDuration.Anchor = 'Top,Right'
$numMsgboxDuration.Anchor = 'Top,Right'
$pageMsg.Controls.Add((New-LabelEx -Text '礼物框字号(像素)' -X 12 -Y 104 -W 118))
$pageMsg.Controls.Add($numMsgboxFontsize)
$pageMsg.Controls.Add($lblMsgboxDuration)
$pageMsg.Controls.Add($numMsgboxDuration)

$numGiftMinPrice = New-NumBox -Value 0 -Min 0 -Max 1000000 -Increment 1 -Decimals 2 -X 134 -Y 134
$pageMsg.Controls.Add((New-LabelEx -Text '礼物最低价格(元)' -X 12 -Y 134 -W 118))
$pageMsg.Controls.Add($numGiftMinPrice)
$hintMsgboxDuration = New-Hint -Text '消息框时长 0 表示使用 XML 中每条消息自带的时长' -X 12 -Y 168 -W 530 -H 20
$hintMsgboxDuration.Anchor = 'Top,Left,Right'
$pageMsg.Controls.Add($hintMsgboxDuration)

# ---- 屏蔽与统计 ----
$chkBlockL2R = New-Check -Text 'L2R 左到右' -X 134 -Y 14 -W 100
$chkBlockR2L = New-Check -Text 'R2L 右到左' -X 240 -Y 14 -W 100
$chkBlockTop = New-Check -Text 'TOP 顶部' -X 346 -Y 14 -W 90
$chkBlockBottom = New-Check -Text 'BOTTOM 底部' -X 440 -Y 14 -W 110
$chkBlockBottom.Anchor = 'Top,Right'
$pageBlock.Controls.Add((New-LabelEx -Text '屏蔽类型' -X 12 -Y 14 -W 118))
$pageBlock.Controls.Add($chkBlockL2R)
$pageBlock.Controls.Add($chkBlockR2L)
$pageBlock.Controls.Add($chkBlockTop)
$pageBlock.Controls.Add($chkBlockBottom)

$chkBlockSpecial = New-Check -Text 'SPECIAL 特殊' -X 134 -Y 42 -W 110
$chkBlockColor = New-Check -Text 'COLOR 彩色' -X 250 -Y 42 -W 100
$chkBlockRepeat = New-Check -Text 'REPEAT 重复' -X 356 -Y 42 -W 120
$chkBlockRepeat.Anchor = 'Top,Right'
$pageBlock.Controls.Add($chkBlockSpecial)
$pageBlock.Controls.Add($chkBlockColor)
$pageBlock.Controls.Add($chkBlockRepeat)

$chkSaveBlocked = New-Check -Text '保留被屏蔽的弹幕' -X 134 -Y 70 -W 150 -Checked $true
$chkBlacklistRegex = New-Check -Text '黑名单按正则匹配' -X 420 -Y 70 -W 150
$chkBlacklistRegex.Anchor = 'Top,Right'
$pageBlock.Controls.Add($chkSaveBlocked)
$pageBlock.Controls.Add($chkBlacklistRegex)

$chkStatTable = New-Check -Text 'TABLE 表格' -X 134 -Y 98 -W 110
$chkStatHistogram = New-Check -Text 'HISTOGRAM 直方图' -X 250 -Y 98 -W 150
$pageBlock.Controls.Add((New-LabelEx -Text '统计框' -X 12 -Y 98 -W 118))
$pageBlock.Controls.Add($chkStatTable)
$pageBlock.Controls.Add($chkStatHistogram)

$txtBlacklist = New-TxtBox -Text '' -X 134 -Y 128 -W 300
$btnBrowseBlacklist = New-Button -Text '浏览…' -X 440 -Y 127 -W 90 -H 25
$txtBlacklist.Anchor = 'Top,Left,Right'
$btnBrowseBlacklist.Anchor = 'Top,Right'
$pageBlock.Controls.Add((New-LabelEx -Text '黑名单文件' -X 12 -Y 128 -W 118))
$pageBlock.Controls.Add($txtBlacklist)
$pageBlock.Controls.Add($btnBrowseBlacklist)
$hintBlacklist = New-Hint -Text '黑名单为纯文本文件，每行一条；启用正则后按正则表达式匹配' -X 12 -Y 160 -W 530 -H 20
$hintBlacklist.Anchor = 'Top,Left,Right'
$pageBlock.Controls.Add($hintBlacklist)

# ---- 其他 ----
$chkIgnoreWarnings = New-Check -Text '忽略警告并自动继续（--ignore-warnings）' -X 12 -Y 14 -W 330 -Checked $true
$chkForce = New-Check -Text '强制覆盖输出文件（--force）' -X 12 -Y 42 -W 330 -Checked $true
$lblDefaultConfig = New-Hint -Text '默认配置文件：' -X 12 -Y 70 -W 530 -H 20
$lblDefaultConfig.Anchor = 'Top,Left,Right'
$txtAdvice = New-Object System.Windows.Forms.TextBox
$txtAdvice.Location = [System.Drawing.Point]::new((Scaled 12), (Scaled 98))
$txtAdvice.Size = [System.Drawing.Size]::new((Scaled 530), (Scaled 300))
$txtAdvice.Anchor = 'Top,Left,Right,Bottom'
$txtAdvice.Multiline = $true
$txtAdvice.ReadOnly = $true
$txtAdvice.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$txtAdvice.BackColor = [System.Drawing.Color]::White
$txtAdvice.Text = @(
    '说明',
    '',
    '1. DanmakuFactory 启动时会自动读取 exe 同目录的 DanmakuFactoryConfig.json。',
    '   「保存为默认配置」就是把当前参数写入该文件，之后直接双击 exe 也会使用这些参数。',
    '',
    '2. 命令行参数优先级最高。点击「运行」时，GUI 会把当前所有参数显式传给 exe，',
    '   因此不会被旧的默认配置文件干扰。',
    '',
    '3. 以下参数只在命令行中生效，不会写入 JSON 配置文件：',
    '   字号处理（--font-size-strict / --font-size-norm）、描边模糊（--outline-blur）、',
    '   描边不透明度（--outline-opacity）、黑名单（--blacklist / --blacklist-regex）。',
    '   请使用「复制命令」或「生成运行脚本」来保留它们。',
    '',
    '4. 输入文件格式按扩展名自动识别：xml / json / ass。'
) -join "`r`n"
$pageAdv.Controls.Add($chkIgnoreWarnings)
$pageAdv.Controls.Add($chkForce)
$pageAdv.Controls.Add($lblDefaultConfig)
$pageAdv.Controls.Add($txtAdvice)

# ---------------------------------------------------------------------------
# 底部：命令行预览
# ---------------------------------------------------------------------------

$grpCommand = New-Group -Text '命令行预览（点击“运行”时执行的完整命令）' -X 12 -Y 502 -W 1206 -H 78
$grpCommand.Anchor = 'Top,Left,Right'
$form.Controls.Add($grpCommand)

$txtCommand = New-Object System.Windows.Forms.TextBox
$txtCommand.Location = [System.Drawing.Point]::new((Scaled 12), (Scaled 20))
$txtCommand.Size = [System.Drawing.Size]::new((Scaled 1028), (Scaled 48))
$txtCommand.Multiline = $true
$txtCommand.ReadOnly = $true
$txtCommand.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$txtCommand.BackColor = [System.Drawing.Color]::White
$txtCommand.Anchor = 'Top,Left,Right'
$grpCommand.Controls.Add($txtCommand)

$btnCopyCommand = New-Button -Text '复制命令' -X 1050 -Y 20 -W 144 -H 22
$btnRun = New-Button -Text '运行' -X 1050 -Y 46 -W 68 -H 22
$btnRun.BackColor = [System.Drawing.Color]::FromArgb(220, 240, 220)
$btnStop = New-Button -Text '停止' -X 1126 -Y 46 -W 68 -H 22
$btnStop.Enabled = $false
$btnCopyCommand.Anchor = 'Top,Right'
$btnRun.Anchor = 'Top,Right'
$btnStop.Anchor = 'Top,Right'
$grpCommand.Controls.Add($btnCopyCommand)
$grpCommand.Controls.Add($btnRun)
$grpCommand.Controls.Add($btnStop)

# ---------------------------------------------------------------------------
# 底部：运行日志
# ---------------------------------------------------------------------------

$grpLog = New-Group -Text '运行日志' -X 12 -Y 592 -W 1206 -H 120
$grpLog.Anchor = 'Top,Left,Right,Bottom'
$form.Controls.Add($grpLog)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = [System.Drawing.Point]::new((Scaled 12), (Scaled 20))
$txtLog.Size = [System.Drawing.Size]::new((Scaled 1182), (Scaled 88))
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
$txtLog.WordWrap = $false
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250)
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtLog.Anchor = 'Top,Left,Right,Bottom'
$grpLog.Controls.Add($txtLog)

$btnClearLog = New-Button -Text '清空日志' -X 1116 -Y 2 -W 84 -H 20
$btnClearLog.Anchor = 'Top,Right'
$grpLog.Controls.Add($btnClearLog)

# ---------------------------------------------------------------------------
# 逻辑：日志与命令生成
# ---------------------------------------------------------------------------

function Append-Log {
    param([string]$Text)
    $line = '[' + (Get-Date).ToString('HH:mm:ss') + '] ' + $Text
    $txtLog.AppendText($line + "`r`n")
}

function Get-BlockedNames {
    $names = New-Object System.Collections.Generic.List[string]
    if ($chkBlockL2R.Checked) { $names.Add('L2R') }
    if ($chkBlockR2L.Checked) { $names.Add('R2L') }
    if ($chkBlockTop.Checked) { $names.Add('TOP') }
    if ($chkBlockBottom.Checked) { $names.Add('BOTTOM') }
    if ($chkBlockSpecial.Checked) { $names.Add('SPECIAL') }
    if ($chkBlockColor.Checked) { $names.Add('COLOR') }
    if ($chkBlockRepeat.Checked) { $names.Add('REPEAT') }
    return $names
}

function Get-StatNames {
    $names = New-Object System.Collections.Generic.List[string]
    if ($chkStatTable.Checked) { $names.Add('TABLE') }
    if ($chkStatHistogram.Checked) { $names.Add('HISTOGRAM') }
    return $names
}

function Get-InputRows {
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($row in $gridInputs.Rows) {
        $shiftText = ''
        if ($null -ne $row.Cells[0].Value) { $shiftText = [string]$row.Cells[0].Value }
        $file = ''
        if ($null -ne $row.Cells[2].Value) { $file = [string]$row.Cells[2].Value }
        $rows.Add([pscustomobject]@{ ShiftText = $shiftText; File = $file })
    }
    return $rows
}

function Get-ArgumentString {
    $tokens = New-Object System.Collections.Generic.List[string]

    $out = $txtOutput.Text.Trim()
    $rows = @(Get-InputRows)

    if ($out -ne '') {
        $tokens.Add('-o')
        $tokens.Add((Quote-Arg $out))
    }
    if ($rows.Count -gt 0) {
        $tokens.Add('-i')
        foreach ($r in $rows) { $tokens.Add((Quote-Arg $r.File)) }
        $tokens.Add('-t')
        foreach ($r in $rows) {
            $d = 0.0
            if (Try-ParseDouble -Text $r.ShiftText -Result ([ref]$d)) {
                $tokens.Add($d.ToString('0.###', $script:Inv))
            } else {
                $tokens.Add('0')
            }
        }
    }

    $tokens.Add('-r');            $tokens.Add((Get-CoordArg $txtResolution.Text))
    $tokens.Add('--displayarea'); $tokens.Add((Fmt ([double]$numDisplayArea.Value) 2))
    $tokens.Add('--scrollarea');  $tokens.Add((Fmt ([double]$numScrollArea.Value) 2))
    $tokens.Add('-s');            $tokens.Add((Fmt ([double]$numScrollTime.Value) 1))
    $tokens.Add('-f');            $tokens.Add((Fmt ([double]$numFixTime.Value) 1))
    $tokens.Add('-d');            $tokens.Add(([int]$numDensity.Value).ToString($script:Inv))
    $tokens.Add('--line-spacing'); $tokens.Add(([int]$numLineSpacing.Value).ToString($script:Inv))
    $tokens.Add('--top-margin');  $tokens.Add(([int]$numTopMargin.Value).ToString($script:Inv))
    $tokens.Add('--bottom-margin'); $tokens.Add(([int]$numBottomMargin.Value).ToString($script:Inv))
    $tokens.Add('-S');            $tokens.Add(([int]$numFontsize.Value).ToString($script:Inv))
    $tokens.Add('-N');            $tokens.Add((Quote-Arg $cmbFont.Text.Trim()))
    $tokens.Add('-O');            $tokens.Add(([int]$numOpacity.Value).ToString($script:Inv))
    $tokens.Add('-L');            $tokens.Add((Fmt ([double]$numOutline.Value) 1))
    $tokens.Add('--outline-blur'); $tokens.Add((Fmt ([double]$numOutlineBlur.Value) 1))
    $tokens.Add('--outline-opacity'); $tokens.Add(([int]$numOutlineOpacity.Value).ToString($script:Inv))
    $tokens.Add('-D');            $tokens.Add((Fmt ([double]$numShadow.Value) 1))
    if ($chkBold.Checked) { $tokens.Add('-B'); $tokens.Add('true') }
    else { $tokens.Add('-B'); $tokens.Add('false') }
    if ($rdoFontStrict.Checked) { $tokens.Add('--font-size-strict') }
    elseif ($rdoFontNorm.Checked) { $tokens.Add('--font-size-norm') }
    $tokens.Add('--saveblocked')
    if ($chkSaveBlocked.Checked) { $tokens.Add('true') } else { $tokens.Add('false') }
    $tokens.Add('--showusernames')
    if ($chkShowUsernames.Checked) { $tokens.Add('true') } else { $tokens.Add('false') }
    $tokens.Add('--showmsgbox')
    if ($chkShowMsgbox.Checked) { $tokens.Add('true') } else { $tokens.Add('false') }
    $tokens.Add('--msgboxsize');    $tokens.Add((Get-CoordArg $txtMsgboxSize.Text))
    $tokens.Add('--msgboxpos');     $tokens.Add((Get-CoordArg $txtMsgboxPos.Text))
    $tokens.Add('--msgboxfontsize'); $tokens.Add(([int]$numMsgboxFontsize.Value).ToString($script:Inv))
    $tokens.Add('--msgboxduration'); $tokens.Add((Fmt ([double]$numMsgboxDuration.Value) 2))
    $tokens.Add('--giftminprice');   $tokens.Add((Fmt ([double]$numGiftMinPrice.Value) 2))

    $blocked = Get-BlockedNames
    if ($blocked.Count -gt 0) {
        $tokens.Add('-b')
        $tokens.Add(($blocked -join '-'))
    }
    $stat = Get-StatNames
    if ($stat.Count -gt 0) {
        $tokens.Add('--statmode')
        $tokens.Add(($stat -join '-'))
    }

    $blacklist = $txtBlacklist.Text.Trim()
    if ($blacklist -ne '') {
        $tokens.Add('--blacklist'); $tokens.Add((Quote-Arg $blacklist))
        if ($chkBlacklistRegex.Checked) { $tokens.Add('--blacklist-regex'); $tokens.Add('true') }
    }
    if ($chkIgnoreWarnings.Checked) { $tokens.Add('--ignore-warnings') }
    if ($chkForce.Checked) { $tokens.Add('--force') }

    return ($tokens -join ' ')
}

function Get-CommandLine {
    $exe = $txtExe.Text.Trim()
    if ($exe -eq '') { $exe = 'DanmakuFactory.exe' }
    $argString = Get-ArgumentString
    if ($argString -eq '') { return (Quote-Arg $exe) }
    return ((Quote-Arg $exe) + ' ' + $argString)
}

function Update-CommandPreview {
    if (-not $script:InitDone) { return }
    $txtCommand.Text = Get-CommandLine
    Update-DefaultConfigLabel
}

function Get-DefaultConfigPath {
    $exe = $txtExe.Text.Trim()
    if ($exe -eq '') { return '' }
    return [System.IO.Path]::Combine((Split-Path -Parent $exe), 'DanmakuFactoryConfig.json')
}

function Update-DefaultConfigLabel {
    $p = Get-DefaultConfigPath
    if ($p -eq '') { $lblDefaultConfig.Text = '默认配置文件：未设置程序路径' }
    else { $lblDefaultConfig.Text = '默认配置文件：' + $p }
}

# ---------------------------------------------------------------------------
# 逻辑：配置文件的读写
# ---------------------------------------------------------------------------

function Get-ConfigJson {
    $blockedLower = New-Object System.Collections.Generic.List[string]
    foreach ($name in (Get-BlockedNames)) {
        if ($name -eq 'L2R') { $blockedLower.Add('L2R') }
        elseif ($name -eq 'R2L') { $blockedLower.Add('R2L') }
        else { $blockedLower.Add($name.ToLowerInvariant()) }
    }
    $statLower = New-Object System.Collections.Generic.List[string]
    foreach ($name in (Get-StatNames)) { $statLower.Add($name.ToLowerInvariant()) }

    $font = $cmbFont.Text.Trim().Replace('\', '\\').Replace('"', '\"')
    $resolution = Get-CoordJsonArray -Text $txtResolution.Text -DefaultX 1920 -DefaultY 1080
    $msgboxSize = Get-CoordJsonArray -Text $txtMsgboxSize.Text -DefaultX 500 -DefaultY 1080
    $msgboxPos = Get-CoordJsonArray -Text $txtMsgboxPos.Text -DefaultX 20 -DefaultY 0

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('{')
    $lines.Add('    "resolution": ' + $resolution + ',')
    $lines.Add('    "displayArea": ' + (Fmt ([double]$numDisplayArea.Value) 6) + ',')
    $lines.Add('    "scrollArea": ' + (Fmt ([double]$numScrollArea.Value) 6) + ',')
    $lines.Add('    "scrolltime": ' + (Fmt ([double]$numScrollTime.Value) 3) + ',')
    $lines.Add('    "fixtime": ' + (Fmt ([double]$numFixTime.Value) 3) + ',')
    $lines.Add('    "density": ' + ([int]$numDensity.Value).ToString($script:Inv) + ',')
    $lines.Add('    "lineSpacing": ' + ([int]$numLineSpacing.Value).ToString($script:Inv) + ',')
    $lines.Add('    "topMargin": ' + ([int]$numTopMargin.Value).ToString($script:Inv) + ',')
    $lines.Add('    "bottomMargin": ' + ([int]$numBottomMargin.Value).ToString($script:Inv) + ',')
    $lines.Add('    "fontsize": ' + ([int]$numFontsize.Value).ToString($script:Inv) + ',')
    $lines.Add('    "fontname": "' + $font + '",')
    $lines.Add('    "opacity": ' + ([int]$numOpacity.Value).ToString($script:Inv) + ',')
    $lines.Add('    "outline": ' + (Fmt ([double]$numOutline.Value) 1) + ',')
    $lines.Add('    "shadow": ' + (Fmt ([double]$numShadow.Value) 1) + ',')
    if ($chkBold.Checked) { $lines.Add('    "bold": true,') } else { $lines.Add('    "bold": false,') }
    if ($chkSaveBlocked.Checked) { $lines.Add('    "saveblocked": true,') } else { $lines.Add('    "saveblocked": false,') }
    if ($chkShowUsernames.Checked) { $lines.Add('    "showUsernames": true,') } else { $lines.Add('    "showUsernames": false,') }
    if ($chkShowMsgbox.Checked) { $lines.Add('    "showMsgbox": true,') } else { $lines.Add('    "showMsgbox": false,') }
    $lines.Add('    "msgboxSize": ' + $msgboxSize + ',')
    $lines.Add('    "msgboxPos": ' + $msgboxPos + ',')
    $lines.Add('    "msgboxFontsize": ' + ([int]$numMsgboxFontsize.Value).ToString($script:Inv) + ',')
    $lines.Add('    "msgboxDuration": ' + (Fmt ([double]$numMsgboxDuration.Value) 2) + ',')
    $lines.Add('    "giftMinPrice": ' + (Fmt ([double]$numGiftMinPrice.Value) 2) + ',')
    $blockedQuoted = @()
    foreach ($name in $blockedLower) { $blockedQuoted += ('"' + $name + '"') }
    $statQuoted = @()
    foreach ($name in $statLower) { $statQuoted += ('"' + $name + '"') }
    $lines.Add('    "blockmode": [' + ($blockedQuoted -join ', ') + '],')
    $lines.Add('    "statmode": [' + ($statQuoted -join ', ') + ']')
    $lines.Add('}')
    return ($lines -join "`r`n")
}

function Save-ConfigFile {
    param([string]$Path)
    $json = Get-ConfigJson
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Set-NumValue {
    param($Control, $Value)
    if ($null -eq $Value) { return }
    $d = 0.0
    if (-not [double]::TryParse(([string]$Value), [System.Globalization.NumberStyles]::Float, $script:Inv, [ref]$d)) {
        if (-not [double]::TryParse(([string]$Value), [ref]$d)) { return }
    }
    if ($d -lt [double]$Control.Minimum) { $d = [double]$Control.Minimum }
    if ($d -gt [double]$Control.Maximum) { $d = [double]$Control.Maximum }
    $Control.Value = [decimal]$d
}

function Load-ConfigFile {
    param([string]$Path)
    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    # 兼容 DanmakuFactory 自己写出的非严格 JSON：blockmode/statmode 数组里是裸词
    $raw = [regex]::Replace(
        $raw,
        '("(?:blockmode|statmode)"\s*:\s*\[)([^\]]*)(\])',
        {
            param($m)
            $inner = $m.Groups[2].Value.Trim()
            if ($inner -eq '') { return $m.Groups[1].Value + $m.Groups[3].Value }
            $parts = @()
            foreach ($p in ($inner -split ',')) {
                $name = $p.Trim().Trim('"')
                if ($name -ne '') { $parts += ('"' + $name + '"') }
            }
            return $m.Groups[1].Value + ($parts -join ', ') + $m.Groups[3].Value
        },
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $obj = $raw | ConvertFrom-Json
    $map = @{}
    foreach ($prop in $obj.PSObject.Properties) {
        $map[$prop.Name.ToLowerInvariant()] = $prop.Value
    }

    if ($map.ContainsKey('resolution')) {
        $v = $map['resolution']
        if ($null -ne $v -and $v.Count -ge 2) {
            $txtResolution.Text = ([int]$v[0]).ToString($script:Inv) + 'x' + ([int]$v[1]).ToString($script:Inv)
        }
    }
    if ($map.ContainsKey('resx') -or $map.ContainsKey('resy')) {
        $coord = @(1920, 1080)
        $null = Try-ParseCoord -Text $txtResolution.Text -Result ([ref]$coord)
        if ($map.ContainsKey('resx')) { $coord[0] = [int]$map['resx'] }
        if ($map.ContainsKey('resy')) { $coord[1] = [int]$map['resy'] }
        $txtResolution.Text = $coord[0].ToString($script:Inv) + 'x' + $coord[1].ToString($script:Inv)
    }
    if ($map.ContainsKey('displayarea')) { Set-NumValue $numDisplayArea $map['displayarea'] }
    if ($map.ContainsKey('scrollarea')) { Set-NumValue $numScrollArea $map['scrollarea'] }
    if ($map.ContainsKey('scrolltime')) { Set-NumValue $numScrollTime $map['scrolltime'] }
    if ($map.ContainsKey('fixtime')) { Set-NumValue $numFixTime $map['fixtime'] }
    if ($map.ContainsKey('density')) { Set-NumValue $numDensity $map['density'] }
    if ($map.ContainsKey('linespacing')) { Set-NumValue $numLineSpacing $map['linespacing'] }
    if ($map.ContainsKey('topmargin')) { Set-NumValue $numTopMargin $map['topmargin'] }
    if ($map.ContainsKey('bottommargin')) { Set-NumValue $numBottomMargin $map['bottommargin'] }
    if ($map.ContainsKey('fontsize')) { Set-NumValue $numFontsize $map['fontsize'] }
    if ($map.ContainsKey('fontname')) { $cmbFont.Text = [string]$map['fontname'] }
    if ($map.ContainsKey('opacity')) { Set-NumValue $numOpacity $map['opacity'] }
    if ($map.ContainsKey('outline')) { Set-NumValue $numOutline $map['outline'] }
    if ($map.ContainsKey('outlineblur')) { Set-NumValue $numOutlineBlur $map['outlineblur'] }
    if ($map.ContainsKey('outlineopacity')) { Set-NumValue $numOutlineOpacity $map['outlineopacity'] }
    if ($map.ContainsKey('shadow')) { Set-NumValue $numShadow $map['shadow'] }
    if ($map.ContainsKey('bold')) { $chkBold.Checked = ToBool $map['bold'] }
    if ($map.ContainsKey('saveblocked')) { $chkSaveBlocked.Checked = ToBool $map['saveblocked'] }
    if ($map.ContainsKey('showusernames')) { $chkShowUsernames.Checked = ToBool $map['showusernames'] }
    if ($map.ContainsKey('showmsgbox')) { $chkShowMsgbox.Checked = ToBool $map['showmsgbox'] }
    if ($map.ContainsKey('msgboxsize')) {
        $v = $map['msgboxsize']
        if ($null -ne $v -and $v.Count -ge 2) {
            $txtMsgboxSize.Text = ([int]$v[0]).ToString($script:Inv) + 'x' + ([int]$v[1]).ToString($script:Inv)
        }
    }
    if ($map.ContainsKey('msgboxpos')) {
        $v = $map['msgboxpos']
        if ($null -ne $v -and $v.Count -ge 2) {
            $txtMsgboxPos.Text = ([int]$v[0]).ToString($script:Inv) + 'x' + ([int]$v[1]).ToString($script:Inv)
        }
    }
    if ($map.ContainsKey('msgboxfontsize')) { Set-NumValue $numMsgboxFontsize $map['msgboxfontsize'] }
    if ($map.ContainsKey('msgboxduration')) { Set-NumValue $numMsgboxDuration $map['msgboxduration'] }
    if ($map.ContainsKey('giftminprice')) { Set-NumValue $numGiftMinPrice $map['giftminprice'] }
    if ($map.ContainsKey('blockmode')) {
        $names = @($map['blockmode'])
        $chkBlockL2R.Checked = ($names -contains 'L2R' -or $names -contains 'l2r')
        $chkBlockR2L.Checked = ($names -contains 'R2L' -or $names -contains 'r2l')
        $chkBlockTop.Checked = ($names -contains 'top' -or $names -contains 'TOP')
        $chkBlockBottom.Checked = ($names -contains 'bottom' -or $names -contains 'BOTTOM')
        $chkBlockSpecial.Checked = ($names -contains 'special' -or $names -contains 'SPECIAL')
        $chkBlockColor.Checked = ($names -contains 'color' -or $names -contains 'COLOR')
        $chkBlockRepeat.Checked = ($names -contains 'repeat' -or $names -contains 'REPEAT')
    }
    if ($map.ContainsKey('statmode')) {
        $names = @($map['statmode'])
        $chkStatTable.Checked = ($names -contains 'table' -or $names -contains 'TABLE')
        $chkStatHistogram.Checked = ($names -contains 'histogram' -or $names -contains 'HISTOGRAM')
    }
    if ($map.ContainsKey('blacklist')) { $txtBlacklist.Text = [string]$map['blacklist'] }
    if ($map.ContainsKey('blacklistregex')) { $chkBlacklistRegex.Checked = ToBool $map['blacklistregex'] }
}

function Reset-ToDefaults {
    $d = $script:Defaults
    $txtResolution.Text = $d.Resolution
    Set-NumValue $numDisplayArea $d.DisplayArea
    Set-NumValue $numScrollArea $d.ScrollArea
    Set-NumValue $numScrollTime $d.ScrollTime
    Set-NumValue $numFixTime $d.FixTime
    Set-NumValue $numDensity $d.Density
    Set-NumValue $numLineSpacing $d.LineSpacing
    Set-NumValue $numTopMargin $d.TopMargin
    Set-NumValue $numBottomMargin $d.BottomMargin
    Set-NumValue $numFontsize $d.Fontsize
    $cmbFont.Text = $d.Fontname
    Set-NumValue $numOpacity $d.Opacity
    Set-NumValue $numOutline $d.Outline
    Set-NumValue $numOutlineBlur $d.OutlineBlur
    Set-NumValue $numOutlineOpacity $d.OutlineOpacity
    Set-NumValue $numShadow $d.Shadow
    $chkBold.Checked = $d.Bold
    $rdoFontDefault.Checked = $true
    $chkSaveBlocked.Checked = $d.SaveBlocked
    $chkShowUsernames.Checked = $d.ShowUsernames
    $chkShowMsgbox.Checked = $d.ShowMsgbox
    $txtMsgboxSize.Text = $d.MsgboxSize
    $txtMsgboxPos.Text = $d.MsgboxPos
    Set-NumValue $numMsgboxFontsize $d.MsgboxFontsize
    Set-NumValue $numMsgboxDuration $d.MsgboxDuration
    Set-NumValue $numGiftMinPrice $d.GiftMinPrice
    $chkBlockL2R.Checked = $false
    $chkBlockR2L.Checked = $false
    $chkBlockTop.Checked = $false
    $chkBlockBottom.Checked = $false
    $chkBlockSpecial.Checked = $false
    $chkBlockColor.Checked = $false
    $chkBlockRepeat.Checked = $false
    $chkStatTable.Checked = $false
    $chkStatHistogram.Checked = $false
    $txtBlacklist.Text = ''
    $chkBlacklistRegex.Checked = $false
    $chkIgnoreWarnings.Checked = $d.IgnoreWarnings
    $chkForce.Checked = $d.Force
}

# ---------------------------------------------------------------------------
# 逻辑：输入文件列表
# ---------------------------------------------------------------------------

function Add-InputFile {
    param([string]$Path)
    $fmt = Get-DisplayFormat $Path
    $label = '未知'
    if ($fmt -ne '') { $label = $fmt.ToUpperInvariant() }
    $index = $gridInputs.Rows.Add('0', $label, $Path)
    $gridInputs.Rows[$index].Cells[2].ToolTipText = $Path
}

# ---------------------------------------------------------------------------
# 逻辑：校验与运行
# ---------------------------------------------------------------------------

function Get-ValidationErrors {
    $errs = New-Object System.Collections.Generic.List[string]

    $exe = $txtExe.Text.Trim()
    if ($exe -eq '') { $errs.Add('请指定 DanmakuFactory.exe 路径。') }
    elseif (-not (Test-Path -LiteralPath $exe)) { $errs.Add('程序不存在：' + $exe) }

    $rows = @(Get-InputRows)
    if ($rows.Count -eq 0) { $errs.Add('请至少添加一个输入文件。') }
    foreach ($r in $rows) {
        if (-not (Test-Path -LiteralPath $r.File)) { $errs.Add('输入文件不存在：' + $r.File) }
        if ((Get-DisplayFormat $r.File) -eq '') { $errs.Add('无法识别输入文件格式（应为 .xml/.json/.ass）：' + $r.File) }
        $d = 0.0
        if (-not (Try-ParseDouble -Text $r.ShiftText -Result ([ref]$d))) {
            $errs.Add('时间偏移不是数字：' + $r.ShiftText)
        }
    }

    $out = $txtOutput.Text.Trim()
    if ($out -eq '') { $errs.Add('请指定输出文件。') }
    elseif ((Get-DisplayFormat $out) -eq '') { $errs.Add('输出文件扩展名应为 .ass/.xml/.json。') }

    $coord = @(0, 0)
    if (-not (Try-ParseCoord -Text $txtResolution.Text -Result ([ref]$coord))) {
        $errs.Add('分辨率格式不正确，例如 1920x1080。')
    }
    if (-not (Try-ParseCoord -Text $txtMsgboxSize.Text -Result ([ref]$coord))) {
        $errs.Add('礼物框尺寸格式不正确，例如 500x1080。')
    }
    if (-not (Try-ParseCoord -Text $txtMsgboxPos.Text -Result ([ref]$coord))) {
        $errs.Add('礼物框位置格式不正确，例如 20x0。')
    }
    $blacklist = $txtBlacklist.Text.Trim()
    if ($blacklist -ne '' -and -not (Test-Path -LiteralPath $blacklist)) {
        $errs.Add('黑名单文件不存在：' + $blacklist)
    }
    return $errs
}

function Set-RunningState {
    param([bool]$Running)
    $btnRun.Enabled = -not $Running
    $btnStop.Enabled = $Running
    $btnCopyCommand.Enabled = -not $Running
    $btnSaveConfig.Enabled = -not $Running
    $btnSaveDefault.Enabled = -not $Running
    $btnMakeBat.Enabled = -not $Running
}

function Read-TextShared {
    # 与正在写入的进程共享读取。
    # cmd 的 ">" 重定向句柄是独占写模式，File.ReadAllText（FileShare.Read）会共享冲突，
    # 导致运行期间读不到输出、只能在结束后一次性读到。这里显式用 FileShare.ReadWrite。
    param([string]$Path)
    if ($Path -eq '' -or -not (Test-Path -LiteralPath $Path)) { return '' }
    $fs = $null
    $sr = $null
    try {
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        return $sr.ReadToEnd()
    } catch {
        return ''
    } finally {
        if ($null -ne $sr) { try { $sr.Dispose() } catch { } }
        elseif ($null -ne $fs) { try { $fs.Dispose() } catch { } }
    }
}

function Read-NewOutput {
    param([string]$Path, [ref]$Shown, [ref]$Tail)
    if ($Path -eq '' -or -not (Test-Path -LiteralPath $Path)) { return '' }
    $text = Read-TextShared -Path $Path
    if ($text.Length -le $Shown.Value) { return '' }
    $new = $text.Substring($Shown.Value)
    $Shown.Value = $text.Length
    $all = $Tail.Value + $new
    $lastLf = $all.LastIndexOf("`n")
    if ($lastLf -lt 0) {
        $Tail.Value = $all
        return ''
    }
    $complete = $all.Substring(0, $lastLf + 1)
    $Tail.Value = $all.Substring($lastLf + 1)
    return $complete
}

function Update-RunOutput {
    try {
        if ($null -eq $script:Proc) { return }
        $out = Read-NewOutput -Path $script:RunOutFile -Shown ([ref]$script:RunOutShown) -Tail ([ref]$script:RunOutTail)
        if ($out -ne '') { $txtLog.AppendText((Normalize-Newlines $out)) }
        $err = Read-NewOutput -Path $script:RunErrFile -Shown ([ref]$script:RunErrShown) -Tail ([ref]$script:RunErrTail)
        if ($err -ne '') { $txtLog.AppendText((Normalize-Newlines $err)) }

        if ($script:Proc.HasExited) {
            $script:RunTimer.Stop()
            # 收尾：把已读取的完整行与最后一段未换行的尾巴输出到日志
            $rest = Read-NewOutput -Path $script:RunOutFile -Shown ([ref]$script:RunOutShown) -Tail ([ref]$script:RunOutTail)
            if ($rest -ne '') { $txtLog.AppendText((Normalize-Newlines $rest)) }
            if ($script:RunOutTail -ne '') { $txtLog.AppendText((Normalize-Newlines $script:RunOutTail)) }
            $script:RunOutTail = ''
            $restErr = Read-NewOutput -Path $script:RunErrFile -Shown ([ref]$script:RunErrShown) -Tail ([ref]$script:RunErrTail)
            if ($restErr -ne '') { $txtLog.AppendText((Normalize-Newlines $restErr)) }
            if ($script:RunErrTail -ne '') { $txtLog.AppendText((Normalize-Newlines $script:RunErrTail)) }
            $script:RunErrTail = ''
            $code = '?'
            try {
                if ($script:RunExitFile -ne '' -and (Test-Path -LiteralPath $script:RunExitFile)) {
                    $rawCode = [System.IO.File]::ReadAllText($script:RunExitFile).Trim()
                    if ($rawCode -ne '') { $code = [int]$rawCode }
                }
            } catch { }
            Append-Log ('运行结束，退出代码 ' + $code)
            # 退出码为 0 也可能代表失败（例如输入文件缺失），再检查输出文件是否真正生成
            try {
                $outputOk = $false
                if (Test-Path -LiteralPath $script:RunOutputPath) {
                    $newStamp = (Get-Item -LiteralPath $script:RunOutputPath).LastWriteTimeUtc
                    if ($null -eq $script:RunOutputStamp -or $newStamp -ne $script:RunOutputStamp) { $outputOk = $true }
                }
                if (-not $outputOk) {
                    Append-Log ('注意：未检测到输出文件生成或更新（' + $script:RunOutputPath + '），请检查上方日志中的 ERROR 提示。')
                }
            } catch { }
            foreach ($f in @($script:RunOutFile, $script:RunErrFile, $script:RunExitFile, $script:RunBatFile)) {
                if ($f -ne '' -and (Test-Path -LiteralPath $f)) {
                    Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
                }
            }
            $script:RunOutFile = ''
            $script:RunErrFile = ''
            $script:RunExitFile = ''
            $script:RunBatFile = ''
            $script:Proc = $null
            Set-RunningState -Running $false
            if ([Environment]::GetEnvironmentVariable('DANMAKU_GUI_SELFTEST_INPUT')) {
                Write-SelfTest ('SELFTEST-RUN-DONE exit=' + $code)
                try { Write-SelfTest ('SELFTEST-LOG-BEGIN' + "`r`n" + $txtLog.Text + 'SELFTEST-LOG-END') } catch { }
                $form.Close()
            }
        }
    } catch {
        try { Append-Log ('运行时错误：' + $_.Exception.Message) } catch { }
        try { $script:RunTimer.Stop() } catch { }
        try { Stop-ProcessTree $script:Proc } catch { }
        $script:Proc = $null
        try { Set-RunningState -Running $false } catch { }
        if ([Environment]::GetEnvironmentVariable('DANMAKU_GUI_SELFTEST_INPUT')) {
            try { $form.Close() } catch { }
        }
    }
}

function Start-Run {
    $errs = @(Get-ValidationErrors)
    if ($errs.Count -gt 0) {
        $msg = '无法运行：' + "`r`n`r`n" + ($errs -join "`r`n")
        [void][System.Windows.Forms.MessageBox]::Show($form, $msg, $script:AppTitle, 'OK', 'Warning')
        Append-Log '参数校验失败：'
        foreach ($e in $errs) { Append-Log ('  - ' + $e) }
        return
    }

    $out = $txtOutput.Text.Trim()
    if ((Test-Path -LiteralPath $out) -and -not $chkForce.Checked -and -not $chkIgnoreWarnings.Checked) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            $form,
            '输出文件已存在，且未启用“忽略警告 / 强制覆盖”，程序可能会等待确认输入而卡住。仍要继续吗？',
            $script:AppTitle, 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }
    }

    $exe = $txtExe.Text.Trim()
    $txtCommand.Text = Get-CommandLine
    $script:RunOutputPath = $out
    $script:RunOutputStamp = $null
    try {
        if (Test-Path -LiteralPath $out) {
            $script:RunOutputStamp = (Get-Item -LiteralPath $out).LastWriteTimeUtc
        }
    } catch { }
    $script:RunOutFile = [System.IO.Path]::GetTempFileName()
    $script:RunErrFile = [System.IO.Path]::GetTempFileName()
    $script:RunExitFile = [System.IO.Path]::GetTempFileName()
    $script:RunBatFile = [System.IO.Path]::GetTempFileName() + '.bat'
    $script:RunOutShown = 0
    $script:RunErrShown = 0
    $script:RunOutTail = ''
    $script:RunErrTail = ''

    # 通过临时 .bat 运行：可以稳定获取退出码，也便于整棵进程树一起停止
    $batLines = @(
        '@echo off'
        'chcp 65001 >nul'
        (Get-CommandLine) + ' 1>"' + $script:RunOutFile + '" 2>"' + $script:RunErrFile + '"'
        'echo %ERRORLEVEL% >"' + $script:RunExitFile + '"'
    )
    # 必须用带 BOM 的 UTF-8 写入，cmd.exe 才能正确读取中文路径
    [System.IO.File]::WriteAllText($script:RunBatFile, (($batLines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($true)))

    Append-Log ('开始运行：' + $exe)
    Append-Log ('工作目录：' + (Split-Path -Parent $exe))
    try {
        $script:Proc = Start-Process -FilePath $script:RunBatFile -WorkingDirectory (Split-Path -Parent $exe) -PassThru -WindowStyle Hidden
    } catch {
        Append-Log ('启动失败：' + $_.Exception.Message)
        $script:Proc = $null
        return
    }
    Set-RunningState -Running $true
    $script:RunTimer.Start()
}

function Stop-ProcessTree {
    param($Process)
    if ($null -eq $Process) { return }
    try {
        if (-not $Process.HasExited) {
            & taskkill.exe /PID $Process.Id /T /F 2>&1 | Out-Null
        }
    } catch { }
}

function Stop-Run {
    if ($null -ne $script:Proc -and -not $script:Proc.HasExited) {
        try {
            Stop-ProcessTree $script:Proc
            Append-Log '已请求停止进程。'
        } catch {
            Append-Log ('停止失败：' + $_.Exception.Message)
        }
    }
}

# ---------------------------------------------------------------------------
# 事件绑定
# ---------------------------------------------------------------------------

$script:updateHandler = { Update-CommandPreview }

function Register-LiveUpdate {
    param($Root)
    foreach ($c in $Root.Controls) {
        if ($c -is [System.Windows.Forms.TextBox] -or $c -is [System.Windows.Forms.ComboBox]) {
            $c.Add_TextChanged($script:updateHandler)
        } elseif ($c -is [System.Windows.Forms.NumericUpDown]) {
            $c.Add_ValueChanged($script:updateHandler)
        } elseif ($c -is [System.Windows.Forms.CheckBox] -or $c -is [System.Windows.Forms.RadioButton]) {
            $c.Add_CheckedChanged($script:updateHandler)
        } elseif ($c -is [System.Windows.Forms.DataGridView]) {
            $c.Add_CellValueChanged($script:updateHandler)
            $c.Add_RowsAdded($script:updateHandler)
            $c.Add_RowsRemoved($script:updateHandler)
        }
        if ($c.HasChildren) { Register-LiveUpdate $c }
    }
}

$btnAddInput.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = '选择输入弹幕文件（可多选）'
    $dlg.Filter = '弹幕文件 (*.xml;*.json;*.ass)|*.xml;*.json;*.ass|所有文件 (*.*)|*.*'
    $dlg.Multiselect = $true
    if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        foreach ($f in $dlg.FileNames) { Add-InputFile $f }
        if ($txtOutput.Text.Trim() -eq '' -and $dlg.FileNames.Count -gt 0) {
            $dir = Split-Path -Parent $dlg.FileNames[0]
            $base = [System.IO.Path]::GetFileNameWithoutExtension($dlg.FileNames[0])
            $txtOutput.Text = [System.IO.Path]::Combine($dir, $base + '.ass')
        }
    }
})

$btnRemoveInput.Add_Click({
    $rows = @($gridInputs.SelectedRows | Sort-Object Index -Descending)
    foreach ($row in $rows) { $gridInputs.Rows.Remove($row) }
})

$btnClearInputs.Add_Click({
    $gridInputs.Rows.Clear()
})

$btnBrowseOutput.Add_Click({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Title = '选择输出文件'
    $dlg.Filter = 'ASS 字幕 (*.ass)|*.ass|XML 弹幕 (*.xml)|*.xml|JSON 弹幕 (*.json)|*.json|所有文件 (*.*)|*.*'
    $dlg.FileName = 'danmaku.ass'
    if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtOutput.Text = $dlg.FileName
    }
})

$btnBrowseExe.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = '选择 DanmakuFactory.exe'
    $dlg.Filter = 'DanmakuFactory (DanmakuFactory.exe)|DanmakuFactory.exe|可执行文件 (*.exe)|*.exe|所有文件 (*.*)|*.*'
    $current = $txtExe.Text.Trim()
    if ($current -ne '' -and (Test-Path -LiteralPath (Split-Path -Parent $current))) {
        $dlg.InitialDirectory = Split-Path -Parent $current
    }
    if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtExe.Text = $dlg.FileName
        $defaultCfg = Get-DefaultConfigPath
        if ($defaultCfg -ne '' -and (Test-Path -LiteralPath $defaultCfg)) {
            $answer = [System.Windows.Forms.MessageBox]::Show($form, '检测到该程序目录下已有默认配置文件，是否载入？', $script:AppTitle, 'YesNo', 'Question')
            if ($answer -eq 'Yes') {
                try { Load-ConfigFile $defaultCfg; Append-Log ('已载入默认配置：' + $defaultCfg) }
                catch { Append-Log ('载入默认配置失败：' + $_.Exception.Message) }
            }
        }
    }
})

$btnBrowseBlacklist.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = '选择黑名单文件'
    $dlg.Filter = '文本文件 (*.txt)|*.txt|所有文件 (*.*)|*.*'
    if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtBlacklist.Text = $dlg.FileName
    }
})

$btnCopyCommand.Add_Click({
    $txtCommand.Text = Get-CommandLine
    try {
        [System.Windows.Forms.Clipboard]::SetText($txtCommand.Text)
        Append-Log '命令已复制到剪贴板。'
    } catch {
        Append-Log ('复制失败：' + $_.Exception.Message)
    }
})

$btnLoadConfig.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = '加载配置文件'
    $dlg.Filter = '配置文件 (*.json)|*.json|所有文件 (*.*)|*.*'
    $exe = $txtExe.Text.Trim()
    if ($exe -ne '') { $dlg.InitialDirectory = Split-Path -Parent $exe }
    if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            Load-ConfigFile $dlg.FileName
            Append-Log ('已加载配置：' + $dlg.FileName)
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show($form, ('加载配置失败：' + $_.Exception.Message), $script:AppTitle, 'OK', 'Error')
            Append-Log ('加载配置失败：' + $_.Exception.Message)
        }
    }
})

$btnSaveConfig.Add_Click({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Title = '保存配置文件'
    $dlg.Filter = '配置文件 (*.json)|*.json'
    $dlg.FileName = 'DanmakuFactoryConfig.json'
    $exe = $txtExe.Text.Trim()
    if ($exe -ne '') { $dlg.InitialDirectory = Split-Path -Parent $exe }
    if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            Save-ConfigFile $dlg.FileName
            Append-Log ('配置已保存：' + $dlg.FileName)
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show($form, ('保存配置失败：' + $_.Exception.Message), $script:AppTitle, 'OK', 'Error')
            Append-Log ('保存配置失败：' + $_.Exception.Message)
        }
    }
})

$btnSaveDefault.Add_Click({
    $path = Get-DefaultConfigPath
    if ($path -eq '') {
        [void][System.Windows.Forms.MessageBox]::Show($form, '请先指定 DanmakuFactory.exe 路径。', $script:AppTitle, 'OK', 'Warning')
        return
    }
    if (Test-Path -LiteralPath $path) {
        $answer = [System.Windows.Forms.MessageBox]::Show($form, ('默认配置文件已存在，是否覆盖？' + "`r`n`r`n" + $path), $script:AppTitle, 'YesNo', 'Question')
        if ($answer -ne 'Yes') { return }
    }
    try {
        Save-ConfigFile $path
        Append-Log ('已保存默认配置：' + $path)
        [void][System.Windows.Forms.MessageBox]::Show($form, ('已保存。' + "`r`n`r`n" + '以后直接运行 DanmakuFactory.exe 也会使用这些参数。'), $script:AppTitle, 'OK', 'Information')
    } catch {
        Append-Log ('保存默认配置失败：' + $_.Exception.Message)
        [void][System.Windows.Forms.MessageBox]::Show($form, ('保存失败：' + $_.Exception.Message), $script:AppTitle, 'OK', 'Error')
    }
})

$btnMakeBat.Add_Click({
    $errs = @(Get-ValidationErrors)
    if ($errs.Count -gt 0) {
        $msg = '当前参数无法生成可运行脚本：' + "`r`n`r`n" + ($errs -join "`r`n")
        [void][System.Windows.Forms.MessageBox]::Show($form, $msg, $script:AppTitle, 'OK', 'Warning')
        return
    }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Title = '生成运行脚本'
    $dlg.Filter = '批处理脚本 (*.bat)|*.bat'
    $dlg.FileName = '运行DanmakuFactory.bat'
    if ($dlg.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $cmd = Get-CommandLine
    $bat = @()
    $bat += '@echo off'
    $bat += 'chcp 65001 >nul'
    $bat += 'cd /d "%~dp0"'
    $bat += $cmd
    $bat += 'echo.'
    $bat += 'echo Exit code: %ERRORLEVEL%'
    $bat += 'pause'
    try {
        # 带 BOM 的 UTF-8：cmd.exe 可正确读取含中文路径的运行脚本
        [System.IO.File]::WriteAllText($dlg.FileName, (($bat -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
        Append-Log ('运行脚本已生成：' + $dlg.FileName)
    } catch {
        Append-Log ('生成脚本失败：' + $_.Exception.Message)
        [void][System.Windows.Forms.MessageBox]::Show($form, ('生成脚本失败：' + $_.Exception.Message), $script:AppTitle, 'OK', 'Error')
    }
})

$btnReset.Add_Click({
    Reset-ToDefaults
    Append-Log '已重置为默认参数。'
})

$btnOpenDir.Add_Click({
    $exe = $txtExe.Text.Trim()
    if ($exe -eq '' -or -not (Test-Path -LiteralPath $exe)) {
        [void][System.Windows.Forms.MessageBox]::Show($form, '请先指定有效的 DanmakuFactory.exe 路径。', $script:AppTitle, 'OK', 'Warning')
        return
    }
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + (Split-Path -Parent $exe) + '"')
})

$btnClearLog.Add_Click({ $txtLog.Clear() })
$btnRun.Add_Click({ Start-Run })
$btnStop.Add_Click({ Stop-Run })

$script:RunTimer = New-Object System.Windows.Forms.Timer
$script:RunTimer.Interval = 250
$script:RunTimer.Add_Tick({ Update-RunOutput })

# 全局兜底：界面事件中的未处理异常记录到日志，避免弹出 JIT 调试对话框
try {
    [System.Windows.Forms.Application]::add_ThreadException({
        param($sender, $e)
        $msg = '界面出现未处理的错误：' + $e.Exception.Message
        try { Append-Log $msg } catch { }
        try { Append-Log $e.Exception.ToString() } catch { }
        try { [void][System.Windows.Forms.MessageBox]::Show($form, $msg, $script:AppTitle, 'OK', 'Error') } catch { }
    })
} catch { }

$form.Add_FormClosing({
    if ($null -ne $script:Proc -and -not $script:Proc.HasExited) {
        try { Stop-ProcessTree $script:Proc } catch { }
    }
})

# 高 DPI 下若窗口超出工作区（例如小屏 + 150% 缩放），自动最大化避免底部被裁掉
$form.Add_Shown({
    try {
        $workArea = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
        if ($form.Width -gt $workArea.Width -or $form.Height -gt $workArea.Height) {
            $form.WindowState = [System.Windows.Forms.FormWindowState]::Maximized
        }
    } catch { }
    Update-MainLayout
    Update-FollowLayout
})

# 快捷键：Ctrl+Enter 运行，Ctrl+S 保存为默认配置
$form.Add_KeyDown({
    param($sender, $e)
    if ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { Start-Run }
    elseif ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::S) { $btnSaveDefault.PerformClick() }
})

# ---------------------------------------------------------------------------
# 初始化
# ---------------------------------------------------------------------------

# TabPage 内需要跟随宽度的控件（显式布局，见 Register-Follow 说明）
Register-Follow $lblResHint 302 240 -Stretch $true
Register-Follow $lblScrollArea 288 128
Register-Follow $numScrollArea 420 110
Register-Follow $lblFixTime 288 128
Register-Follow $numFixTime 420 110
Register-Follow $lblLineSpacing 288 128
Register-Follow $numLineSpacing 420 110
Register-Follow $lblBottomMargin 288 128
Register-Follow $numBottomMargin 420 110
Register-Follow $hintBasic1 12 530 -Stretch $true
Register-Follow $hintBasic2 12 530 -Stretch $true
Register-Follow $chkBold 420 120
Register-Follow $cmbFont 134 396 -Stretch $true
Register-Follow $lblOutlineOpacity 288 128
Register-Follow $numOutlineOpacity 420 110
Register-Follow $lblOutlineBlur 288 128
Register-Follow $numOutlineBlur 420 110
Register-Follow $hintStyle 12 530 -Stretch $true
Register-Follow $chkShowMsgbox 420 130
Register-Follow $hintMsgboxSize 302 240 -Stretch $true
Register-Follow $hintMsgboxPos 302 240 -Stretch $true
Register-Follow $lblMsgboxDuration 288 128
Register-Follow $numMsgboxDuration 420 110
Register-Follow $hintMsgboxDuration 12 530 -Stretch $true
Register-Follow $chkBlockBottom 440 110
Register-Follow $chkBlockRepeat 356 120
Register-Follow $chkBlacklistRegex 420 150
Register-Follow $txtBlacklist 134 300 -Stretch $true
Register-Follow $btnBrowseBlacklist 440 90
Register-Follow $hintBlacklist 12 530 -Stretch $true
Register-Follow $lblDefaultConfig 12 530 -Stretch $true
Register-Follow $txtAdvice 12 530 -Stretch $true

Update-FollowLayout
Update-MainLayout
$form.Add_Resize({ Update-FollowLayout })
$form.Add_Resize({ Update-MainLayout })
$tabs.Add_Resize({ Update-FollowLayout })
$tabs.Add_SelectedIndexChanged({ Update-FollowLayout })

Register-LiveUpdate $form
Reset-ToDefaults

# 自动定位 exe：脚本目录 -> 上级目录
$exeCandidates = @(
    [System.IO.Path]::Combine($script:ScriptDir, 'DanmakuFactory.exe'),
    [System.IO.Path]::Combine((Split-Path -Parent $script:ScriptDir), 'DanmakuFactory.exe')
)
foreach ($candidate in $exeCandidates) {
    if (Test-Path -LiteralPath $candidate) {
        $txtExe.Text = $candidate
        break
    }
}

# 自动载入 exe 同目录的默认配置
$defaultConfig = Get-DefaultConfigPath
if ($defaultConfig -ne '' -and (Test-Path -LiteralPath $defaultConfig)) {
    try {
        Load-ConfigFile $defaultConfig
        $script:LoadedDefaultConfig = $defaultConfig
    } catch {
        $script:LoadedDefaultConfig = $null
        $script:LoadedDefaultConfigError = $_.Exception.Message
    }
}

$script:InitDone = $true
Update-CommandPreview

Append-Log '欢迎使用 DanmakuFactory 参数配置 GUI。'
if ($txtExe.Text.Trim() -ne '') { Append-Log ('程序路径：' + $txtExe.Text.Trim()) }
else { Append-Log '未找到 DanmakuFactory.exe，请手动指定程序路径。' }
if ($script:LoadedDefaultConfig) { Append-Log ('已载入默认配置：' + $script:LoadedDefaultConfig) }
elseif ($script:LoadedDefaultConfigError) { Append-Log ('默认配置解析失败（已使用内置默认值）：' + $script:LoadedDefaultConfigError) }
Append-Log '提示：Ctrl+Enter 直接运行，Ctrl+S 保存为默认配置。'

# ---------------------------------------------------------------------------
# 显示（SelfTestShot 仅供开发自检：截图后退出）
# ---------------------------------------------------------------------------

if ($SelfTestShot -ne '') {
    $form.TopMost = $true
    $script:ShotTimer = New-Object System.Windows.Forms.Timer
    $script:ShotTimer.Interval = 1500
    $script:ShotTimer.Add_Tick({
        $script:ShotTimer.Stop()
        try {
            $testTab = [Environment]::GetEnvironmentVariable('DANMAKU_GUI_SELFTEST_TAB')
            if ($testTab) { try { $tabs.SelectedIndex = [int]$testTab } catch { } }
            $testWidth = [Environment]::GetEnvironmentVariable('DANMAKU_GUI_SELFTEST_WIDTH')
            if ($testWidth) { try { $form.Width = [int]$testWidth } catch { } }
            # 直接渲染窗体（避免 DPI 虚拟化下的屏幕截图裁剪问题）
            $shotW = [int]$form.ClientSize.Width
            $shotH = [int]$form.ClientSize.Height
            $bmp = New-Object System.Drawing.Bitmap($shotW, $shotH)
            $form.DrawToBitmap($bmp, ([System.Drawing.Rectangle]::new(0, 0, $shotW, $shotH)))
            $bmp.Save($SelfTestShot, [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
            Write-SelfTest ('SELFTEST-SHOT-OK ' + $SelfTestShot)
            Write-SelfTest ('SELFTEST-GEOMETRY scale=' + $script:UiScale + ' client=' + $form.ClientSize.ToString() + ' bounds=' + $form.Bounds.ToString() + ' screen=' + [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.ToString() + ' logBottom=' + ($grpLog.Top + $grpLog.Height))
        } catch {
            Write-SelfTest ('SELFTEST-SHOT-FAIL ' + $_.Exception.Message)
        }
        try {
            Write-SelfTest ('SELFTEST-COMMAND ' + (Get-CommandLine))
        } catch {
            Write-SelfTest ('SELFTEST-COMMAND-FAIL ' + $_.Exception.Message)
        }

        $testInput = [Environment]::GetEnvironmentVariable('DANMAKU_GUI_SELFTEST_INPUT')
        if ($testInput) {
            try {
                $testConfig = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'danmaku_gui_selftest.json')
                Save-ConfigFile $testConfig
                Write-SelfTest ('SELFTEST-CONFIG-SAVED ' + $testConfig)
                Add-InputFile $testInput
                $testOutput = [Environment]::GetEnvironmentVariable('DANMAKU_GUI_SELFTEST_OUTPUT')
                if (-not $testOutput) {
                    $testOutput = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'danmaku_gui_selftest.ass')
                }
                $txtOutput.Text = $testOutput
                if (Test-Path -LiteralPath $txtOutput.Text) {
                    Remove-Item -LiteralPath $txtOutput.Text -Force -ErrorAction SilentlyContinue
                }
                $testErrors = @(Get-ValidationErrors)
                if ($testErrors.Count -gt 0) {
                    Write-SelfTest ('SELFTEST-RUN-INVALID ' + ($testErrors -join ' | '))
                    $form.Close()
                } else {
                    Write-SelfTest ('SELFTEST-RUN-START ' + $txtOutput.Text)
                    Start-Run
                }
            } catch {
                Write-SelfTest ('SELFTEST-RUN-EXCEPTION ' + $_.Exception.Message)
                $form.Close()
            }
        } else {
            $form.Close()
        }
    })
    $script:ShotTimer.Start()
}

[void]$form.ShowDialog()
$form.Dispose()
