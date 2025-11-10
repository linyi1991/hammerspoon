-- ~/.hammerspoon/init.lua
-- 單一腳本載入 + 全域停止（你可自行改啟用哪個）

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
-- 【選擇要啟用的腳本】（只會載入這一個）
------------------------------------------------------------
-- 將下面這行改成你想啟用的腳本檔名（不用加 .lua）
-- local ACTIVE_SCRIPT = "祈禱機-戰鬥7-死2攻擊"
-- local ACTIVE_SCRIPT = "祈禱機-死7-自動施放回自由"
-- local ACTIVE_SCRIPT = "祈禱機-活7-施放被動技能"
local ACTIVE_SCRIPT = "祈禱機-活7-自動CD"

------------------------------------------------------------
-- 【載入腳本】
------------------------------------------------------------
local function loadScript(name)
  local ok, mod = pcall(require, "scripts." .. name)
  if ok then
    hs.alert.show("[init] ✔ 已載入：" .. name)
    hs.printf("[init] ✔ 已載入：%s", name)
    return mod
  else
    hs.alert.show("[init] ❌ 載入失敗：" .. name)
    hs.printf("[init] ❌ 載入失敗：%s\n%s", name, mod)
    return nil
  end
end

loadScript(ACTIVE_SCRIPT)

------------------------------------------------------------
-- 【啟動提示】
------------------------------------------------------------
hs.alert.show("[init] 啟動完成：" .. ACTIVE_SCRIPT .. "\n⌘⌥F8 執行 / ⌘⌥F10 循環 / ⌘⌥F9 停止")
hs.printf("[init] 啟動完成（%s）\n", ACTIVE_SCRIPT)