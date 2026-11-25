-- 错误同时打到日志和 OSD（只处理 error 级）。
-- OSD 用独立 ASS 覆盖层：多条错误自下而上堆叠，各自按 error_duration 到期消失。

local Options = require "modules.options"
local Color = require "modules.color"

local M = {}

local C_ERROR = Color.parse(Options.color_error, "FF8080FF")
local C_OUTLINE = Color.parse(Options.color_outline, "000000FF")
local DURATION = tonumber(Options.error_duration) or 3
local MAX_LINES = 5          -- 同时最多显示几条，防止刷屏

local overlay = mp.create_osd_overlay("ass-events")
local messages = {}          -- { { text = ..., at = mp.get_time() }, ... }
local expire_timer = nil

local function ass_escape(s)
    s = tostring(s or ""):gsub("[\r\n]+", " ")
    return (s:gsub("{", "("):gsub("}", ")"))
end

local function schedule_expire()
    if expire_timer then
        expire_timer:kill()
        expire_timer = nil
    end
    if DURATION <= 0 or #messages == 0 then return end

    local earliest = nil
    for _, m in ipairs(messages) do
        local t = m.at + DURATION
        if not earliest or t < earliest then earliest = t end
    end
    local left = earliest - mp.get_time()
    if left < 0.01 then left = 0.01 end

    expire_timer = mp.add_timeout(left, function()
        expire_timer = nil
        M.render()
    end)
end

function M.render()
    local dim = mp.get_property_native("osd-dimensions")
    local w = dim and dim.w or 0
    local h = dim and dim.h or 0
    if w <= 0 or h <= 0 then
        overlay.data = ""
        overlay:update()
        return
    end

    -- 到期清理
    if DURATION > 0 then
        local now = mp.get_time()
        for i = #messages, 1, -1 do
            if now - messages[i].at >= DURATION then
                table.remove(messages, i)
            end
        end
    end

    if #messages == 0 then
        overlay.data = ""
        overlay:update()
        return
    end

    local fs = math.max(14, math.min(40, math.floor(h / 32)))
    local line_h = math.floor(fs * 1.35)
    local base_y = h - 60

    overlay.res_x, overlay.res_y = w, h
    local out = {}
    for i, m in ipairs(messages) do
        -- 最新的一条在最下面，更早的往上堆；超长文本直接溢出，不做换行
        local y = base_y - (#messages - i) * line_h
        out[#out + 1] = string.format(
            "{\\an2\\pos(%d,%d)\\fs%d\\b1\\bord2\\3c%s\\3a%s\\1c%s\\1a%s}%s",
            math.floor(w / 2), y, fs,
            C_OUTLINE.rgb, C_OUTLINE.alpha, C_ERROR.rgb, C_ERROR.alpha,
            ass_escape(m.text))
    end
    overlay.data = table.concat(out, "\n")
    overlay:update()

    schedule_expire()
end

function M.error(msg)
    mp.msg.error(msg)
    messages[#messages + 1] = { text = msg, at = mp.get_time() }
    while #messages > MAX_LINES do
        table.remove(messages, 1)
    end
    M.render()
end

return M
