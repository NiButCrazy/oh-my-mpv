-- 统一读取 script-opts/oh_my_mpv.conf，各模块共用这一份配置。

local mp_options = require "mp.options"

local M = {
    -- 启动后立即渲染区域调试视图（等同启动时执行 region-exec-debug on）
    debug_on_start = false,

    -- 命令激活色持续秒数；0 表示一直保持
    active_duration = 0.3,

    -- 错误提示：颜色与停留秒数（0 = 一直显示到下一条错误）
    color_error = "#FF5555",
    error_duration = 3,

    -- 颜色写法：#RRGGBB 或 #RRGGBBAA；A 是不透明度，FF 不透明、00 全透明
    color_border_idle = "#BFBFBF",    -- 未命中区域的边框
    color_border_hit  = "#00E000",    -- 命中区域的边框
    color_fill_idle   = "#00000000",  -- 未命中区域的填充（默认全透明）
    color_fill_hit    = "#00E00020",  -- 命中区域的填充
    color_text        = "#FFFFFF",    -- 序号与坐标（命令文本用 color_text_dim）
    color_text_dim    = "#808080",    -- 命令文本（未激活）/ 标题状态文字
    color_text_hit    = "#00E000",    -- 本次会执行的命令
    color_text_active = "#00BFFF",    -- 执行过（激活）的命令
    color_outline     = "#000000",    -- 文字描边
}

mp_options.read_options(M, "oh_my_mpv")

return M
