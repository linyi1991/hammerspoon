-- ~/.hammerspoon/scripts/auto_prayer.lua
-- 熱鍵：
--   ⌘⌥F8  → 立即執行一次（或啟動循環的第一輪）
--   ⌘⌥F10 → 切換循環 開/關
--   ⌘⌥F7  → 切換是否在執行前固定視窗位置/大小
--   ⌘⌥F6  → 以目前滑鼠位置擷取點擊座標（相對百分比）
--   ⌘⌥F9  → 全域緊急停止（由你的 init.lua 提供）

local mod = {}

----------------------------------------------------------------------
-- 【可調參數】
----------------------------------------------------------------------
local TARGET_APP_NAME = "MapleStory"   -- 遊戲 App 名稱

-- 時序（秒）
local T_LEFT_HOLD         = 5       -- ← 長按秒數
local T_RIGHT_HOLD        = 1.35     -- → 長按秒數
local T_WAIT_BEFORE_UP    = 1.2       -- 等待再按 ↑
local T_WAIT_AFTER_UP     = 2       -- 按 ↑ 後等待
local T_BETWEEN_OPT_LR    = 0.55    -- ⌥← 與 ⌥→ 之間間隔
local T_WAIT_BEFORE_CLICK = 1.75     -- 多鍵序列完成後，延遲多少秒再點擊
local T_FINAL_WAIT        = 280     -- 流程最後等待（也作為循環間隔）

--   多鍵序列（依序按下；可含修飾鍵）
--   每項 {mods=<修飾鍵陣列>, key=<鍵名>, press_ms=<按住毫秒(可省)>}
--   key 例："2","3","4","z","f1","left","right"
local ACTION_KEYS = {
  { mods = {}, key = "1", press_ms = 250 },
  { mods = {}, key = "2", press_ms = 250 },
  -- { mods = {}, key = "4", press_ms = 120 },
}
local ACTION_KEYS_INTERVAL = 1.5   -- 多鍵之間的間隔秒數

-- 視窗固定（選擇性）
local PIN_WINDOW_BEFORE_RUN = false
local PIN_FRAME = { x=0, y=0, w=780, h=420 }

-- 點擊模式
--   "relative"：相對百分比（推薦，視窗變動也能對準）
--   "absolute"：主螢幕絕對座標
local CLICK_MODE = "relative"
local REL_CLICK = { px=0.42, py=0.58 }    -- 0~1；用 ⌘⌥F6 擷取
local ABS_CLICK = { x=780, y=420 }        -- CLICK_MODE="absolute" 時使用

-- 循環設定
local LOOP_ENABLED       = false          -- 預設不循環；⌘⌥F10 切換
-- local LOOP_GAP_SECONDS   = T_FINAL_WAIT   -- 每輪結束後隔多久再跑
local LOOP_GAP_SECONDS   = 0   -- 每輪結束後隔多久再跑
local LOOP_MAX_RUNS      =7 -- 0=無上限；>0 最多跑 N 次

-- 安全：單次長按最大上限（避免卡鍵）
local SAFETY_MAX_HOLD = 20

----------------------------------------------------------------------
-- 【內部狀態 & 小工具】
----------------------------------------------------------------------
local activeTimers, heldKeys, running = {}, {}, false
local runCount, loopTimer, menuBar = 0, nil, nil

local function ensureMenuBar()
  if menuBar then return end
  menuBar = hs.menubar.new()
  if menuBar then
    menuBar:setClickCallback(function()
      runCount = 0
      menuBar:setTitle("天祝&祈禱 x0")
      hs.alert.show("[auto_prayer] 計數已重設")
    end)
  end
end

local function updateMenuBar()
  ensureMenuBar()
  if menuBar then menuBar:setTitle(("天祝&祈禱 x%d"):format(runCount)) end
end

local function pushTimer(t) table.insert(activeTimers, t); return t end
local function stopAllTimers()
  for _,t in ipairs(activeTimers) do if t:running() then t:stop() end end
  activeTimers = {}
end
local function cancelLoopTimer()
  if loopTimer and loopTimer:running() then loopTimer:stop() end
  loopTimer = nil
end

-- 基本按鍵 API ------------------------------------------------------
local function keyDown(mods, key) hs.eventtap.event.newKeyEvent(mods or {}, key, true):post(); heldKeys[key]=true end
local function keyUp(mods, key)   hs.eventtap.event.newKeyEvent(mods or {}, key, false):post(); heldKeys[key]=nil end
local function tapKey(mods, key, press_ms)
  press_ms = press_ms or 60
  keyDown(mods, key)
  hs.timer.usleep(press_ms * 1000)
  keyUp(mods, key)
