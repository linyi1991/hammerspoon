-- ~/.hammerspoon/scripts/forest_loop.lua
-- 死亡森林2（隨機版）：Q(瞬移) + Z(補血)
-- 流程：隨機 → 向某方向移動(隨機秒) → 原地攻擊(隨機秒) → 反向 → 休息(隨機) → 循環
-- 熱鍵：
--   ⌥F8 → 開/關循環
--   ⌥F6 → 單次測試
--   ⌥F9 → 緊急停止（釋放所有鍵）
--   ⌥F1 → 列印目前前景 App 的 name/bundleID（偵錯）

local mod = {}

----------------------------------------------------------------------
-- 可調參數（含「範圍」）
----------------------------------------------------------------------
-- 前景檢查模式: "lenient"（預設）|"strict"|"none"
local FOREGROUND_MODE = "lenient"
local MAX_WAIT_TRIES  = 3       -- lenient 模式下最多等待次數（每次 0.4s）

-- 允許多個名稱/Bundle ID；任一匹配即視為目標（大小寫不敏感）
local TARGET_NAMES = { "MapleStory" }
local TARGET_BUNDLE_IDS = {
  -- 例如： "com.nexon.maplestory"
}

-- === 範圍設定（秒） ===
-- 每一「小段」的移動與原地攻擊秒數都從這裡隨機抽
local MOVE_CHUNK_RANGE   = { 0.80, 1.20 }   -- 每段移動（Q+方向）持續秒數
local ATTACK_STOP_RANGE  = { 3.20, 5.80 }   -- 每段移動後，原地 Z 的秒數

-- 整輪左右方向的「目標總時長」也會隨機抽
local RIGHT_TOTAL_RANGE  = { 5.0, 10.0 }   -- 向右整段目標秒數
local LEFT_TOTAL_RANGE   = { 5.0, 10.0 }   -- 向左整段目標秒數

-- 每輪結束後的休息秒數（也隨機）
local REST_RANGE         = { 0.40, 1.20 }

-- 技能鍵
local SKILL_KEY  = "q"          -- 瞬移技能（按住）
local ATTACK_KEY = "z"          -- 攻擊/補血技能（按住）

-- Buff：開循環就先施放一次，之後固定間隔施放
local BUFF_KEYS      = { "5", "6" }   -- 若用數字小鍵盤可寫 { "pad5", "pad6" }
local BUFF_INTERVAL  = 198            -- 每多少秒放一次（提早於 300s）
local BUFF_PRESS_MS  = 150            -- 每顆 Buff 鍵按住毫秒
local BUFF_GAP_MS    = 420            -- 兩顆 Buff 鍵之間的間隔
local BUFF_RETRIES   = 0              -- 補按次數（0=不補按；建議 1）

-- 人類化行為（可選）
local CHANCE_TAP_Z_WHILE_MOVING = 0.12   -- 移動段中，短促點一下 Z 的機率
local TAP_Z_MS_RANGE            = { 30, 60 }

----------------------------------------------------------------------
-- 狀態 / 工具
----------------------------------------------------------------------
local running, timers, runCount, buffTimer = false, {}, 0, nil
local waitTries = 0

math.randomseed(os.time())
local function randf(a, b) return a + math.random() * (b - a) end
local function randi(a, b) return math.floor(a + math.random() * (b - a + 1)) end
local function chance(p)   return math.random() < p end

local function pickf(range) return randf(range[1], range[2]) end
local function picki(range) return randi(range[1], range[2]) end

local forestMenuBar = hs.menubar.new()
if forestMenuBar then forestMenuBar:setTitle("死2-x0") end

local function log(fmt, ...)
  hs.printf("[forest_loop-rand] " .. string.format(fmt, ...))
end

local function pushTimer(t) table.insert(timers, t); return t end
local function stopAllTimers()
  for _,t in ipairs(timers) do if t:running() then t:stop() end end
  timers = {}
  if buffTimer and buffTimer:running() then buffTimer:stop() end
  buffTimer = nil
end

-- 逐鍵 down/up（支援 "5","6" 或 "pad5","pad6"）
local function tapOneKey(keyName, press_ms)
  press_ms = press_ms or 60
  local down = hs.eventtap.event.newKeyEvent({}, keyName, true)
  local up   = hs.eventtap.event.newKeyEvent({}, keyName, false)
  down:post()
  hs.timer.usleep(press_ms * 1000)
  up:post()
end

