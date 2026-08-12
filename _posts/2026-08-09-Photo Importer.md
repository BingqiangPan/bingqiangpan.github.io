---
title: 我用Codex做了一个照片导入小工具
author: B. Pan
date: 2026-08-09 01:20:00 +0200
categories: [Notes]
tags: [Photography, AI, Codex, Workflow, Automation]
typora-root-url: ..
pin: false
---

十几年来，从我开始拍照片起，照片备份的流程几乎没有变过：把相机存储卡插到电脑上，然后手动把照片复制到电脑本地，或者移动硬盘里，之后再进行修图、整理、发布等后续操作。最近我忽然意识到，这件事其实可以让 Codex 帮我做成一个自动化脚本，把原来反复手动复制的流程，变成一个更接近一键导入的操作。

既然是用 Codex 来做，我希望这个脚本不只是简单复制文件，而是更贴合我的实际工作流。它需要自动读取照片和视频的拍摄日期，按照 `YYYY-MM-DD` 创建文件夹，并把当天的照片和视频放到对应日期下面；对于一些没有日期信息的旧照片，则统一放到 `_No Data` 文件夹里，之后再手动整理。我也希望它能判断哪些文件已经备份过，因为很多时候我会忘记哪些照片已经导入，哪些还没有，哪些是已经导入但仍然留在存储卡里的。已经确认备份过的文件应该被跳过，但这个判断不能依赖绝对路径，因为照片备份之后，我可能会修改文件夹名字，比如在日期后面加上地点，或者再建立一个上级文件夹，把同一次旅行里的多个日期汇集在一起。因此，脚本需要确认的是“目标照片库里是否真的存在相同内容的文件”，而不是死记某一个固定路径。

复制完成后，我还希望有校验过程。存储卡、读卡器或者移动硬盘连接偶尔可能中断，某些文件也可能在复制时出问题，所以我需要确认文件确实完整地拷贝到了目标位置。每次导入结束后，脚本还会在目标文件夹里留下一个 `Import Log`，记录这次扫描了多少文件、导入了哪些照片、跳过了哪些重复文件、有没有失败，以及整个过程用了多长时间。除此之外，我还加了一个可选功能：导入完成后，可以把源文件夹里已经成功导入、或者确认重复的文件移动到源目录下的 `archive` 文件夹。这样我就知道这些源文件已经被处理过，相当于多一层保险。

于是，我开始了这次和 Codex 的 vibe coding 过程。之前我也尝试过让 ChatGPT 帮我写 ImageJ 的自动化脚本，所以我知道，只要模型能够理解需求，并且具备调用本地文件和系统工具的能力，这类个人工作流自动化其实是可以实现的。经过几轮需求补充、测试和修正，最后得到了现在这个对我来说已经可用的 macOS 照片导入脚本。这个工具不是 Lightroom，也不是 FreeFileSync，而是把我自己长期以来的照片导入习惯和偏好固化成了一个小工具。下面是演示视频和代码的下载链接。

<div style="position: relative; width: 100%; aspect-ratio: 16 / 9; margin: 1.5rem 0;">
  <iframe
    src="https://player.bilibili.com/player.html?bvid=BV1jnu56tEm7&page=1"
    style="width: 100%; height: 100%; border: 0;"
    scrolling="no"
    frameborder="no"
    framespacing="0"
    allowfullscreen>
  </iframe>
</div>
---

**代码说明及文件**

[README.md](/assets/files/Photo Importer for macos/Photo Importer README.md)

[Photo Importer v3.4](/assets/files/Photo Importer for macos/Photo Importer v3.4.command)
