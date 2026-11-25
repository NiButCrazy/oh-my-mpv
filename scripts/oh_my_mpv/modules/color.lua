-- 颜色转换："#RRGGBB" / "#RRGGBBAA" -> ASS 的 rgb 与 alpha 两段。
-- ASS 的 alpha 与 CSS 相反：00 不透明、FF 全透明，所以这里取反。

local M = {}

function M.parse(value, default_hex)
    local hex = tostring(value or ""):gsub("%s", ""):match("^#?(%x+)$")
    if not hex or (#hex ~= 6 and #hex ~= 8) then hex = default_hex end
    if #hex == 6 then hex = hex .. "FF" end
    local r, g, b, a = hex:sub(1, 2), hex:sub(3, 4), hex:sub(5, 6), hex:sub(7, 8)
    return {
        rgb = "&H" .. b .. g .. r .. "&",
        alpha = string.format("&H%02X&", 255 - tonumber(a, 16)),
    }
end

return M
