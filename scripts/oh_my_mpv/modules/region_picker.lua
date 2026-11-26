-- 区域选择器：在画面上点两个点，生成可直接粘贴进 input.conf 的 region-exec 坐标。
-- 入口：script-message region-pick，或键绑定 region-pick-start。
-- 选择期间临时劫持左键取点、右键 / ESC 取消，结束即解除。
-- 结果同时出现在 OSD 与日志（日志里含可直接粘贴的绑定模板）。

local RegionExec = require "modules.region_exec"
local Notify = require "modules.notify"
local Options = require "modules.options"
local Color = require "modules.color"

local M = {}

local RESULT_HOLD = 15   -- 结果在 OSD 上停留的秒数

local overlay = mp.create_osd_overlay("ass-events")
local hold_timer = nil
local stage = nil        -- nil / "first" / "second"
local p1 = nil           -- 第一个点 { x, y, w, h }（像素 + 当时的窗口尺寸）
local result = nil       -- 结果矩形 { rx0, ry0, rx1, ry1, info }；info 只缓存 rel 与绑定模板
local bound = false      -- 是否处于劫持按键的选择阶段
local observing = false  -- 是否已挂观察者

local C = {
    border      = Color.parse(Options.color_border_hit, "00E000FF"),
    fill        = Color.parse(Options.color_fill_hit, "00E00020"),
    border_idle = Color.parse(Options.color_border_idle, "BFBFBFFF"),
    fill_idle   = Color.parse(Options.color_fill_idle, "00000000"),
    text    = Color.parse(Options.color_text, "FFFFFFFF"),
    dim     = Color.parse(Options.color_text_dim, "808080FF"),
    outline = Color.parse(Options.color_outline, "000000FF"),
}

local function iround(v)
    return math.floor(v + 0.5)
end

-- 当前指针位置；不在窗口内时返回 nil。
local function mouse_pos()
    local pos = mp.get_property_native("mouse-pos")
    if not pos or pos.hover ~= true or not pos.x or not pos.y then return nil end
    return pos.x, pos.y
end

local function dims()
    return RegionExec.osd_size()
end

local function clear_overlay()
    overlay.data = ""
    overlay.res_x, overlay.res_y = 0, 0
    overlay:update()
end

-- 把某个窗口尺寸下记录的像素点换算到当前尺寸（窗口缩放后仍与画面内容对齐）
local function scale_to(x, y, w0, h0, w, h)
    local sx = (w0 or 0) > 0 and w / w0 or 1
    local sy = (h0 or 0) > 0 and h / h0 or 1
    return (x or 0) * sx, (y or 0) * sy
end

-- 左上 / 右下归一化
local function norm(x0, y0, x1, y1)
    if x0 > x1 then x0, x1 = x1, x0 end
    if y0 > y1 then y0, y1 = y1, y0 end
    return x0, y0, x1, y1
end

-- 一整行 ASS 文本事件
local function text_event(x, y, fs, color, text)
    return string.format("{\\an7\\pos(%d,%d)\\fs%d\\bord2\\3c%s\\3a%s\\1c%s\\1a%s}%s",
        x, y, fs, C.outline.rgb, C.outline.alpha, color.rgb, color.alpha, text)
end

-- 矩形描边 + 填充（绘图模式）
local function rect_event(x0, y0, x1, y1, border, fill)
    return string.format(
        "{\\an7\\pos(0,0)\\p1\\bord2\\1c%s\\1a%s\\3c%s\\3a%s}m %d %d l %d %d %d %d %d %d",
        fill.rgb, fill.alpha, border.rgb, border.alpha,
        iround(x0), iround(y0), iround(x1), iround(y0),
        iround(x1), iround(y1), iround(x0), iround(y1))
end

-- 结果文字背后的半透明面板，避免和调试视图标签叠在一起看不清。
local function panel_event(x, y, w, h)
    return string.format(
        "{\\an7\\pos(0,0)\\p1\\bord0\\1c&H000000&\\1a&H60&}m %d %d l %d %d %d %d %d %d",
        iround(x), iround(y), iround(x + w), iround(y),
        iround(x + w), iround(y + h), iround(x), iround(y + h))
