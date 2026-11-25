-- 播放/暂停。在 keep-open 停到结尾（eof-reached）时从头重新播放。
-- 不主动绑定按键；需要时在 input.conf 里写：
--   SPACE   script-message-to contextmenu_native play-pause
local function play_pause()
    if mp.get_property_native("eof-reached") then
        mp.commandv("seek", 0, "absolute-percent")
        mp.commandv("set", "pause", "no")
    else
        mp.commandv("cycle", "pause")
    end
end

mp.add_key_binding(nil, "play-pause", play_pause)