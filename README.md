# Oh My MPV

Windows 便携版 mpv 的自用配置：modernz 播放器界面、中文 OSD、以及本文重点介绍的 **oh_my_mpv** 脚本。

![oh_my_mpv 区域调试视图](snap/p1.png)

---

## oh_my_mpv

一个把"鼠标现在在哪块区域"变成可编程条件的 mpv 脚本。mpv 原生的 `set_mouse_area` 只能处理悬停高亮，无法按位置分流滚轮事件；`oh_my_mpv` 直接在脚本里读 `mouse-pos`，因此**点击、滚轮、键盘按键都能按区域劫持**。

### 功能一览

| 功能 | 入口 | 说明 |
|---|---|---|
| 区域命令劫持 | `region-exec` 消息 | 鼠标在矩形内执行命令 A，矩形外执行命令 B（可省略 = 静默吞掉） |
| 区域可视化 | `region-exec-debug` 消息 / `region-exec-debug-toggle` 绑定 | 把已触发过的区域画到 OSD 上，命中高亮，命令执行后短暂变色 |
| 播放/暂停 | `play_pause` 绑定 | 播放到结尾且暂停时从头重播，否则切换暂停 |
| 打开文件 | `open_files` 绑定 | PowerShell 系统对话框，多选，第一个替换、其余追加 |
| 打开文件夹 | `open_folder` 绑定 | 选择目录后整个交给 mpv 播放 |

安装、语法、调试视图、配置与错误排查见 [`scripts/oh_my_mpv/README.md`](scripts/oh_my_mpv/README.md)。

---

## 仓库内其他内容

| 路径 | 说明 |
|---|---|
| `scripts/modernz.lua` | 第三方 OSC（不修改） |
| `scripts/stats.lua`、`thumbfast.lua`、`playlist_osd.lua`、`pause_indicator_lite.lua`、`pip_lite.lua`、`open_file.lua`、`save_global_props.lua` | 第三方 / 自用脚本，各自维护 |
| `script-opts/*.conf` | 上述脚本的配置 |
| `mpv.conf`、`input.conf`、`menu.conf` | 播放器与按键配置 |
| `fonts/` | OSD 字体 |
| `snap/` | 截图 |