-- 嘗試把目標 App 叫到前景（多種方式）
local function focusTargetApp()
  for _, name in ipairs(TARGET_NAMES) do
    local app = hs.application.get(name) or hs.appfinder.appFromName(name) or hs.application.find(name)
    if app then app:activate(true); return true end
  end
  for _, bid in ipairs(TARGET_BUNDLE_IDS) do
    local app = hs.application.get(bid) or hs.application.find(bid)
    if app then app:activate(true); return true end
  end
  return false
end

-- 穩健版前景判斷（全螢幕也可）：frontmostApplication()
local function frontIsTarget()
  if FOREGROUND_MODE == "none" then return true end
  local app = hs.application.frontmostApplication()
  if not app then return false end
  local name = (app:name() or ""):lower()
  local bid  = (app:bundleID() or "")
  for _, n in ipairs(TARGET_NAMES) do
    if name == n:lower() then return true end
  end
  for _, b in ipairs(TARGET_BUNDLE_IDS) do
    if bid == b then return true end
  end
  return false
end

local function updateForestMenuBar(state)
  if not forestMenuBar then return end
  if state == "stop" then
    forestMenuBar:setTitle("死2-STOP")
  elseif state == "wait" then
    forestMenuBar:setTitle(string.format("死2-wait(%d)", waitTries))
  else
    forestMenuBar:setTitle(("死2-x%d"):format(runCount))
  end
end

-- Buff 按鍵（逐鍵 down/up，帶可調間隔與重試）
local function pressBuffKeys()
  for r = 1, (BUFF_RETRIES + 1) do
    for idx, k in ipairs(BUFF_KEYS) do
      tapOneKey(k, BUFF_PRESS_MS)
      if idx < #BUFF_KEYS then
        hs.timer.usleep(BUFF_GAP_MS * 1000)
      end
    end
    if r < (BUFF_RETRIES + 1) then
      hs.timer.usleep((BUFF_GAP_MS + 80) * 1000)
    end
  end
  log("buff pressed (%s)", table.concat(BUFF_KEYS, ","))
end

----------------------------------------------------------------------
-- 一段：移動 moveDur 秒 → 原地 Z attackDur 秒（**每段隨機**）
----------------------------------------------------------------------
local function doMoveAndStopAttack(dir, elapsed, limit, onDone)
  if elapsed >= limit then
    if onDone then onDone() end
    return
  end

  -- 這一小段的隨機時長
  local moveDur   = pickf(MOVE_CHUNK_RANGE)
  local attackDur = pickf(ATTACK_STOP_RANGE)

  -- 若最後一段超標，截斷到上限（避免長度過長）
  if elapsed + moveDur + attackDur > limit then
    local remain = math.max(0.05, limit - elapsed)
    -- 以 6:4 拆配（移動:攻擊），但仍保底 0.1 秒
    moveDur   = math.max(0.1, remain * 0.6)
    attackDur = math.max(0.1, remain - moveDur)
  end

  log("step dir=%s move=%.2fs attack=%.2fs (elapsed=%.2f / limit=%.2f)", dir, moveDur, attackDur, elapsed, limit)

  -- Step1: 移動 (Q+方向 down)
  hs.eventtap.event.newKeyEvent({}, SKILL_KEY, true):post()
  hs.eventtap.event.newKeyEvent({}, dir, true):post()

  -- （可選）移動中隨機點一下 Z
  if chance(CHANCE_TAP_Z_WHILE_MOVING) then
    pushTimer(hs.timer.doAfter(randf(0.08, math.max(0.12, moveDur * 0.5)), function()
      tapOneKey(ATTACK_KEY, randi(TAP_Z_MS_RANGE[1], TAP_Z_MS_RANGE[2]))
      log("tap Z while moving")
    end))
  end

  -- 到點 → 放開方向，保持 Q，然後原地 Z
  pushTimer(hs.timer.doAfter(moveDur, function()
    hs.eventtap.event.newKeyEvent({}, dir, false):post()

    hs.eventtap.event.newKeyEvent({}, ATTACK_KEY, true):post()
    pushTimer(hs.timer.doAfter(attackDur, function()
      hs.eventtap.event.newKeyEvent({}, ATTACK_KEY, false):post()
      hs.eventtap.event.newKeyEvent({}, SKILL_KEY, false):post()

      -- 下一個小段（遞迴）
      doMoveAndStopAttack(dir, elapsed + moveDur + attackDur, limit, onDone)
    end))
  end))
end

