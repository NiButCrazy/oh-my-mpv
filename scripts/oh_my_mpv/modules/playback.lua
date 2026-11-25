-- 播放控制

local M = {}

-- 播放/暂停。播放停到结尾（eof-reached）且处于暂停时从头重新播放。
function M.play_pause()
    if mp.get_property_native("eof-reached") then
        mp.commandv("seek", 0, "absolute-percent")
        mp.commandv("set", "pause", "no")
    else
        mp.commandv("cycle", "pause")
    end
end

return M
