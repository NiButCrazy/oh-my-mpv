-- 区域命令劫持：同一个按键按鼠标位置分派到不同命令。
-- 协议见同目录 README.md；本模块只负责解析参数、判定命中、执行命令、记录区域。
-- 记录以"矩形"为单位（zone），同一矩形下的不同命令作为成员挂在 zone 上，
-- 这样多个按键绑到同一块区域时，调试视图只画一个矩形、成员逐行列出。

local Notify = require "modules.notify"

local M = {}

local zones = {}        -- 区域列表（按矩形去重），供调试视图绘制
local zone_by_key = {}  -- 矩形 key -> zone
local on_change = nil   -- 区域/成员变化或命令执行后的回调（由调试视图挂载）

-- 执行单条命令字符串；空命令忽略。命令失败只记日志，不影响后续按键。
local function run_command(cmd)
    if cmd == nil or cmd == "" then return end
    -- mpv 的 ignore 是空操作，直接跳过，省一次命令调用（约占单次开销的一半）
    if cmd == "ignore" then return end
    local ok, err = mp.command(cmd)
    if not ok then
        Notify.error("region-exec: 命令执行失败: " .. tostring(err))
    end
end

-- input.conf 里的 ${prop} 会在到达脚本之前就被 mpv 展开成具体值，
-- 导致每次按键命令文本都不同、调试视图重复记录。要求写成 $${prop}。
-- 绑定只扫描一次，问题缓存下来，之后每次触发都重新报一遍。
local bindings_checked = false
local binding_error = nil