----------------------------------------------------------------------
-- 主流程：隨機起點方向 → 另一方向 → 休息（全部隨機）
----------------------------------------------------------------------
local function runCycle()
  -- 決定本輪左右的目標秒數（隨機）
  local rightSec = pickf(RIGHT_TOTAL_RANGE)
  local leftSec  = pickf(LEFT_TOTAL_RANGE)
  local restSec  = pickf(REST_RANGE)

  -- 隨機挑起點方向
  local firstDir = (math.random() < 0.5) and "right" or "left"
  local secondDir = (firstDir == "right") and "left" or "right"
  local firstLimit  = (firstDir == "right") and rightSec or leftSec
  local secondLimit = (secondDir == "right") and rightSec or leftSec

  log("cycle start: %s=%.2fs then %s=%.2fs | rest=%.2fs", firstDir, firstLimit, secondDir, secondLimit, restSec)

  doMoveAndStopAttack(firstDir, 0, firstLimit, function()
    doMoveAndStopAttack(secondDir, 0, secondLimit, function()
      runCount = runCount + 1
      updateForestMenuBar()
      log("cycle finished #%d; rest %.2fs", runCount, restSec)
      if running then
        pushTimer(hs.timer.doAfter(restSec, runCycle))
      end
    end)
  end)
end

----------------------------------------------------------------------
-- 外層控制（含前景檢查）
----------------------------------------------------------------------
local function runOnce()
  if not running then return end

  if FOREGROUND_MODE ~= "none" and not frontIsTarget() then
    if FOREGROUND_MODE == "strict" then
      if focusTargetApp() then
        log("focused target; retry soon")
      else
        log("target not front; strict wait...")
      end
      waitTries = waitTries + 1
      updateForestMenuBar("wait")
      pushTimer(hs.timer.doAfter(0.4, runOnce))
      return
    else
      -- lenient：嘗試帶到前景，最多等 MAX_WAIT_TRIES 次，之後照跑
      focusTargetApp()
      waitTries = waitTries + 1
      updateForestMenuBar("wait")
      if waitTries < MAX_WAIT_TRIES then
        pushTimer(hs.timer.doAfter(0.4, runOnce))
        return
      else
        log("lenient: max wait reached, continue anyway")
      end
    end
  end

  waitTries = 0
  updateForestMenuBar()
  runCycle()
end

----------------------------------------------------------------------
-- 控制 / 熱鍵
----------------------------------------------------------------------
local function emergencyStop()
  running = false
  stopAllTimers()
  -- 保險釋放
  hs.eventtap.event.newKeyEvent({}, SKILL_KEY, false):post()
  hs.eventtap.event.newKeyEvent({}, ATTACK_KEY, false):post()
  hs.eventtap.event.newKeyEvent({}, "left", false):post()
  hs.eventtap.event.newKeyEvent({}, "right", false):post()
  updateForestMenuBar("stop")
  hs.alert.show("[forest_loop] 已停止")
  log("stopped")
end

-- ⌥F8 → 循環
hs.hotkey.bind({"alt"}, "F8", function()
  running = not running
  if running then
    runCount = 0
    waitTries = 0
    updateForestMenuBar()
    hs.alert.show("[forest_loop] 循環開始（隨機版）")

    -- ✅ 先立即施放一次 Buff（5、6），之後固定間隔施放
    pressBuffKeys()
    buffTimer = hs.timer.doEvery(BUFF_INTERVAL, pressBuffKeys)

    runOnce()
  else
    emergencyStop()
  end
end)

-- ⌥F6 → 單次測試（執行「一整輪隨機」）
hs.hotkey.bind({"alt"}, "F6", function()
  if running then hs.alert.show("[forest_loop] 請先關閉循環"); return end
  hs.alert.show("[forest_loop] 單次隨機輪開始")
  local saveRun = running
  running = true
  runCount = 0
  waitTries = 0
  updateForestMenuBar()
  runCycle()
  -- 在一輪結束後自動停（靠 runCycle 裡的 running 判斷）
  pushTimer(hs.timer.doAfter(0.1, function() running = saveRun end))
end)

-- ⌥F9 → 停止
hs.hotkey.bind({"alt"}, "F9", emergencyStop)

-- ⌥F1 → 印出目前前景 App 資訊（name/bundleID）
hs.hotkey.bind({"alt"}, "F1", function()
  local app = hs.application.frontmostApplication()
  if not app then
    hs.alert.show("無前景 App"); return
  end
  local msg = string.format("Front App: name='%s', bundleID='%s'", app:name() or "?", app:bundleID() or "?")
  hs.printf(msg)
  hs.alert.show("已列印前景 App 到 Console")
end)

-- 全域停止匯流排
_G.__HS_STOP_BUS = _G.__HS_STOP_BUS or {}
table.insert(_G.__HS_STOP_BUS, emergencyStop)

return mod