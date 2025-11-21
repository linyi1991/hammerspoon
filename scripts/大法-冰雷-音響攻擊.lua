-- ~/.hammerspoon/scripts/forest_loop.lua
-- 死亡森林2：Q(瞬移) + Z(補血)，移動 → 停下攻擊 → 循環
-- 熱鍵：
--   ⌥F8 → 開/關循環
--   ⌥F6 → 單次測試
--   ⌥F9 → 停止
--   ⌥F1 → 列印目前前景 App 的 name/bundleID（偵錯）

local mod = {}

----------------------------------------------------------------------
-- 可調參數
----------------------------------------------------------------------
-- 前景檢查模式: "lenient"（預設）|"strict"|"none"
local FOREGROUND_MODE = "lenient"
local MAX_WAIT_TRIES  = 3       -- lenient 模式下最多等待次數（每次 0.4s）

-- 允許多個名稱/Bundle ID；任一匹配即視為目標（大小寫不敏感）
local TARGET_NAMES = {
  "MapleStory",          -- 你目前用的名稱；若不同可改
  -- "MapleStory Worlds",
}
local TARGET_BUNDLE_IDS = {
  -- 建議用 ⌥F1 印出實際 bundleID 後填入，例如： "com.nexon.maplestory"
}

-- 路徑/節奏設定（秒）
local RIGHT_SEC        = 10.0   -- 向右總持續秒數
local LEFT_SEC         = 10.0   -- 向左總持續秒數
local REST_SEC         = 0.293    -- 每輪休息秒數
local MOVE_CHUNK_SEC   = 0.1  -- 每次移動多久（Q+方向鍵按住）
local ATTACK_STOP_SEC  = 1.055    -- 每段移動後原地 Z 多久

-- 技能鍵
local SKILL_KEY  = "q"          -- 瞬移技能（按住）
local ATTACK_KEY = "z"          -- 攻擊/補血技能（按住）

-- Buff：開循環就先施放一次，之後固定間隔施放
local BUFF_KEYS      = { "5", "6" } -- 若用數字小鍵盤可寫 { "pad5", "pad6" }
local BUFF_INTERVAL  = 198          -- 每多少秒放一次（300s 到期前 1s 先補）
local BUFF_PRESS_MS  = 150           -- 每顆 Buff 鍵按住毫秒
local BUFF_GAP_MS    = 420          -- 兩顆 Buff 鍵之間的間隔
local BUFF_RETRIES   = 0            -- 補按次數（0=不補按；建議 1）

----------------------------------------------------------------------
-- 狀態 / 工具
----------------------------------------------------------------------
local running, timers, runCount, buffTimer = false, {}, 0, nil
local waitTries = 0

local forestMenuBar = hs.menubar.new()
if forestMenuBar then forestMenuBar:setTitle("死2-x0") end

local function log(fmt, ...)
  hs.printf("[forest_loop] " .. string.format(fmt, ...))
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
-- 一段：移動 MOVE_CHUNK_SEC 秒 → 原地 Z ATTACK_STOP_SEC 秒
----------------------------------------------------------------------
local function doMoveAndStopAttack(dir, elapsed, limit, onDone)
  if elapsed >= limit then
    if onDone then onDone() end
    return
  end

  -- Step1: 移動 (Q+方向 down)
  hs.eventtap.event.newKeyEvent({}, SKILL_KEY, true):post()
  hs.eventtap.event.newKeyEvent({}, dir, true):post()

  pushTimer(hs.timer.doAfter(MOVE_CHUNK_SEC, function()
    -- Step2: 放開方向，但保持 Q
    hs.eventtap.event.newKeyEvent({}, dir, false):post()

    -- Step3: 原地攻擊 Z
    hs.eventtap.event.newKeyEvent({}, ATTACK_KEY, true):post()

    pushTimer(hs.timer.doAfter(ATTACK_STOP_SEC, function()
      hs.eventtap.event.newKeyEvent({}, ATTACK_KEY, false):post()
      hs.eventtap.event.newKeyEvent({}, SKILL_KEY, false):post()

      -- 下一個小段
      doMoveAndStopAttack(dir, elapsed + MOVE_CHUNK_SEC + ATTACK_STOP_SEC, limit, onDone)
    end))
  end))
end

----------------------------------------------------------------------
-- 主流程：右 → 左 → 休息
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
  log("run cycle start (right=%ss, left=%ss)", RIGHT_SEC, LEFT_SEC)

  doMoveAndStopAttack("right", 0, RIGHT_SEC, function()
    doMoveAndStopAttack("left", 0, LEFT_SEC, function()
      runCount = runCount + 1
      updateForestMenuBar()
      log("cycle finished #%d; rest %ss", runCount, REST_SEC)
      if running then
        pushTimer(hs.timer.doAfter(REST_SEC, runOnce))
      end
    end)
  end)
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
end

-- ⌥F8 → 循環
hs.hotkey.bind({"alt"}, "F8", function()
  running = not running
  if running then
    runCount = 0
    waitTries = 0
    updateForestMenuBar()
    hs.alert.show("[forest_loop] 循環開始")

    -- ✅ 先立即施放一次 Buff（5、6）
    pressBuffKeys()
    -- ✅ 再每 299 秒施放一次
    buffTimer = hs.timer.doEvery(BUFF_INTERVAL, pressBuffKeys)

    runOnce()
  else
    emergencyStop()
  end
end)

-- ⌥F6 → 單次測試
hs.hotkey.bind({"alt"}, "F6", function()
  if running then hs.alert.show("[forest_loop] 請先關閉循環") return end
  hs.alert.show("[forest_loop] 單次測試開始")
  doMoveAndStopAttack("right", 0, RIGHT_SEC, function()
    doMoveAndStopAttack("left", 0, LEFT_SEC, function()
      hs.alert.show("[forest_loop] 單次完成")
    end)
  end)
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
