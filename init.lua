-- ~/.hammerspoon/init.lua
-- 全域停止 + 單一主腳本載入 + 錄製器

hs.console.clearConsole()
hs.console.printStyledtext("🔹 Hammerspoon 初始化中...\n")

------------------------------------------------------------
-- 【全域停止】 Cmd+Alt+F9
------------------------------------------------------------
_G.__HS_STOP_BUS = _G.__HS_STOP_BUS or {}

local function globalEmergencyStop()
  hs.alert.show("[global] 強制停止所有腳本")
  for _, fn in ipairs(_G.__HS_STOP_BUS) do
    pcall(fn)
  end
end

hs.hotkey.bind({"cmd","alt"}, "F9", globalEmergencyStop)

------------------------------------------------------------
-- 【載入錄製器：永遠啟用】（⌘⌥R / ⌘⌥P / ⌘⌥L）
------------------------------------------------------------
local macro_recorder_ok, macro_recorder = pcall(require, "scripts.macro_recorder")
if macro_recorder_ok then
  hs.printf("[init] ✔ 已載入：macro_recorder")
else
  hs.printf("[init] ❌ macro_recorder 載入失敗：%s", tostring(macro_recorder))
end

------------------------------------------------------------
-- 【選擇要啟用的主腳本】（只會載入這一個）
------------------------------------------------------------
-- 將下面這行改成你想啟用的腳本檔名（不用加 .lua）
 local ACTIVE_SCRIPT = "祈禱機-戰鬥7-死2攻擊"
-- local ACTIVE_SCRIPT = "祈禱機-死7-自動施放回自由"
-- local ACTIVE_SCRIPT = "祈禱機-活7-施放被動技能"
-- local ACTIVE_SCRIPT = "祈禱機-活7-自動CD"

------------------------------------------------------------
-- 【載入主腳本】
------------------------------------------------------------
local function loadScript(name)
  local ok, mod = pcall(require, "scripts." .. name)
  if ok then
    hs.alert.show("[init] ✔ 已載入：" .. tostring(name))
    hs.printf("[init] ✔ 已載入：%s", tostring(name))
    return mod
  else
    hs.alert.show("[init] ❌ 載入失敗：" .. tostring(name))
    hs.printf("[init] ❌ 載入失敗：%s\n%s", tostring(name), tostring(mod))
    return nil
  end
end

local activeMod = nil
if ACTIVE_SCRIPT ~= nil then
  activeMod = loadScript(ACTIVE_SCRIPT)
else
  hs.printf("[init] ⚠ ACTIVE_SCRIPT 未設定，略過主腳本載入\n")
end

------------------------------------------------------------
-- 【啟動提示】
------------------------------------------------------------
if ACTIVE_SCRIPT ~= nil and activeMod ~= nil then
  hs.alert.show("[init] 啟動完成：" .. ACTIVE_SCRIPT .. "\n⌘⌥F8 單次 / ⌘⌥F10 循環 / ⌘⌥F9 停止")
  hs.printf("[init] 啟動完成（%s）\n", ACTIVE_SCRIPT)
else
  hs.alert.show("[init] 啟動完成（無主腳本，僅啟用 macro_recorder）")
  hs.printf("[init] 啟動完成（no ACTIVE_SCRIPT or load failed）\n")
end