-- 区域命令劫持：同一个按键按鼠标位置分派到不同命令。
-- 协议见 main.lua 头部；本模块只负责解析参数、判定命中、执行命令、记录区域。

local Notify = require "modules.notify"

local M = {}

local regions = {}        -- 已触发过的区域，调试视图据此绘制
local region_by_key = {}  -- 去重 + 命中后就地标记"已执行过"
local on_change = nil     -- 区域记录/激活后的回调（由调试视图挂载）

-- 执行单条命令字符串；空命令忽略。命令失败只记日志，不影响后续按键。
local function run_command(cmd)
    if cmd == nil or cmd == "" then return end
    local ok, err = mp.command(cmd)
    if not ok then
        Notify.error("region-exec: 命令执行失败: " .. tostring(err))
    end
end

-- 取 OSD 像素尺寸；没有有效视频输出时返回 0。
local function get_osd_size()
    local dim = mp.get_property_native("osd-dimensions")
    local w = dim and dim.w or 0
    local h = dim and dim.h or 0
    if w <= 0 or h <= 0 then return 0, 0 end
    return w, h
end

-- 把给定矩形换算成 OSD 像素坐标，并归一化为左上/右下两点。
-- rel 模式缺有效尺寸时返回 nil，调用方按区域外处理。
local function rect_to_px(mode, x0, y0, x1, y1, w, h)
    if mode == "rel" then
        if w <= 0 or h <= 0 then return nil end
        x0, x1 = x0 * w, x1 * w
        y0, y1 = y0 * h, y1 * h
    end
    if x0 > x1 then x0, x1 = x1, x0 end
    if y0 > y1 then y0, y1 = y1, y0 end
    return x0, y0, x1, y1
end

-- 当前鼠标是否落在矩形内（闭区间）。指针不在窗口内时一律视为区域外。
local function mouse_in_rect(x0, y0, x1, y1)
    local pos = mp.get_property_native("mouse-pos")
    if not pos or pos.hover ~= true or not pos.x or not pos.y then return false end
    return pos.x >= x0 and pos.x <= x1 and pos.y >= y0 and pos.y <= y1
end

-- 记住用过的区域（去重），供调试视图显示；返回该区域对象与是否新建。
local function record_region(mode, a, x0, y0, x1, y1)
    if x0 > x1 then x0, x1 = x1, x0 end
    if y0 > y1 then y0, y1 = y1, y0 end
    local key = table.concat({ mode, x0, y0, x1, y1, a[6], a[8] or "" }, "\1")
    local existing = region_by_key[key]
    if existing then return existing, false end

    local r = {
        mode = mode,
        x0 = x0, y0 = y0, x1 = x1, y1 = y1,
        label = table.concat({ a[1], a[2], a[3], a[4], a[5] }, " "),
        inside = a[6],
        outside = a[8],
        active_inside_at = nil,   -- 区域内命令最近一次执行的时刻
        active_outside_at = nil,  -- 区域外命令最近一次执行的时刻
    }
    regions[#regions + 1] = r
    region_by_key[key] = r
    return r, true
end

local function notify_change()
    if on_change then on_change() end
end

-- script-message region-exec 的入口。
function M.handle(...)
    local a = { ... }
    if #a ~= 6 and not (#a == 8 and a[7] == "--") then
        Notify.error("region-exec: 用法 region-exec <rel|px> <x0> <y0> <x1> <y1> \"<区域内命令>\" [-- \"<区域外命令>\"]")
        return
    end
    local mode = a[1]
    if mode ~= "rel" and mode ~= "px" then
        Notify.error("region-exec: 未知坐标模式 '" .. tostring(mode) .. "'（只支持 rel / px）")
        return
    end
    local x0, y0, x1, y1 = tonumber(a[2]), tonumber(a[3]), tonumber(a[4]), tonumber(a[5])
    if not (x0 and y0 and x1 and y1) then
        Notify.error("region-exec: 坐标必须是数字")
        return
    end

    local w, h = get_osd_size()
    local px0, py0, px1, py1 = rect_to_px(mode, x0, y0, x1, y1, w, h)
    local r, created = record_region(mode, a, x0, y0, x1, y1)

    if px0 and mouse_in_rect(px0, py0, px1, py1) then
        r.active_inside_at = mp.get_time()
        run_command(a[6])
        notify_change()
    elseif #a == 8 then
        r.active_outside_at = mp.get_time()
        run_command(a[8])
        notify_change()
    elseif created then
        notify_change()
    end
end

function M.set_on_change(fn)
    on_change = fn
end

function M.regions()
    return regions
end

M.osd_size = get_osd_size
M.rect_to_px = rect_to_px
M.mouse_in_rect = mouse_in_rect

return M
