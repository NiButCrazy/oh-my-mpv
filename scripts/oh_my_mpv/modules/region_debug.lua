-- 区域可视化：把 region-exec 记录到的区域画到 OSD 上，核对矩形与命令；命中的区域高亮。
-- 开关入口：script-message region-exec-debug <on|off|toggle>，或键绑定 region-exec-debug-toggle。
-- 颜色与启动开关见 script-opts/oh_my_mpv.conf。

local RegionExec = require "modules.region_exec"
local Options = require "modules.options"
local Notify = require "modules.notify"
local Color = require "modules.color"
local VERSION = require "modules.version"

local M = {}

local MAX_MEMBERS = 5      -- 每个区域最多展开几条绑定
local LABEL_GAP = 4        -- 同锚点标签块之间的垂直间距

local zones = RegionExec.zones()
local debug_on = false
local debug_observed = false
local debug_overlay = mp.create_osd_overlay("ass-events")
local repaint_timer = nil

local C = {
    border_idle = Color.parse(Options.color_border_idle, "BFBFBFFF"),
    border_hit  = Color.parse(Options.color_border_hit,  "00E000FF"),
    fill_idle   = Color.parse(Options.color_fill_idle,   "00000000"),
    fill_hit    = Color.parse(Options.color_fill_hit,    "00E00020"),
    text        = Color.parse(Options.color_text,        "FFFFFFFF"),
    text_dim    = Color.parse(Options.color_text_dim,    "808080FF"),
    text_hit    = Color.parse(Options.color_text_hit,    "00E000FF"),
    text_active = Color.parse(Options.color_text_active, "00BFFFFF"),
    outline     = Color.parse(Options.color_outline,     "000000FF"),
}

-- ASS 文本里的花括号是标签分隔符，换行也必须压平。
local function ass_escape(s)
    s = tostring(s or ""):gsub("[\r\n]+", " ")
    return (s:gsub("{", "("):gsub("}", ")"))
end

-- 按字节上限截断，但不切断 UTF-8 多字节字符（LuaJIT 没有 utf8 库，只回退到字符边界）。
local function truncate_utf8(s, limit)
    if #s <= limit then return s end
    local cut = limit
    while cut > 0 do
        local b = s:byte(cut + 1)
        if not b or b < 0x80 or b >= 0xC0 then break end   -- 下一字节是新字符起始/ASCII
        cut = cut - 1
    end
    return s:sub(1, cut) .. "..."
end

-- 命令片段单独截断：避免一条长命令把后面的“区域内/外”整段吃掉。
local function short_cmd(cmd)
    return truncate_utf8(ass_escape(cmd), 48)
end

local function iround(v)
    return math.floor(v + 0.5)
end

-- 行内换色：rgb 与 alpha 一起切，自定义半透明文字也能生效。
local function span(c, text, extra)
    return string.format("{\\1c%s\\1a%s%s}%s", c.rgb, c.alpha, extra or "", text)
end

-- 一整行 ASS 文本事件
local function text_event(x, y, fs, segs)
    local body = {}
    for i, s in ipairs(segs) do
        body[i] = span(s[1], s[2])
    end
    return string.format("{\\an7\\pos(%d,%d)\\fs%d\\bord2\\3c%s\\3a%s}%s",
        x, y, fs, C.outline.rgb, C.outline.alpha, table.concat(body))
end

-- 命令着色：分支前缀（内/外）标出当前会走哪一支，命令文本没有执行过就是灰色，执行过后变激活色。
local function cmd_segments(hit_now, active, prefix, cmd)
    return {
        { hit_now and C.text_hit or C.text_dim, prefix },
        { active and C.text_active or C.text_dim, " " .. short_cmd(cmd) },
    }
end