end

-- 讓修飾鍵（如 alt）先行按住 → 送方向鍵 → 再釋放修飾鍵（更像真人）
local function modCombo(mods, key, press_ms, pre_hold_ms, post_hold_ms)
  press_ms     = press_ms     or 60
  pre_hold_ms  = pre_hold_ms  or 60
  post_hold_ms = post_hold_ms or 60

  for _, m in ipairs(mods or {}) do
    hs.eventtap.event.newKeyEvent({}, m, true):post()   -- 修飾鍵 keyDown
  end
  hs.timer.usleep(pre_hold_ms * 1000)

  tapKey({}, key, press_ms)

  hs.timer.usleep(post_hold_ms * 1000)
  for i = #(mods or {}), 1, -1 do
    hs.eventtap.event.newKeyEvent({}, mods[i], false):post() -- 修飾鍵 keyUp
  end
end

local function holdKeyFor(mods, key, sec, onDone)
  sec = math.min(sec, SAFETY_MAX_HOLD)
  keyDown(mods, key)
  pushTimer(hs.timer.doAfter(sec, function()
    keyUp(mods, key)
    if onDone then onDone() end
  end))
end

local function safeAfter(sec, fn) pushTimer(hs.timer.doAfter(sec, function() pcall(fn) end)) end

local function releaseAllKeys()
  local keys = { "left","right","up","down" }
  for _, a in ipairs(ACTION_KEYS) do table.insert(keys, a.key) end
  for _,k in ipairs(keys) do
    if heldKeys[k] then keyUp({}, k) end
    keyUp({"alt"}, k); keyUp({"cmd"}, k); keyUp({"ctrl"}, k); keyUp({"shift"}, k)
  end
  heldKeys = {}
end

-- 強化版：移動 → 按下 → 等待 → 放開
local function mouseLeftClick(pt, holdMs)
  holdMs = holdMs or 80

  -- 先確保滑鼠真的移到該位置
  hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.mouseMoved, pt):post()
  hs.timer.usleep(20 * 1000)

  -- MouseDown
  hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.leftMouseDown, pt):post()
  hs.timer.usleep(holdMs * 1000)

  -- MouseUp
  hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.leftMouseUp, pt):post()
end


local function getAppWin()
  local app = hs.appfinder.appFromName(TARGET_APP_NAME)
  if not app then return nil, "找不到 App：「"..TARGET_APP_NAME.."」" end
  local win = app:mainWindow()
  if not win then return nil, "找不到主視窗（可能最小化或無焦點）" end
  return win
end

local function focusApp()
  local app = hs.appfinder.appFromName(TARGET_APP_NAME)
  if not app then return false, "找不到 App：「"..TARGET_APP_NAME.."」" end
  app:activate(true); return true
end

local function resolveClickPoint(win)
  if CLICK_MODE == "absolute" then
    return { x=ABS_CLICK.x, y=ABS_CLICK.y }
  end
  local f = win:frame()
  local w, h = math.max(1, f.w), math.max(1, f.h)
  return { x = f.x + REL_CLICK.px*w, y = f.y + REL_CLICK.py*h }
end

-- 依序按下多鍵 ------------------------------------------------------
local function pressActionKeysSequentially(idx, onDone)
  idx = idx or 1
  if idx > #ACTION_KEYS then
    if onDone then onDone() end
    return
  end
  local a = ACTION_KEYS[idx]
  tapKey(a.mods or {}, a.key, a.press_ms or 60)
  safeAfter(ACTION_KEYS_INTERVAL, function()
    pressActionKeysSequentially(idx + 1, onDone)
  end)
end

----------------------------------------------------------------------
-- 【主流程】← → 等1 ↑ 等3 ⌥← ⌥→ (多鍵序列) 等一秒 → 點擊 等 T_FINAL_WAIT
----------------------------------------------------------------------
local function scheduleNextLoop()
  cancelLoopTimer()
  if not LOOP_ENABLED then return end
  if LOOP_MAX_RUNS > 0 and runCount >= LOOP_MAX_RUNS then
    hs.alert.show(("[auto_prayer] 已達最大次數：%d"):format(LOOP_MAX_RUNS))
    return
  end
  loopTimer = hs.timer.doAfter(LOOP_GAP_SECONDS, function()
    if not running then mod.runOnce() end
  end)
