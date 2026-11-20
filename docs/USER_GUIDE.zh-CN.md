# QuickBounce V0.7.4

by Huang Wenjie

QuickBounce 帮你把 Pro Tools 里的不同混音版本一次导出，并快速检查导出的文件。

V0.7.4（49）在 MOV 预览右上角加入全屏按钮。

## 安装

按[源码构建说明](BUILDING.md)生成 `QuickBounce V0.7.4.app` 后，可以直接打开，或将它拖到“应用程序”文件夹。构建产物包含本地提供的 PTSL 框架。

稳定支持 **Pro Tools 2025.12 及以上**，使用时请保持 Pro Tools 打开。2024.03–2025.10 为实验性兼容。部分功能取决于 Pro Tools 版本，连接时会提示不可用的功能。

系统要求：macOS 14 或更新版本；支持 Apple 芯片和 Intel Mac。

## 最简单的使用方法

1. 打开 Pro Tools 和要处理的 Session。
2. 在 Pro Tools 里做好 Solo/Mute，并选好时间范围。
3. 回到 QuickBounce，点 **Add Mix**，给这个版本起个名字。
   如果想先核对这个版本，可在左侧 Mix 列表该行点击 **Check**。QuickBounce 会在 Pro Tools 中同时显示该 Mix 保存的 Solo/Mute 和时间选区；再次点击同一按钮即可恢复 Check 前的状态。
4. 在 **Bounce Settings** 里选择 WAV、MP3 或 MOV，确认导出文件夹，然后点 **Bounce Mixes**。
5. 导出完成后，在右侧列表检查文件；需要时点 **Open Bounced Files** 打开本批次的导出文件夹。

每个 Mix 都可以单独设置格式、采样率、位深、离线/实时导出、是否补齐视频帧边界和保存位置。默认使用离线导出；取消勾选 **Offline Bounce** 会改为实时导出。勾选 **Pad To Frame Boundary** 时，文件首尾会补齐到完整视频帧，QuickBounce 会按当前 Session 帧率检查补齐后的时长。

导出 **MOV** 时，可在 **MOV 音频编码** 中选 **PCM** 或 **AAC**。默认 PCM。AAC 支持 44.1 和 48 kHz，可选 CBR（默认）或 VBR。切换到 AAC 时，超出范围的采样率会切到 48 kHz。Pro Tools 完成导出后，QuickBounce 会把音轨转为 AAC，视频样本直接复制。所选编码会随预设和工程导出设置保存。

Pro Tools 会先把文件写到所选目标磁盘上的临时目录，校验后再交付。如果 Pro Tools 明确拒绝 MOV「与源相同」且没有其他导出错误，QuickBounce 会在同一选区用 H.264 重试一次。

跨工程导出时，QuickBounce 会在每个工程完成后恢复原来的独奏、静音、时间选区、播放起点及预卷／后卷设置，核对并保存。只有需要进入下一个工程时才关闭当前工程；最后一个会保持打开。取消或任务失败时，也会在恢复成功后保留当前工程。

## 修改 Mix 名称

双击待导出 Mix 的名称即可修改。按回车或点击输入框外确认，按 Esc 取消；名称不能为空。

## 多声道检查与试听

5.1、7.1 等多声道交付请选择 **WAV**。检查区会显示全部声道的波形；文件带有声道位置信息时，会标出 L、R、C、LFE 等名称。MP3 仍只支持单声道和立体声。

QuickBounce 使用 macOS 默认输出设备。在“音频 MIDI 设置”中配置好环绕扬声器后，可按多声道试听；只有立体声输出、或配置的输出声道不够时，会显示“下混试听”。下混时中置、环绕等声道衰减后合入左右，LFE 不加入立体声。多声道模式的 **ALL** 电平反映全部输出声道中的最大峰值。

下混仅用于试听，不会改变导出文件、波形或测量结果。响度按原始声道计算并排除 LFE；峰值检查仍包含 LFE。文件缺少声道布局时，不猜测声道位置，会保留波形和峰值检查，并提示响度与试听不可用。

## 批量命名前后缀

点击 **Session Settings** 右侧的 **Batch Rename**，填写前缀、后缀。以后每次 Add Mix 都会自动带上它们，光标停在中间，直接输入本次 Mix 的名字即可。留空就不添加；需要空格、下划线等分隔符时，请一起填入。此设置只影响后续新增的 Mix，本次关闭 App 后清空。

同一个 Session 再次导出到默认 **Bounced Files** 文件夹时，QuickBounce 会检查已有的 WAV、MP3 和 MOV 名称。重名会自动使用 `名称_1`、`名称_2` 等未占用编号，保留旧文件；WAV + MP3 使用相同编号。自定义输出文件夹仍沿用覆盖前询问的方式。

## 导出预设

点击 Bounce Settings 预设下拉框右侧的 **＋**，输入名称后点 **Confirm**，或按回车，即可保存当前设置（多选时取第一个 Mix）。选中预设后，下拉框会显示它的名称。