-- 一条绑定的两行内容：区域内 + 区域外
local function member_segments(m, hit, in_active, out_active)
    local segs = {}
    for _, s in ipairs(cmd_segments(hit, in_active, "    区域内:", m.inside)) do
        segs[#segs + 1] = s
    end
    if m.outside then
        for _, s in ipairs(cmd_segments(not hit, out_active, "  |  区域外:", m.outside)) do
            segs[#segs + 1] = s
        end
    end
    return segs
end

-- 激活色到期后重绘一次，让颜色自己退回默认色。
local function schedule_repaint(at)
    if repaint_timer then repaint_timer:kill() end
    local left = at - mp.get_time()
    if left <= 0 then return end
    repaint_timer = mp.add_timeout(left, function()
        repaint_timer = nil
        M.render_if_on()
    end)
end

local function render()
    local w, h = RegionExec.osd_size()
    if w <= 0 or h <= 0 then
        debug_overlay.data = ""
        debug_overlay:update()
        return
    end
    debug_overlay.res_x, debug_overlay.res_y = w, h

    local pos = mp.get_property_native("mouse-pos")
    local cursor = "窗口外"
    if pos and pos.hover == true and pos.x and pos.y then
        cursor = string.format("%d, %d px %.2f, %.2f rel",
            iround(pos.x), iround(pos.y), pos.x / w, pos.y / h)
    end

    -- 激活色只亮 active_duration 秒；0 表示一直保持
    local dur = tonumber(Options.active_duration) or 0
    local expire_at = nil
    local function active_now(at)
        if not at then return false end
        if dur <= 0 then return true end
        local until_t = at + dur
        local left = until_t - mp.get_time()
        if left <= 0 then return false end
        if not expire_at or until_t < expire_at then expire_at = until_t end
        return true
    end

    local fs = math.max(12, math.min(48, math.floor(h / 36)))
    local head_h = math.floor(fs * 1.8)
    local line_h = math.floor(fs * 1.45)

    -- 头行 + 最多 MAX_MEMBERS 条成员行 + 一条省略行；返回 (ASS 行数组, 实际占用行数)
    local function render_block(it, prefix, suffix, ly)
        local z = it.z
        local lx = it.ax + 8
        local head = (prefix or "") .. string.format("%d. %s", it.zi, z.label)
        if #z.members > 1 then
            head = head .. string.format("  ➔  %d 个绑定", #z.members)
        end
        if suffix then head = head .. suffix end

        local rows = { text_event(lx, ly, fs, { { C.text, head } }) }

        -- 成员行：屏幕放得下多少就展开多少；要折叠时先给 "另 N 个绑定" 提示行让出一行
        local room = math.max(0, math.floor((h - ly - fs) / line_h))
        local shown = math.min(#z.members, MAX_MEMBERS, room)
        if #z.members > shown then
            room = math.max(0, room - 1)
            shown = math.min(#z.members, MAX_MEMBERS, room)
        end
        for mi = 1, shown do
            local m = z.members[mi]
            rows[#rows + 1] = text_event(lx, ly + mi * line_h, fs,
                member_segments(m, it.hit,
                    active_now(m.active_inside_at), active_now(m.active_outside_at)))
        end
        if #z.members > shown then
            rows[#rows + 1] = text_event(lx, ly + (shown + 1) * line_h, fs,
                { { C.text_dim, string.format("    … 另 %d 个绑定", #z.members - shown) } })
        end

        return rows, 1 + shown + (#z.members > shown and 1 or 0)
    end

    local out = {}
    local hits = 0
    local items = {}

    -- 第一遍：只画矩形，同时把标签项按锚点分组留到第二遍
    for zi, z in ipairs(zones) do
        local x0, y0, x1, y1 = RegionExec.rect_to_px(z.coords, w, h)
        if x0 then
            local hit = RegionExec.mouse_in_rect(x0, y0, x1, y1)
            if hit then hits = hits + 1 end
            local border = hit and C.border_hit or C.border_idle
            local fill = hit and C.fill_hit or C.fill_idle

            -- 矩形只画一次：同一块区域下的多个按键共用
            out[#out + 1] = string.format(
                "{\\an7\\pos(0,0)\\p1\\bord2\\1c%s\\1a%s\\3c%s\\3a%s}m %d %d l %d %d %d %d %d %d",
                fill.rgb, fill.alpha, border.rgb, border.alpha,
                iround(x0), iround(y0), iround(x1), iround(y0),
                iround(x1), iround(y1), iround(x0), iround(y1))

            items[#items + 1] = { zi = zi, z = z, hit = hit, ax = iround(x0), ay = iround(y0) }
        end
    end

    -- 第二遍：按左上角像素坐标分组，同组标签纵向堆叠，避免互相盖住
    local groups, group_order = {}, {}
    for _, it in ipairs(items) do
        local key = it.ax .. "," .. it.ay
        local g = groups[key]
        if not g then
            g = { ax = it.ax, ay = it.ay, items = {} }
            groups[key] = g
            group_order[#group_order + 1] = g
        end
        g.items[#g.items + 1] = it
    end

    for _, g in ipairs(group_order) do
        if #g.items == 1 then
            -- 单块组保持原布局：从区域顶部往下排，下方放不下时改为向上展开
            local it = g.items[1]
            local ly = math.max(head_h + 4, math.min(it.ay + 6, h - fs - 6))
            local want = math.min(#it.z.members, MAX_MEMBERS)
            if #it.z.members > MAX_MEMBERS then want = want + 1 end  -- 折叠提示行也要放得下
            -- 与 render_block 同一判据：容量 = 该 y 之下还能放几行（含字号余量）
            local function capacity(y)
                return math.max(0, math.floor((h - y - fs) / line_h))
            end
            if capacity(ly) < want then
                local alt = math.min(it.ay, h) - (1 + want) * line_h - 4
                if alt >= head_h + 4 and capacity(alt) >= want then ly = alt end
            end
            local rows = render_block(it, nil, nil, ly)
            for _, r in ipairs(rows) do out[#out + 1] = r end
        else
            -- 多块组：从公共锚点向下堆叠，放不下时从末尾折叠成一行提示
            local plan = {}
            for i, it in ipairs(g.items) do
                local n = #it.z.members
                plan[i] = { it = it, lines = 1 + math.min(n, MAX_MEMBERS) + (n > MAX_MEMBERS and 1 or 0) }
            end

            local base = math.max(head_h + 4, math.min(g.ay + 6, h - fs - 6))
            local folded = 0
            local top, used
            while true do
                used = 0
                for i, p in ipairs(plan) do
                    used = used + p.lines * line_h
                    if i > 1 then used = used + LABEL_GAP end
                end
                -- 先按理想高度整组上移；仍放不下则去掉末尾一块再试
                if folded > 0 then used = used + LABEL_GAP + line_h end
                top = math.max(head_h + 4, math.min(base, h - 4 - used))
                if top + used <= h - 4 or #plan <= 1 then break end
                table.remove(plan)
                folded = folded + 1
            end

            -- 折叠提示：整行放得下就单独一行，否则并进最后一块的头行
            local suffix, note = nil, nil
            if folded > 0 then
                if top + used <= h - 4 then
                    note = string.format("    … 另 %d 个同锚点区域", folded)
                else
                    suffix = string.format("  |  同锚点另 %d 个区域", folded)
                end
            end

            local y = top
            for i, p in ipairs(plan) do
                -- 组内第 2 块起加前缀，表示共用左上角
                local rows, n = render_block(p.it, i > 1 and "└ " or nil,
                    i == #plan and suffix or nil, y)
                for _, r in ipairs(rows) do out[#out + 1] = r end
                y = y + n * line_h + LABEL_GAP
            end
            if note then
                out[#out + 1] = text_event(g.ax + 8, y, fs, { { C.text_dim, note } })
            end
        end
    end

    -- 标题行最后画，保证永远压在最上层
    local status
    if #zones == 0 then
        status = "尚无区域记录 - 先触发一次绑定"
    else
        status = string.format("%s  |  命中 %d  |  %d 个区域", cursor, hits, #zones)
    end
    out[#out + 1] = string.format("{\\an9\\pos(%d,%d)\\fs%d\\bord2\\3c%s\\3a%s}%s%s%s",
        w - 10, math.floor(fs * 0.35), fs, C.outline.rgb, C.outline.alpha,
        span(C.text_dim, ass_escape(status), "\\b0"),
        span(C.text_dim, "   ·   v" .. VERSION, "\\b0"),
        span(C.text, "   OH MY MPV", "\\b1"))

    debug_overlay.data = table.concat(out, "\n")
    debug_overlay:update()
    mp.msg.verbose(string.format("region-exec-debug: 绘制 %d 个区域，命中 %d", #zones, hits))

    if expire_at then schedule_repaint(expire_at) end
end

local function set_on(on)
    debug_on = on

    if debug_on and not debug_observed then
        mp.observe_property("osd-dimensions", "native", M.render_if_on)
        mp.observe_property("mouse-pos", "native", M.render_if_on)
        debug_observed = true
    elseif not debug_on and debug_observed then
        mp.unobserve_property(M.render_if_on)
        debug_observed = false
    end

    if debug_on then
        render()
    else
        if repaint_timer then
            repaint_timer:kill()
            repaint_timer = nil
        end
        debug_overlay.data = ""
        debug_overlay.res_x, debug_overlay.res_y = 0, 0
        debug_overlay:update()
    end
    mp.msg.info(string.format("region-exec-debug: %s（已记录 %d 个区域）",
        debug_on and "开启" or "关闭", #zones))
end

-- 供 region-exec 在记录新区域或执行命令后调用；debug 未开启时什么都不做。
function M.render_if_on()
    if debug_on then render() end
end

-- script-message region-exec-debug 的入口：on / off / toggle，缺省 toggle。
function M.handle(action)
    action = action == nil and "" or tostring(action)
    if action == "on" then
        set_on(true)
    elseif action == "off" then
        set_on(false)
    elseif action == "" or action == "toggle" then
        set_on(not debug_on)
    else
        Notify.error("region-exec-debug: 用法 region-exec-debug <on|off|toggle>")
    end
end

-- 键绑定入口：按键回调可能带状态参数，这里固定按 toggle 处理。
function M.toggle_key()
    M.handle("toggle")
end

-- 配置要求启动即渲染；此时可能还没有 VO，osd-dimensions 生效后会自动重绘。
if Options.debug_on_start then
    set_on(true)
end

return M
