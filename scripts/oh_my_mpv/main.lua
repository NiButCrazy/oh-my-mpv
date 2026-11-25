-- Oh My MPV (https://github.com/NiButCrazy/oh-my-mpv)  版本号见 modules/version.lua
--
-- 目录形式的 mpv 脚本（scripts/oh_my_mpv/main.lua），功能按模块拆分：
--   modules/playback.lua     播放/暂停
--   modules/files.lua        打开文件 / 打开文件夹（PowerShell 对话框）
--   modules/region_exec.lua  区域命令劫持
--   modules/region_debug.lua 区域可视化（region-exec 的调试视图）
--   modules/options.lua      读取 script-opts/oh_my_mpv.conf（颜色、启动是否直接渲染 debug）
--
--[[
region-exec：区域命令劫持。鼠标位于矩形内时执行指定命令，矩形外可另给一条命令。
点击和滚轮都适用——滚轮无法用原生 set_mouse_area 按位置分流，只能在这里按 mouse-pos 判断。

用法（写进 input.conf）：
    KEY script-message-to oh_my_mpv region-exec <rel|px> <x0> <y0> <x1> <y1> "<区域内命令>" [-- "<区域外命令>"]

    rel：相对 osd-dimensions 的 0..1 比例（跟随窗口/DPI 缩放，推荐）
    px ：OSD 像素坐标，与 mouse-pos 同一坐标系（不是 modernz 的 ASS 虚拟画布）
    命令必须整体加引号作为单个参数传入，才能原样保留空格、";" 多命令和 no-osd 等前缀。
    命令里的 ${prop} 必须写成 $${prop}：mpv 会在脚本收到之前展开 ${...}，每次按键文本都不同，
    调试视图就会重复记录同一条绑定（脚本检测到未转义的 ${...} 会直接报错）。
    省略 "-- \"<区域外命令>\"" 时，区域外的按键被静默吞掉（即劫持）。

示例：
    WHEEL_UP  script-message-to oh_my_mpv region-exec rel 0 0.85 1 1 "add volume 5" -- "add volume 1"
    MBTN_LEFT script-message-to oh_my_mpv region-exec rel 0 0.85 1 1 "ignore" -- "script-binding oh_my_mpv/play_pause"

region-exec-debug：把已经触发过的区域画到 OSD 上，核对矩形范围和对应命令；鼠标命中的
区域用绿色高亮。区域要先用上面的绑定触发一次才会被记录。

    KEY script-message-to oh_my_mpv region-exec-debug <on|off|toggle>
    KEY script-binding oh_my_mpv/region-exec-debug-toggle

示例：
    F1 script-message-to oh_my_mpv region-exec-debug toggle
]]

local playback = require "modules.playback"
local files = require "modules.files"
local region_exec = require "modules.region_exec"
local region_debug = require "modules.region_debug"

-- 记录到新区域时让 debug 视图立刻刷新（debug 未开启时是空操作）
region_exec.set_on_change(region_debug.render_if_on)

mp.register_script_message("region-exec", region_exec.handle)
mp.register_script_message("region-exec-debug", region_debug.handle)

mp.add_key_binding(nil, "open_files", files.open_files)
mp.add_key_binding(nil, "open_folder", files.open_folder)
mp.add_key_binding(nil, "play_pause", playback.play_pause)
-- 键绑定不能与 script-message 同名，否则消息会被它截走（参数全丢），故用 -toggle 后缀
mp.add_key_binding(nil, "region-exec-debug-toggle", region_debug.toggle_key)