local function check_bindings()
    if bindings_checked then return end
    bindings_checked = true

    local list = mp.get_property_native("input-bindings")
    if type(list) ~= "table" then return end

    local bad = {}
    for _, b in ipairs(list) do
        local cmd = b.cmd or ""
        if cmd:find("region-exec", 1, true) then
            local from = 1
            while true do
                local pos = cmd:find("${", from, true)
                if not pos then break end
                if cmd:sub(pos - 1, pos - 1) ~= "$" then
                    local stop = cmd:find("}", pos, true) or pos
                    bad[#bad + 1] = string.format("%s … %s", tostring(b.key), cmd:sub(pos, stop))
                    break
                end
                from = pos + 2
            end
        end
    end

    if #bad > 0 then
        binding_error = "regionxec: 以下命令导致重复绑定 ➔ ${...} 请写成 ➔ $${...} ▶ "
            .. table.concat(bad, " | ")
    end
end

-- input.conf 运行时重载后重新扫描，避免沿用旧结论
mp.observe_property("input-bindings", "none", function()
    bindings_checked = false
    binding_error = nil
end)

-- 取 OSD 像素尺寸；没有有效视频输出时返回 0。
local function get_osd_size()
    local dim = mp.get_property_native("osd-dimensions")
    local w = dim and dim.w or 0
    local h = dim and dim.h or 0
    if w <= 0 or h <= 0 then return 0, 0 end
    return w, h
end

-- mix 坐标项：一个或两个带单位的数值。无单位按 rel。
-- 返回 coord 或 nil, "syntax"|"rel"
local NUM = "%d*%.?%d+"
local function parse_mix_coord(token)
    local s = tostring(token)
    local n1, u1, op, n2, u2 = s:match("^(" .. NUM .. ")([rp]?)([%+%-])(" .. NUM .. ")([rp]?)$")
    if not n1 then
        n1, u1 = s:match("^(" .. NUM .. ")([rp]?)$")
    end
    if not n1 then return nil, "syntax" end

    local terms = { { n1, u1, "+" } }
    if n2 then terms[#terms + 1] = { n2, u2, op } end

    local rel, px = 0, 0
    for _, t in ipairs(terms) do
        local v = tonumber(t[1])
        local unit = t[2] ~= "" and t[2] or "r"
        local sign = t[3] == "-" and -1 or 1
        if unit == "r" then
            if v < 0 or v > 1 then return nil, "rel" end
            rel = rel + sign * v
        else
            px = px + sign * v
        end
    end
    return { rel = rel, px = px }
end

-- 单个坐标换算成像素；含 rel 分量且尺寸无效时返回 nil
local function coord_px(c, dim)
    if c.rel == 0 then return c.px end
    if dim <= 0 then return nil end
    return c.rel * dim + c.px
end

-- coords = { x0, y0, x1, y1 }，每项是 { rel, px }。
-- 任一坐标无法换算（含 rel 且尺寸无效）时返回 nil；返回像素已按左上/右下归一化。
local function rect_to_px(coords, w, h)
    local x0 = coord_px(coords[1], w)
    local y0 = coord_px(coords[2], h)
    local x1 = coord_px(coords[3], w)
    local y1 = coord_px(coords[4], h)
    if not (x0 and y0 and x1 and y1) then return nil end
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

-- 归一化比较键：先比 rel 分量，再比 px 分量（与窗口尺寸无关）
local function coord_less(a, b)
    if a.rel ~= b.rel then return a.rel < b.rel end
    return a.px < b.px
end

local function coord_key(c)
    return string.format("%s,%s", tostring(c.rel), tostring(c.px))
end

-- 记录一次调用：按矩形归并 zone，再按 (区内命令, 区外命令) 归并成员。
-- 返回 zone、成员、以及是否新建了 zone 或成员。
local function record(coords, a)
    local x0, x1 = coords[1], coords[3]
    local y0, y1 = coords[2], coords[4]
    if coord_less(x1, x0) then x0, x1 = x1, x0 end
    if coord_less(y1, y0) then y0, y1 = y1, y0 end

    local zkey = table.concat({ coord_key(x0), coord_key(y0), coord_key(x1), coord_key(y1) }, "\1")
    local z = zone_by_key[zkey]
    local created = false
    if not z then
        z = {
            coords = { x0, y0, x1, y1 },
            label = table.concat({ a[1], a[2], a[3], a[4], a[5] }, " "),
            members = {},
            member_by_key = {},
        }
        zone_by_key[zkey] = z
        zones[#zones + 1] = z
        created = true
    end

    local mkey = table.concat({ a[6], a[8] or "" }, "\2")
    local m = z.member_by_key[mkey]
    if not m then
        m = { inside = a[6], outside = a[8] }
        z.member_by_key[mkey] = m
        z.members[#z.members + 1] = m
        created = true
    end
    return z, m, created
end

local function notify_change()
    if on_change then on_change() end
end

-- script-message region-exec 的入口。
function M.handle(...)
    local a = { ... }
    check_bindings()
    if binding_error then Notify.error(binding_error) end

    if #a ~= 6 and not (#a == 8 and a[7] == "--") then
        Notify.error("region-exec: 用法 region-exec <rel|px|mix> <x0> <y0> <x1> <y1> \"<区域内命令>\" [-- \"<区域外命令>\"]")
        return
    end
    local mode = a[1]
    if mode ~= "rel" and mode ~= "px" and mode ~= "mix" then
        Notify.error("region-exec: 未知坐标模式 '" .. tostring(mode) .. "'（只支持 rel / px / mix）")
        return
    end

    local coords = {}
    if mode == "mix" then
        for i = 2, 5 do
            local c, err = parse_mix_coord(a[i])
            if not c then
                if err == "rel" then
                    Notify.error(string.format(
                        "region-exec: mix 坐标 '%s' 里的 rel 值必须在 0..1 之间", tostring(a[i])))
                else
                    Notify.error(string.format(
                        "region-exec: mix 坐标 '%s' 无效（支持 0.5、0.5r、100p、1r-10p）", tostring(a[i])))
                end
                return
            end
            coords[i - 1] = c
        end
    else
        local x0, y0, x1, y1 = tonumber(a[2]), tonumber(a[3]), tonumber(a[4]), tonumber(a[5])
        if not (x0 and y0 and x1 and y1) then
            Notify.error("region-exec: 坐标必须是数字")
            return
        end
        if x0 == x1 or y0 == y1 then
            Notify.error("region-exec: 矩形面积为 0（x0 == x1 或 y0 == y1）")
            return
        end
        if mode == "rel" then
            local lo, hi = math.min(x0, x1), math.max(x0, x1)
            local lo_y, hi_y = math.min(y0, y1), math.max(y0, y1)
            if lo < 0 or hi > 1 or lo_y < 0 or hi_y > 1 then
                Notify.error(string.format(
                    "region-exec: rel 坐标必须在 0..1 之间（当前 %s %s %s %s）", a[2], a[3], a[4], a[5]))
                return
            end
            coords = { { rel = x0, px = 0 }, { rel = y0, px = 0 },
                       { rel = x1, px = 0 }, { rel = y1, px = 0 } }
        else
            if x0 < 0 or y0 < 0 or x1 < 0 or y1 < 0 then
                Notify.error("region-exec: px 坐标不能为负")
                return
            end
            coords = { { rel = 0, px = x0 }, { rel = 0, px = y0 },
                       { rel = 0, px = x1 }, { rel = 0, px = y1 } }
        end
    end

    if a[6] == nil or a[6] == "" then
        Notify.error("region-exec: 区域内命令不能为空")
        return
    end

    local w, h = get_osd_size()
    local px0, py0, px1, py1 = rect_to_px(coords, w, h)
    if mode == "mix" and px0 and (px0 == px1 or py0 == py1) then
        Notify.error("region-exec: 矩形面积为 0（换算后 x0 == x1 或 y0 == y1）")
        return
    end
    local _, m, created = record(coords, a)

    if px0 and mouse_in_rect(px0, py0, px1, py1) then
        m.active_inside_at = mp.get_time()
        run_command(a[6])
        notify_change()
    elseif #a == 8 then
        m.active_outside_at = mp.get_time()
        run_command(a[8])
        notify_change()
    elseif created then
        notify_change()
    end
end

function M.set_on_change(fn)
    on_change = fn
end

function M.zones()
    return zones
end

M.osd_size = get_osd_size
M.rect_to_px = rect_to_px
M.mouse_in_rect = mouse_in_rect

return M