end

function mod.runOnce()
  if running then hs.alert.show("[auto_prayer] 正在執行中"); return end
  running = true
  stopAllTimers(); cancelLoopTimer(); releaseAllKeys()

  local ok, ferr = focusApp(); if not ok then hs.alert.show(ferr); running=false; return end
  local win, werr = getAppWin(); if not win then hs.alert.show(werr); running=false; return end

  if PIN_WINDOW_BEFORE_RUN then win:setFrame(PIN_FRAME, 0) end
  local clickPoint = resolveClickPoint(win)

  -- 1) 長按 ←
  holdKeyFor({}, "left", T_LEFT_HOLD, function()
    -- 2) 長按 →
    holdKeyFor({}, "right", T_RIGHT_HOLD, function()
      -- 3) 等待再按 ↑
      safeAfter(T_WAIT_BEFORE_UP, function()
        tapKey({}, "up", 60)

        -- 4) 按 ↑ 後等待
        safeAfter(T_WAIT_AFTER_UP, function()

          -- 5) ⌥+←
          modCombo({"alt"}, "left", 60, 60, 60)

          -- 6) 與 ⌥+→ 之間的間隔
          safeAfter(T_BETWEEN_OPT_LR, function()
            -- 7) ⌥+→
            modCombo({"alt"}, "right", 60, 60, 60)

            -- 8) 多鍵序列（例如 2→3→4）
            pressActionKeysSequentially(1, function()
              --  8→9 中間等一秒（T_WAIT_BEFORE_CLICK）
              safeAfter(T_WAIT_BEFORE_CLICK, function()
                -- 9) 滑鼠點擊（相對或絕對）
                mouseLeftClick(clickPoint, 60)
                mouseLeftClick(clickPoint, 60)

                -- 10) 最後等待 / 循環
                safeAfter(T_FINAL_WAIT, function()
                  running = false
                  runCount = runCount + 1
                  updateMenuBar()
                  hs.alert.show(("[auto_prayer] 完成：第 %d 次"):format(runCount))
                  scheduleNextLoop()
                end)
              end)
            end)

          end)
        end)
      end)
    end)
  end)
end

local function emergencyStop()
  stopAllTimers(); cancelLoopTimer(); releaseAllKeys(); running=false
  hs.alert.show("[auto_prayer] 已停止")
end

-- 註冊到全域緊急停止匯流排（由 init.lua 呼叫）
_G.__HS_STOP_BUS = _G.__HS_STOP_BUS or {}
table.insert(_G.__HS_STOP_BUS, emergencyStop)

----------------------------------------------------------------------
-- 【熱鍵綁定】
----------------------------------------------------------------------
hs.hotkey.bind({"cmd","alt"}, "F8", function() mod.runOnce() end)

hs.hotkey.bind({"cmd","alt"}, "F6", function()
  local win, e = getAppWin(); if not win then hs.alert.show(e); return end
  local f = win:frame(); local mp = hs.mouse.getAbsolutePosition()
  local px = (mp.x - f.x) / math.max(1, f.w)
  local py = (mp.y - f.y) / math.max(1, f.h)
  REL_CLICK = { px = math.min(math.max(px,0),1), py = math.min(math.max(py,0),1) }
  hs.alert.show(string.format("[auto_prayer] 已存相對點：px=%.3f, py=%.3f", REL_CLICK.px, REL_CLICK.py))
end)

hs.hotkey.bind({"cmd","alt"}, "F7", function()
  PIN_WINDOW_BEFORE_RUN = not PIN_WINDOW_BEFORE_RUN
  hs.alert.show("[auto_prayer] 固定視窗：" .. (PIN_WINDOW_BEFORE_RUN and "開" or "關"))
end)

-- 循環開關（注意：F10 若是媒體鍵，需配合 fn 或在系統設定改為標準功能鍵）
hs.hotkey.bind({"cmd","alt"}, "F10", function()
  LOOP_ENABLED = not LOOP_ENABLED
  if LOOP_ENABLED then
    hs.alert.show("[auto_prayer] 循環：開（每 "..LOOP_GAP_SECONDS.." 秒）")
    if not running and (LOOP_MAX_RUNS==0 or runCount<LOOP_MAX_RUNS) then mod.runOnce() end
  else
    cancelLoopTimer()
    hs.alert.show("[auto_prayer] 循環：關")
  end
end)

-- 初始化顯示
updateMenuBar()

return mod
