----------------------------------------------------------------------
-- ~/.hammerspoon/init.lua
-- 功能：
--  1) 只載入白名單中的 ~/.hammerspoon/scripts/*.lua
--  2) 檔案變動自動 reload
--  3) 全域緊急停止 (⌘⌥F9)
----------------------------------------------------------------------

local HS_HOME   = os.getenv("HOME") .. "/.hammerspoon"
local SCRIPTS   = HS_HOME .. "/scripts"

-- 讓 require 找得到 scripts/ 裡的檔案
package.path = table.concat({
  HS_HOME .. "/?.lua",
  HS_HOME .. "/?/init.lua",
  SCRIPTS .. "/?.lua",
  package.path
}, ";")

-- 全域緊急停止匯流排：各腳本可把清理函式註冊進來
_G.__HS_STOP_BUS = _G.__HS_STOP_BUS or {}

local function emergencyStopAll()
  for _, fn in ipairs(_G.__HS_STOP_BUS) do pcall(fn) end
  hs.alert.show("All scripts: Emergency stop executed")
end

-- ~/.hammerspoon/init.lua（節選）
local ENABLED_SCRIPTS = {
  -- "祈禱機-戰鬥7-死2攻擊",   -- ← 對應 祈禱機-戰鬥7-死2攻擊.lua
  -- "祈禱機-死7-自動施放回自由", -- 需要時再打開
  -- "祈禱機-死7-軍1攻擊",
  -- "祈禱機-死7-自動施放葉子回自由",
   "祈禱機-活7-施放被動技能",
}



-- 綁定全域緊急停止
hs.hotkey.bind({"cmd","alt"}, "F9", emergencyStopAll)

-- ✅ 僅依白名單 require，不再掃描整個目錄
local function loadEnabledScripts()
  for _, mod in ipairs(ENABLED_SCRIPTS) do
    local fullname = "scripts." .. mod
    local ok, err = pcall(require, fullname)
    if not ok then
      hs.printf("[init] Failed loading %s: %s", fullname, err)
      hs.alert.show("Load failed: " .. fullname)
    else
      hs.printf("[init] Loaded %s", fullname)
    end
  end
end

loadEnabledScripts()

-- 監控 scripts/ 目錄，如有變更就 reload（方便你改任何腳本後生效）
hs.pathwatcher.new(SCRIPTS, function(files)
  for _, f in ipairs(files) do
    if f:match("%.lua$") then
      hs.alert.show("Config changed → Reloading Hammerspoon")
      hs.reload()
      return
    end
  end
end):start()

hs.alert.show("Hammerspoon ready. (⌘⌥F9 = Emergency Stop)")