-- ~/.hammerspoon/init.lua
require "hs.application"
require "hs.appfinder"
require "hs.window"
require "hs.keycodes"
require "hs.timer"
require "hs.screen"

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
-- 【螢幕 ROI 選取工具】 Cmd+Alt+P
------------------------------------------------------------
local roiPicker = require("screen_roi_picker")

hs.hotkey.bind({"cmd","alt"}, "P", function()
  roiPicker.start()
end)

------------------------------------------------------------
-- 【選擇啟用的腳本】
------------------------------------------------------------
-- 將下面這行改成你想啟用的腳本檔名（不用加 .lua）
-- local ACTIVE_SCRIPT = "祈禱機-戰鬥7-死2攻擊"
-- local ACTIVE_SCRIPT = "祈禱機-死7-自動施放回自由"
--  local ACTIVE_SCRIPT = "祈禱機-活7-自動CD" 
-- local ACTIVE_SCRIPT = "祈禱機-活7-自動鯊魚" 
  local ACTIVE_SCRIPT = "祈禱機-戰鬥7-自動鯊魚" 
-- local ACTIVE_SCRIPT = "祈禱機-活7-施放被動技能"

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