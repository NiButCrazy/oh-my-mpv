-- 区域可视化：把 region-exec 记录到的区域画到 OSD 上，核对矩形与命令；命中的区域高亮。
-- 开关入口：script-message region-exec-debug <on|off|toggle>，或键绑定 region-exec-debug-toggle。
-- 颜色与启动开关见 script-opts/oh_my_mpv.conf。

local RegionExec = require "modules.region_exec"
local Options = require "modules.options"
local Notify = require "modules.notify"
local Color = require "modules.color"
local VERSION = require "modules.version"

local M = {}

local regions = RegionExec.regions()
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

-- 命令着色：分支前缀（内/外）标出当前会走哪一支，命令文本没有执行过就是灰色，执行过后变激活色。
local function cmd_segments(hit_now, active, prefix, cmd)
    return {
        { hit_now and C.text_hit or C.text_dim, prefix },
        { active and C.text_active or C.text_dim, " " .. short_cmd(cmd) },
    }
end

-- 一条区域的标签：序号+坐标中性色，内/外两条命令各自着色。
local function label_event(x, y, fs, r, idx, hit, in_active, out_active)
    local segs = {
        { C.text, string.format("%d. %s", idx, ass_escape(r.label)) },
    }
    for _, s in ipairs(cmd_segments(hit, in_active, "  |  区域内:", r.inside)) do
        segs[#segs + 1] = s
    end
    if r.outside then
        for _, s in ipairs(cmd_segments(not hit, out_active, "  |  区域外:", r.outside)) do
            segs[#segs + 1] = s
        end
    end

    local body = {}
    for i, s in ipairs(segs) do
        body[i] = span(s[1], s[2])
    end

    return string.format("{\\an7\\pos(%d,%d)\\fs%d\\bord2\\3c%s\\3a%s}%s",
        x, y, fs, C.outline.rgb, C.outline.alpha, table.concat(body))
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

    local out = {}
    local hits = 0
    for i, r in ipairs(regions) do
        local x0, y0, x1, y1 = RegionExec.rect_to_px(r.mode, r.x0, r.y0, r.x1, r.y1, w, h)
        if x0 then
            local hit = RegionExec.mouse_in_rect(x0, y0, x1, y1)
            if hit then hits = hits + 1 end
            local border = hit and C.border_hit or C.border_idle
            local fill = hit and C.fill_hit or C.fill_idle

            -- 矩形：填充色/透明度与边框色都可配
            out[#out + 1] = string.format(
                "{\\an7\\pos(0,0)\\p1\\bord2\\1c%s\\1a%s\\3c%s\\3a%s}m %d %d l %d %d %d %d %d %d",
                fill.rgb, fill.alpha, border.rgb, border.alpha,
                iround(x0), iround(y0), iround(x1), iround(y0),
                iround(x1), iround(y1), iround(x0), iround(y1))

            -- 标签锚定区域左上角；顶到屏幕边时让开标题行
            local lx = iround(x0) + 8
            local ly = math.max(head_h + 4, math.min(iround(y0) + 6, h - fs - 6))
            out[#out + 1] = label_event(lx, ly, fs, r, i, hit,
                active_now(r.active_inside_at), active_now(r.active_outside_at))
        end
    end

    -- 标题行最后画，保证永远压在最上层
    local status
    if #regions == 0 then
        status = "尚无区域记录 - 先触发一次绑定"
    else
        status = string.format("鼠标 %s  |  命中 %d  |  %d 个区域", cursor, hits, #regions)
    end
    -- 标题行放右上角（\an9 右对齐），信息自右向左：名称、版本、状态
    out[#out + 1] = string.format("{\\an9\\pos(%d,%d)\\fs%d\\bord2\\3c%s\\3a%s}%s%s%s",
        w - 10, math.floor(fs * 0.35), fs, C.outline.rgb, C.outline.alpha,
        span(C.text_dim, ass_escape(status), "\\b0"),
        span(C.text_dim, "   ·   v" .. VERSION, "\\b0"),
        span(C.text, "   OH MY MPV", "\\b1"))

    debug_overlay.data = table.concat(out, "\n")
    debug_overlay:update()
    mp.msg.verbose(string.format("region-exec-debug: 绘制 %d 个区域，命中 %d", #regions, hits))

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
        debug_on and "开启" or "关闭", #regions))
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
