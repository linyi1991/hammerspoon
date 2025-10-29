-- ~/.hammerspoon/scripts/walk_and_attack.lua
-- 功能：按照自訂序列 → 按方向一段時間 → 放開 → (可選) 按 z
-- 熱鍵：
--   ⌥F8 → 開/關循環
--   ⌥F6 → 單次測試
--   ⌥F9 → 緊急停止

local mod = {}

----------------------------------------------------------------------
-- 可調參數
----------------------------------------------------------------------

-- （可選）只在特定 App 前景時執行；若不想限制，設為 nil
local TARGET_APP_NAME = "MapleStory Worlds"

-- 動作序列：依序執行
-- 每項 { dir="left"/"right", hold=秒數, doZ=true/false }
local ACTIONS = {
  { dir = "left",  hold = 0.75, doZ = true },
  { dir = "right", hold = 0.75, doZ = true },
  -- 你可以加更多，例如：
  { dir="left", hold=1, doZ=true },
  { dir="right", hold=1, doZ=true },
}

-- Z 設定
local Z_HOLD_MS     = 1000    -- 按住 z 的毫秒
local GAP_AFTER_Z   = 0.15  -- z 放開後到下一步的間隔（秒）

-- 循環設定
local LOOP_GAP_SEC  = 3.0   -- 每輪結束後休息秒數
local LOOP_MAX_RUNS = 0     -- 0=無限；>0 最多執行 N 輪

----------------------------------------------------------------------
-- 狀態
----------------------------------------------------------------------
local running  = false
local timers   = {}
local runCount = 0

----------------------------------------------------------------------
-- 工具
----------------------------------------------------------------------
local function msleep(ms) hs.timer.usleep(ms * 1000) end
local function pushTimer(t) table.insert(timers, t); return t end
local function stopAllTimers() for _,t in ipairs(timers) do if t:running() then t:stop() end end; timers = {} end

local function keyDown(key) hs.eventtap.event.newKeyEvent({}, key, true):post() end
local function keyUp(key)   hs.eventtap.event.newKeyEvent({}, key, false):post() end
local function tapKey(key, holdMs) keyDown(key); msleep(holdMs or 60); keyUp(key) end

local function frontIsTarget()
  if not TARGET_APP_NAME then return true end
  local win = hs.window.frontmostWindow()
  if not win then return false end
  local app = win:application()
  return app and app:name() == TARGET_APP_NAME
end

----------------------------------------------------------------------
-- 動作流程
----------------------------------------------------------------------
local function runSequence(onDone)
  local idx = 0
  local function nextStep()
    idx = idx + 1
    if idx > #ACTIONS then
      if onDone then onDone() end
      return
    end
    local act = ACTIONS[idx]

    -- 1) 按住方向鍵
    keyDown(act.dir)
    pushTimer(hs.timer.doAfter(act.hold, function()
      keyUp(act.dir)

      if act.doZ then
        -- 2) 按 z
        tapKey("z", Z_HOLD_MS)
        pushTimer(hs.timer.doAfter(GAP_AFTER_Z, nextStep))
      else
        -- 直接進下一步
        nextStep()
      end
    end))
  end
  nextStep()
end

local function runOnce()
  if not frontIsTarget() then
    hs.alert.show("[walk_and_attack] 前景不是目標 App，暫緩 0.3 秒重試")
    pushTimer(hs.timer.doAfter(0.3, function()
      if running then runOnce() end
    end))
    return
  end

  runSequence(function()
    runCount = runCount + 1
    hs.alert.show(string.format("[walk_and_attack] 完成：第 %d 輪", runCount))

    if LOOP_MAX_RUNS > 0 and runCount >= LOOP_MAX_RUNS then
      running = false
      return
    end

    if running then
      pushTimer(hs.timer.doAfter(LOOP_GAP_SEC, runOnce))
    end
  end)
end

----------------------------------------------------------------------
-- 控制
----------------------------------------------------------------------
local function emergencyStop()
  running = false
  stopAllTimers()
  pcall(keyUp, "left"); pcall(keyUp, "right"); pcall(keyUp, "z")
  hs.alert.show("[walk_and_attack] 已停止")
end

-- Alt+F8 → 循環
hs.hotkey.bind({"alt"}, "F8", function()
  running = not running
  if running then
    runCount = 0
    hs.alert.show("[walk_and_attack] 循環開始")
    runOnce()
  else
    emergencyStop()
  end
end)

-- Alt+F6 → 單次測試
hs.hotkey.bind({"alt"}, "F6", function()
  hs.alert.show("[walk_and_attack] 單次測試")
  runSequence(function()
    hs.alert.show("[walk_and_attack] 單次完成")
  end)
end)

-- Alt+F9 → 緊急停止
hs.hotkey.bind({"alt"}, "F9", emergencyStop)

_G.__HS_STOP_BUS = _G.__HS_STOP_BUS or {}
table.insert(_G.__HS_STOP_BUS, emergencyStop)

return mod