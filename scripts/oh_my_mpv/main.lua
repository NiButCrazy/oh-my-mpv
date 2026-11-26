-- Oh My MPV (https://github.com/NiButCrazy/oh-my-mpv)  版本号见 modules/version.lua
--
-- 目录形式的 mpv 脚本（scripts/oh_my_mpv/main.lua），功能按模块拆分：
--   modules/playback.lua     播放/暂停
--   modules/files.lua        打开文件 / 打开文件夹（PowerShell 对话框）
--   modules/region_exec.lua  区域命令劫持
--   modules/region_debug.lua 区域可视化（region-exec 的调试视图）
--   modules/options.lua      读取 script-opts/oh_my_mpv.conf（颜色、启动是否直接渲染 debug）
--
-- 协议、按键写法、配置与排错详见同目录 README.md。

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