如果已选中一个预设，**＋** 会提供两项：**Add Current Settings as New Preset…** 另存为新预设，或 **Update “预设名称”** 更新当前预设。修改导出参数后可以直接更新，预设名称和默认状态会保留。

**Manage Presets…** 只管理默认项与删除。点 **Make Default** 后，每次 Add Mix 都会默认选中它，也可以在 Add Mix 窗口临时选择别的预设。

要批量应用，先在左侧用 Command 或 Shift 选中多个 Mix，再从 **Bounce Settings Presets** 菜单选择预设。预设包含格式、采样率、位深、Mix Source、Offline、Pad To Frame Boundary 等导出设置；每个 Mix 原来的输出文件夹会保留。预设会在重启后保留；不再需要时可在管理窗口删除。

## 工程导出设置历史

**导出前**，点击左侧 **工程导出设置 / Session Settings**，点击主面板中工程导出设置右侧的 **＋** 图标，填写名称即可保存。跨工程清单中，保存当前选中 Mix 所属工程的全部 Mix，包括名字、备注、Solo/Mute、时间范围和导出设置。

设置统一保存在 `~/Library/Application Support/QuickBounce/Session Settings/`，不再选择保存位置。它独立于每次启动清空的任务清单，重启后仍会保留。

列表按**首次加入时间从新到旧**排列，默认只显示最近 5 条。条目超过 5 条时，底部的 **显示更多 / Show More** 展开最近 10 条；超过 10 条时，再点 **显示更多** 打开独立历史界面，可滚动浏览全部记录。主面板右侧的放大镜可直接搜索全部历史，独立历史界面也支持搜索。点击某条记录，将它载入当前打开的 Pro Tools 工程；载入本身不改变 Pro Tools，建议导出前用 **Check** 核对。

要更新已有记录，点击主面板中工程导出设置右侧的 **更新** 图标（循环箭头），或新增时输入已有名称。确认 **替换 / Replace** 后才覆盖，取消则保留原文件；替换不改变首次加入时间及排序。若想保留不同版本，点击 **＋** 并使用不同名称。

主面板中工程导出设置右侧的 **文件夹** 图标会在 Finder 中打开管理目录，可改名、复制、备份或删除记录。回到 QuickBounce 后列表会刷新。旧版保存到其他位置的 `.quickbounce.json` 或 `.json` 设置文件，可复制到此目录后载入；不会自动搬移或删除原文件。

每个 Mix 的原名始终与其 Solo/Mute 快照一起保存；重复导出产生的数字后缀只用于本次文件，不改动保存的名称。这适用于只调整音量、效果器的后续版本。轨道增删、改名、改类型、移动文件夹或更改工程采样率后，需要重新 Add Mix；重名轨道无法可靠匹配时也会提示。设置文件不包含音频或历史导出结果。工程位置变化时，默认 Bounced Files 路径会跟随当前工程，自定义输出路径仍保留。

## 外观、语言与功能提示

点击 Bounce Settings 标题旁的齿轮，或打开 **QuickBounce → Settings…**（⌘,），可以选择 **Light（浅色）**、**Dark（深色）**、**Follow macOS（跟随系统）**。默认跟随系统，切换立即生效，重启后保留选择。

同一设置页可切换 **English / 简体中文**。打开 **显示功能提示 / Show Function Tips** 后，将鼠标停在按钮上约半秒即可查看功能说明。关闭后，测量数字的“名称 + 数值 + 单位”详情仍可查看。语言和提示开关都会记住。

中文界面的 **分层检查（Stems Check）** 会将所选分轨从文件起点对齐播放，可分别独奏或静音。

## 收起与置顶

- Bounced Files 和波形检查区默认收起。点击 **Bounce Settings** 右上角的箭头可以随时展开或收起；本批次第一首导出完成后会自动展开一次。
- 每批导出成功完成后，自动退出置顶模式、展开检查区并前置 QuickBounce，方便检查导出文件；置顶模式的添加快捷键同时停用。
- 展开时窗口会适配当前屏幕的可用范围；小屏幕上各栏会收窄，极小窗口可以滚动查看完整内容。
- 点击右上角的图钉进入 **Keep on Top** 模式。窗口会只保留 Add Mix 和 Bounce Settings 两列，并始终显示在 Pro Tools 前面；再次点击图钉即可退出。
- 点击图钉旁的键盘按钮可自定义 **Add Mix** 快捷键。它只在 Keep on Top 模式中生效：按下后 QuickBounce 会获得焦点并打开 Add Mix，不会同时触发 Pro Tools 里的同一快捷键。

## 检查与预览