end

-- 把两个像素点格式化成三种可粘贴文本。纯函数，便于单独校验。
function M.describe(x0, y0, x1, y1, w, h)
    x0, y0, x1, y1 = norm(x0, y0, x1, y1)
    local rel = string.format("rel %.2f %.2f %.2f %.2f",
        x0 / w, y0 / h, x1 / w, y1 / h)
    local px = string.format("px %d %d %d %d",
        iround(x0), iround(y0), iround(x1), iround(y1))
    local line = string.format(
        'KEY script-message-to oh_my_mpv region-exec %s "区域内命令" -- "区域外命令"', rel)
    return { rel = rel, px = px, line = line }
end

local function render()
    local w, h = dims()
    if w <= 0 or h <= 0 then
        clear_overlay()
        return
    end
    overlay.res_x, overlay.res_y = w, h

    local fs = math.max(14, math.min(40, math.floor(h / 34)))
    local line_h = math.floor(fs * 1.5)
    local out = {}
    local cx, cy = mouse_pos()

    if stage then
        -- 半透明遮罩，明确当前处于选择状态
        out[#out + 1] = string.format(
            "{\\an7\\pos(0,0)\\p1\\1c&H000000&\\1a&H99&}m 0 0 l %d 0 %d %d 0 %d", w, w, h, h)

        if p1 and cx then
            -- p1 是点击当时的像素；窗口变化后按比例换算，保持与画面内容对齐
            local ax, ay = scale_to(p1.x, p1.y, p1.w, p1.h, w, h)
            local x0, y0, x1, y1 = norm(ax, ay, cx, cy)
            out[#out + 1] = rect_event(x0, y0, x1, y1, C.border, C.fill)
            local label = string.format("%d × %d px    rel %.2f × %.2f",
                iround(x1 - x0), iround(y1 - y0), (x1 - x0) / w, (y1 - y0) / h)
            out[#out + 1] = text_event(iround(x0) + 8, math.max(fs, iround(y0) - line_h), fs, C.text, label)
        end

        local hint = stage == "first"
            and "区域选择：左键点击第一个角（右键 / ESC 取消）"
            or "区域选择：左键点击第二个角（右键 / ESC 取消）"
        out[#out + 1] = string.format("{\\an2\\pos(%d,%d)\\fs%d\\bord2\\3c%s\\3a%s\\1c%s\\1a%s}%s",
            math.floor(w / 2), math.floor(h * 0.06), fs,
            C.outline.rgb, C.outline.alpha, C.text.rgb, C.text.alpha, hint)

        -- 实时指针坐标，取点时用来对齐
        if cx then
            out[#out + 1] = string.format("{\\an2\\pos(%d,%d)\\fs%d\\bord2\\3c%s\\3a%s\\1c%s\\1a%s}%s",
                math.floor(w / 2), math.floor(h * 0.06) + line_h, fs,
                C.outline.rgb, C.outline.alpha, C.text.rgb, C.text.alpha,
                string.format("%d, %d px    rel %.2f, %.2f", iround(cx), iround(cy), cx / w, cy / h))
        end
    elseif result then
        -- 框与 px 都按记录的比例重算：窗口缩放时跟着走
        local x0, y0, x1, y1 = result.rx0 * w, result.ry0 * h, result.rx1 * w, result.ry1 * h
        out[#out + 1] = rect_event(x0, y0, x1, y1, C.border_idle, C.fill_idle)

        local info = result.info
        -- px 行按当前窗口重新换算，和框保持一致；日志里记的是选择当时的像素
        local px_line = string.format("px %d %d %d %d",
            iround(x0), iround(y0), iround(x1), iround(y1))
        local bx, by = math.floor(w * 0.04), math.floor(h * 0.06)
        local pad = math.floor(fs * 0.5)
        out[#out + 1] = panel_event(bx - pad, by - pad,
            math.min(w - bx * 2, math.floor(fs * 24)), line_h * 3 + pad * 2)
        out[#out + 1] = text_event(bx, by, fs, C.text, info.rel)
        out[#out + 1] = text_event(bx, by + line_h, fs, C.text, px_line)
        out[#out + 1] = text_event(bx, by + line_h * 2, fs, C.dim,
            string.format("%d 秒后自动消失", RESULT_HOLD))
    end

    overlay.data = table.concat(out, "\n")
    overlay:update()
    mp.msg.verbose(string.format("region-pick: 绘制 %d 行", #out))
end

local function unbind()
    if not bound then return end
    mp.remove_key_binding("region-pick-point")
    mp.remove_key_binding("region-pick-cancel")
    mp.remove_key_binding("region-pick-esc")
    bound = false
end

local function on_mouse()
    if stage then render() end
end

local function on_dims()
    if stage or result then render() end
end

local function observe()
    if observing then return end
    mp.observe_property("mouse-pos", "native", on_mouse)
    mp.observe_property("osd-dimensions", "native", on_dims)
    observing = true
end

local function unobserve()
    if not observing then return end
    mp.unobserve_property(on_mouse)
    mp.unobserve_property(on_dims)
    observing = false
end

-- 清空状态与画面（结果到期、取消都走这里）
function M.clear()
    if hold_timer then
        hold_timer:kill()
        hold_timer = nil
    end
    stage, p1, result = nil, nil, nil
    unbind()
    unobserve()
    clear_overlay()
end

function M.cancel(reason)
    M.clear()
    mp.msg.info("region-pick: " .. (reason or "已取消"))
end

-- 进入选择：清掉上一次结果，从第一个点开始。
function M.start()
    local w, h = dims()
    if w <= 0 or h <= 0 then
        Notify.error("region-pick: 需要有效的视频输出（无 OSD 尺寸）")
        return
    end
    M.clear()
    stage = "first"
    observe()
    mp.add_forced_key_binding("MBTN_LEFT", "region-pick-point", M.click)
    mp.add_forced_key_binding("MBTN_RIGHT", "region-pick-cancel", function() M.cancel("已取消") end)
    mp.add_forced_key_binding("ESC", "region-pick-esc", function() M.cancel("已取消") end)
    bound = true
    render()
    mp.msg.info("region-pick: 等待第一个点（左键取点，右键 / ESC 取消）")
end

-- 左键取点；第二个点落下后出结果。
function M.click()
    if not stage then return end
    local cx, cy = mouse_pos()
    if not cx then return end

    local w, h = dims()

    if stage == "first" then
        p1 = { x = cx, y = cy, w = w, h = h }
        stage = "second"
        render()
        mp.msg.info(string.format("region-pick: 第一点 %d, %d", iround(cx), iround(cy)))
        return
    end

    -- 第一点存的是旧窗口的像素，这里先换算到当前尺寸，再和第二个点配对
    local first = p1
    if not first then
        -- stage 与 p1 理论上同步；这里兜底，避免状态错乱时崩
        stage = "first"
        render()
        return
    end
    local ax, ay = scale_to(first.x, first.y, first.w, first.h, w, h)
    local x0, y0, x1, y1 = norm(ax, ay, cx, cy)
    if iround(x0) == iround(x1) or iround(y0) == iround(y1) then
        -- 面积为 0 的矩形会被 region-exec 拒绝，直接回第一点重取
        p1, stage = nil, "first"
        render()
        Notify.error("region-pick: 两点不能重合（面积为 0），请重新取点")
        return
    end

    local info = M.describe(ax, ay, cx, cy, w, h)
    result = { rx0 = x0 / w, ry0 = y0 / h, rx1 = x1 / w, ry1 = y1 / h, info = info }
    p1, stage = nil, nil
    unbind()

    mp.msg.info("region-pick: " .. info.rel)
    mp.msg.info("region-pick: " .. info.px)
    mp.msg.info("region-pick: " .. info.line)

    render()
    if hold_timer then hold_timer:kill() end
    hold_timer = mp.add_timeout(RESULT_HOLD, function()
        hold_timer = nil
        M.clear()
    end)
end

return M
