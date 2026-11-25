-- 打开文件 / 打开文件夹：借 PowerShell 的系统对话框取路径，再交给 mpv 加载。

local utils = require "mp.utils"

local M = {}

-- 弹出对话框期间临时取消置顶，避免对话框被窗口挡住。
-- 返回标准输出的文本；用户取消或失败时返回 nil。
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

-- 多选文件：第一个 replace，其余 append。
function M.open_files()
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

-- 选一个文件夹，整目录交给 mpv 播放。
function M.open_folder()
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

return M
