# QuickBounce

QuickBounce is a macOS app for batching and reviewing Pro Tools bounces. Save the solo/mute state and timeline selection for each mix, queue multiple mixes, then review the exported files in one window.

QuickBounce 是一款 macOS 工具，帮助你记录 Pro Tools 中各个混音版本的独奏、静音和时间选区，批量导出并检查文件。[中文使用手册](docs/USER_GUIDE.zh-CN.md)

- Export WAV and MP3, or MOV with PCM or AAC audio.
- Save per-mix export presets and recall a session's mix list.
- Inspect waveforms, peaks and loudness. Compare mixes or audition time-aligned stems.
- Preview MOV files in QuickBounce. In v0.7.4, use the full-screen button in the preview. Press Esc or click Exit Full Screen to return.

## Requirements

- macOS 14 or later on Apple silicon or Intel.
- Pro Tools 2025.12 or later for the supported workflow. Versions 2024.03 through 2025.10 have experimental compatibility.
- Building from source requires Xcode with Swift 6, the Avid Pro Tools Scripting SDK and LAME. See [Build from source](docs/BUILDING.md).

## Get started

1. Open a session in Pro Tools and set its solo/mute state and timeline selection.
2. In QuickBounce, click **Add Mix** and name the mix. Repeat for the remaining mixes.
3. Choose an output format and folder in **Bounce Settings**, then click **Bounce Mixes**.
4. Use the review pane to inspect and audition the exported files.

## Report an issue

Include the QuickBounce, macOS and Pro Tools versions, the steps to reproduce the issue, and what you expected to happen. To collect a log, choose **QuickBounce → Export Diagnostic Log…**. Review any log or screenshot before sharing it publicly.

## License and credits

Copyright © 2026 Huang Wenjie. The [QuickBounce Noncommercial License](LICENSE) allows noncommercial use and modification and lets you share original or modified copies free of charge. Commercial use, including paid client work, requires separate permission.

QuickBounce 自有内容允许非商用、修改和免费分发，分享时请保留许可和版权声明。用于付费客户项目等商业用途须另获授权。[许可全文](LICENSE)

Third-party components are covered by their respective terms. See the [third-party notices](THIRD_PARTY_NOTICES.md).

QuickBounce is an independent project. Pro Tools is a trademark of Avid Technology, Inc.