- WAV 和 MP3：选中后可看波形、播放，并查看响度等数值。点击 **Metrics** 可以选择显示哪些数值；把鼠标停在数字上会看到完整名称和单位。
- 批量导出时，每完成一个音频文件就会在后台生成波形并测量响度，同时 Pro Tools 继续导出下一条；不需要等整批文件全部完成才开始分析。
- 如果分析未能完成，点击该文件下的 **Retry Analysis（重新分析）** 再试一次。已导出的文件会保留，不需要重新导出；分析失败的原因也会记入诊断日志。
- MOV：点击文件即可在原波形区域预览，按空格播放或暂停。点击预览右上角的全屏按钮可全屏播放，按 Esc 或点「退出全屏」返回。预览上方的「打开方式」提供默认浏览器和默认视频播放器。
- 文件列表点右键，可选 **Reveal in Finder**，在 Finder 中定位该文件。
- **Mix Compare** 用来逐个对比版本：每首歌都从左到右显示完整波形，下方有自己的时间轴；点击某首歌的波形即可从该位置试听。**Stems Check** 保持共用时间轴，并可缩放，用来检查多个 Stem 合起来是否完整。
- 分层检查右下角显示“不改变文件音量”，监听音量推子双击可回到 0 dB。

## 几个重要提示

- **WAV + MP3** 只导出一次 WAV，再由 QuickBounce 生成 MP3；使用 **Import After Bounce** 时只会把 WAV 导回 Pro Tools。
- 跨 Session 导出时，QuickBounce 会在每个 Session 完成后恢复原来的状态并保存。
- 点 **Cancel Bounce** 可以中断队列；已经完成并保存的文件会保留。
- 导出时磁盘空间不足会明确报错。导出失败会保留已添加的全部 Mix 和已经保存的文件。腾出空间后，再点 **Bounce Mixes** 重试。若显示工程状态待恢复，先恢复工程状态。
- 如果在恢复工程状态时取消，QuickBounce 会先完成恢复，再停止，不会继续导回已完成的音频。若原时间选区无法读取，导出会在首次修改轨道状态、时间选区及执行 Bounce 前停止；恢复选区读回不一致时保留恢复记录。
- 从 Finder 移动或删除导出文件后，QuickBounce 列表中的记录不会替你找回文件；可在列表右侧删除记录并重新导出。

## 如果显示 Disconnected

先确认 Pro Tools 已打开、Session 已打开，并允许 QuickBounce 控制 Pro Tools。首次使用时，macOS 可能会在“系统设置 → 隐私与安全性 → 自动化”或“辅助功能”中询问权限，允许 QuickBounce 即可。

QuickBounce 不会上传音频或 Session；导出文件仍保存在你选择的文件夹中。

## 导出诊断日志

常见错误会先显示简短说明和下一步建议。需要查看原始报错时，点 **Technical Details…（技术详情…）**，也可以复制详情。无法确定原因时会如实提示，不会一律归为设置问题。

如果遇到 Check、Solo/Mute、Bounce、波形或响度分析表现异常，请先复现一次问题，然后从屏幕左上角的 **QuickBounce** 菜单选择 **Export Diagnostic Log…** 保存 ZIP。日志会记录各步骤的耗时及分析失败原因，方便定位问题。

诊断日志会记录 QuickBounce 与 Pro Tools 的操作过程，但不会包含音频、视频、PTX、Bounce 文件或 QuickBounce 数据库。Session 路径、轨道名称和轨道 ID 会在写入日志前自动匿名化。

## 恢复记录与本地数据

QuickBounce 意外中断时会保存一份 Session 恢复记录。如果原 Session 已删除或不再需要，可点击 **Discard Recovery Record** 并确认；这只删除 QuickBounce 的记录，不会操作任何 Pro Tools Session。待恢复记录只会阻止对应的 Session，其他 Session 仍可正常使用。

SQLite 数据库只保存导出预设、Bounce Plan、任务状态、导出文件索引、检查结果和 Solo/Mute 恢复快照，不保存 WAV、MP3、MOV 或 `.ptx` 文件。每次重新启动都会清理上次的 Plan、任务和产物清单；用户保存的导出预设和尚未处理的安全恢复记录会保留。Session Settings 保存在 QuickBounce 应用数据目录的 Session Settings 文件夹中，重启后保留，需要时从历史列表载入。

## 反馈

稳定支持范围：macOS 14 及以上，Pro Tools 2025.12 及以上。稳定支持不意味着任何工程或未来版本都不会出现问题。使用前请保存并备份工程，正式交付前请核对导出文件。

遇到问题，请提供 QuickBounce、macOS 和 Pro Tools 版本、复现步骤，以及通过“导出诊断日志”生成的 ZIP。日志会对工程路径、轨道名称和 ID 做匿名化处理，但分享前仍请检查内容；截图也请遮挡不希望公开的信息。

QuickBounce 是 Huang Wenjie 独立开发的软件，与 Avid 无隶属关系，并非 Avid 官方产品。Pro Tools 是 Avid Technology, Inc. 的商标。

QuickBounce 自有内容允许非商用、修改和免费分发，分享时须保留许可和版权声明。付费客户项目等商业使用须另获授权。[许可全文](../LICENSE)

第三方组件说明见 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)，随 App 提供的第三方许可位于 `Contents/Resources/Licenses`。
