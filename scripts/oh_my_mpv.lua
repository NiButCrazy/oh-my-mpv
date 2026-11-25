-- Oh My MPV v0.1.0 (https://github.com/NiButCrazy/oh-my-mpv)

local utils = require "mp.utils"


-- 播放/暂停。播放停到结尾（eof-reached）且处于暂停时从头重新播放。
local function play_pause()
    if mp.get_property_native("eof-reached") then
        mp.commandv("seek", 0, "absolute-percent")
        mp.commandv("set", "pause", "no")
    else
        mp.commandv("cycle", "pause")
    end
end



local function invoke_dialog(ps_command)
    local was_ontop = mp.get_property_native("ontop")
    if was_ontop then mp.set_property_native("ontop", false) end

    local res = utils.subprocess({
        args = { "powershell", "-NoProfile", "-STA", "-Command", ps_command },
        cancellable = false,
        capture_stdout = true,
        capture_stderr = true,
    })

    if was_ontop then mp.set_property_native("ontop", true) end

    if res and res.status == 0 and res.stdout and res.stdout ~= "" then
        return res.stdout
    end
end

local function open_files()
    local stdout = invoke_dialog([[
        Add-Type -AssemblyName PresentationFramework
        $ofd = New-Object Microsoft.Win32.OpenFileDialog
        $ofd.Multiselect = $true
        $ofd.Filter = "Media files|*.mkv;*.mp4;*.avi;*.mov;*.webm;*.wmv;*.gif;*.m4v;*.flv;*.mpg;*.mpeg;*.vob;*.ogv;*.3gp;*.ts;*.divx;*.mp3;*.flac;*.aac;*.ogg;*.wav;*.m4a;*.opus;*.wma;*.mka;*.m3u;*.m3u8|All files|*.*"

        if ($ofd.ShowDialog() -eq $true) {
            $u8  = New-Object System.Text.UTF8Encoding $false
            $out = [Console]::OpenStandardOutput()
            foreach ($f in $ofd.FileNames) {
                $bytes = $u8.GetBytes($f + "`n")
                $out.Write($bytes, 0, $bytes.Length)
            }
            $out.Flush()
        }
    ]])

    if not stdout or stdout == "" then return end

    local first = true
    for filename in stdout:gmatch("[^\r\n]+") do
        mp.commandv("loadfile", filename, first and "replace" or "append")
        first = false
    end
end


local function open_folder()
    local stdout = invoke_dialog([[
        Add-Type -AssemblyName System.Windows.Forms
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.ShowNewFolderButton = $false
        if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $u8  = New-Object System.Text.UTF8Encoding $false
            $out = [Console]::OpenStandardOutput()
            $bytes = $u8.GetBytes($fbd.SelectedPath + "`n")
            $out.Write($bytes, 0, $bytes.Length)
            $out.Flush()
        }
    ]])

    if not stdout then return end

    local dir = stdout:gsub("%s+$", "")
    if dir == "" then return end
    mp.commandv("loadfile", dir)
end

mp.add_key_binding(nil, "open_files", open_files)
mp.add_key_binding(nil, "open_folder", open_folder)
mp.add_key_binding(nil, "play_pause", play_pause)