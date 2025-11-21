-- ~/.hammerspoon/scripts/祈禱機-戰鬥7-全自動魚屋.lua
-- 流程：
--   啟動：馬上跑一輪「buff + 左移到打怪點 + 等怪偵測 + 攻擊 + 回原位」。
--   之後：
--     - 每 FULL_CYCLE_SEC 秒，再重跑一次上述流程。
--   buff：
--     - 0：15 分鐘 buff，首次一定施放，之後於剩餘 SKILL0_RECAST_EARLY_SEC 秒時重放。
--     - 1/2/Q：每輪 buff 一起施放，依 ENABLE_SKILL? 開關控制。

local mod = {}

------------------------------------------------------------
-- 參數區
------------------------------------------------------------
local TARGET_APP_NAMES      = { "MapleStory Worlds", "MapleStory" }

-- 怪物偵測（Hammerspoon 截圖 → Python + OpenCV）
local MONSTER_CAPTURE_PATH  = "/tmp/ham_monster_check.png"
-- local MONSTER_CLIENT_SCRIPT = "/Users/theo/data/github/artale/detect_client_nc.sh"
local MONSTER_CLIENT_SCRIPT = "/Users/theo/data/github/artale/detect_client.sh"
local MONSTER_POLL_SEC      = 0.1        -- 等怪時的偵測間隔

------------------------------------------------------------

-- 倒數
local PRE_ATTACK_COUNTDOWN_SEC = 1
local COUNTDOWN_TICK_MS        = 150

-- Buff 0/1/2/Q
local SKILL0_KEY           = "0"      -- 15 分鐘大 buff
local SKILL1_KEY           = "1"
local SKILL2_KEY           = "2"
local SKILLQ_KEY           = "3"

local ENABLE_SKILL0        = true --false/true
local ENABLE_SKILL1        = true
local ENABLE_SKILL2        = true
local ENABLE_SKILLQ        = false

-- 0 鍵 buff：實際為 15 分鐘，提前 20 秒重放（14:40）
local SKILL0_DURATION_SEC         = 15 * 60
local SKILL0_RECAST_EARLY_SEC     = 20
local SKILL0_RECAST_THRESHOLD_SEC = SKILL0_DURATION_SEC - SKILL0_RECAST_EARLY_SEC

-- 按鍵時間
local KEY_TAP_MS           = 85
local SKILL_CAST_GAP_MS    = 800
local SKILL2_TAP_MS        = 200
local SKILL2_PRE_DELAY_MS  = 120
local SKILL2_RETRY_DELAY_MS= 260

-- 攻擊設定
local ATTACK_HOLD_MIN_SEC  = 15
local ATTACK_HOLD_MAX_SEC  = 17
-- 移動相關
local MOVE_LEFT_TO_SPOT_SEC      = 1.65   -- buff 後往左走到打怪點
local POST_ATTACK_EXTRA_LEFT_SEC = 1.2   -- 打完後額外往左走幾秒（不要就設 0）
local MOVE_RIGHT_BACK_SEC        = 2.3   -- 打完後往右走回原位幾秒（跟左邊可以不同）

local POST_ATTACK_KEYCODE  = 7         -- X
local POST_ATTACK_PRESS_MS = 140
local POST_Z_TO_X_DELAY_MS = 340
local POST_Z_TO_X_EXTRA_SETTLE_MS = 60
local POST_ATTACK_X_RETRIES       = 1
local POST_ATTACK_X_RETRY_GAP_MS  = 120

-- 週期控制（buff ＋ 攻擊一起跑）
local FULL_CYCLE_SEC        = 210        -- 每幾秒跑一次完整流程

-- 如果「等怪 → 開始 Z」超過這些秒數，就把下一輪 buff 倒數往前拉這麼多秒
local WAIT_BEFORE_ATTACK_THRESHOLD_SEC = 30   -- 超過多少秒算「等太久」
local WAIT_BEFORE_ATTACK_ADJUST_SEC    = 30   -- 要補回多少秒（你說要補 30 秒）

-- X 前喚醒
local PRE_X_WAKE_ENABLED   = true
local PRE_X_WAKE_KEYS      = { "right", "left" }
local PRE_X_WAKE_TAP_MS    = 45
local PRE_X_WAKE_GAP_MS    = 45

-- UI / 熱鍵
local UI_TICK_SEC          = 0.5
local ENABLE_MANUAL_TRIGGER_ON_CLICK = true
local MENU_CLICK_DEBOUNCE_SEC       = 0.4
local MENU_CLICK_TO_ACTION_DELAY_MS = 250

-- 聚焦
local FOCUS_ON_ACTION      = true
local FOCUS_ON_MENU_CLICK  = true
local REQUIRE_FRONTMOST    = true
local FOCUS_WAIT_TIMEOUT_MS= 900
local CAST_FOCUS_SETTLE_MS = 400

-- Debug
local DEBUG = true
local function log(...)
  if DEBUG then print("[skillbot]", ...) end
end

------------------------------------------------------------
-- 工具函式
------------------------------------------------------------
math.randomseed(os.time())
local function randf(a,b) return a + math.random()*(b-a) end
local function fmt_mmss(sec)
  sec = math.max(0, math.floor(sec or 0))
  return string.format("%d:%02d", math.floor(sec/60), sec%60)
end

-- UI
local menuBar = nil
local function ensureMenuBar()
  if not menuBar then
    menuBar = hs.menubar.new()
    if menuBar then
      menuBar:setTitle("待機")
      menuBar:setTooltip("點一下：倒數→buff→打怪")
    end
  end
end

local function safeSetBar(s)
  ensureMenuBar()
  if not menuBar then return end
  local ok, err = pcall(function() menuBar:setTitle(s or "…") end)
  if not ok then print("[skillbot] setBar error:", err) end
end

-- 輸入法
local function ensureUSKeyboard()
  local ok = hs.keycodes.setLayout("U.S.")
  if not ok then hs.keycodes.setLayout("ABC") end
end

-- 目標 app
local function isTargetName(name)
  if not name or name == "" then return false end
  for _, n in ipairs(TARGET_APP_NAMES) do
    if name == n then return true end
  end
  if string.find(string.lower(name), "maplestory", 1, true) then return true end
  return false
end

local function findTargetApp()
  for _, n in ipairs(TARGET_APP_NAMES) do
    local a = hs.appfinder.appFromName(n)
    if a then return a end
  end
  return hs.application.find("MapleStory")
end

-- 聚焦
local function focusAppAndWait(timeout_ms)
  if not FOCUS_ON_ACTION then return true end
  local app = findTargetApp()
  if not app then log("focus fail: target app not found"); return false end
  app:activate(true)
  local waited, step, limit = 0, 40, math.max(0, timeout_ms or FOCUS_WAIT_TIMEOUT_MS)
  while waited <= limit do
    local fw = hs.window.frontmostWindow()
    local a  = fw and fw:application()
    local nm = a and a:name() or ""
    if isTargetName(nm) then
      if CAST_FOCUS_SETTLE_MS>0 then hs.timer.usleep(CAST_FOCUS_SETTLE_MS*1000) end
      local mw = app and app:mainWindow(); if mw then mw:focus() end
      return true
    end
    hs.timer.usleep(step*1000); waited = waited + step
  end
  local fw = hs.window.frontmostWindow(); local a = fw and fw:application()
  log("focus fail, frontmost=", a and a:name() or "nil")
  return false
end

-- key event
local function postKeycodeToApp(app, keycode, isDown)
  local ev = hs.eventtap.event.newKeyEvent({}, keycode, isDown)
  if not ev then return false end
  local ok = pcall(function() ev:post(app) end)
  return ok
end

local function tapKeyToApp(app, keyName, press_ms)
  local ms = press_ms or KEY_TAP_MS
  local kc = hs.keycodes.map[keyName]
  if not kc then return false end
  local okD = postKeycodeToApp(app, kc, true)
  hs.timer.usleep(ms*1000)
  local okU = postKeycodeToApp(app, kc, false)
  return okD and okU
end

local function tapKeyGlobal(keyOrCode, press_ms)
  local isNum = type(keyOrCode)=="number"
  local d = hs.eventtap.event.newKeyEvent({}, (isNum and keyOrCode or keyOrCode), true)
  local u = hs.eventtap.event.newKeyEvent({}, (isNum and keyOrCode or keyOrCode), false)
  if d then d:post() end
  hs.timer.usleep((press_ms or KEY_TAP_MS)*1000)
  if u then u:post() end
end

local function keyDownApp(app, keyName)
  local kc = hs.keycodes.map[keyName]; if not kc then return end
  if not postKeycodeToApp(app, kc, true) then
    hs.eventtap.event.newKeyEvent({}, keyName, true):post()
  end
end

local function keyUpApp(app, keyName)
  local kc = hs.keycodes.map[keyName]; if not kc then return end
  if not postKeycodeToApp(app, kc, false) then
    hs.eventtap.event.newKeyEvent({}, keyName, false):post()
  end
end

-- 守門（避免短時間重複送同一鍵）
local lastKeySentAt = {}
local function guardTap(keyTag, window_ms)
  local now = hs.timer.secondsSinceEpoch()
  local last = lastKeySentAt[keyTag] or 0
  if (now - last)*1000 < (window_ms or 260) then return false end
  lastKeySentAt[keyTag] = now
  return true
end

local function resetIdle(src) log("idle reset by:", src or "unknown") end
local function stopTimer(t) if t and t:running() then t:stop() end; return nil end

------------------------------------------------------------
-- 遊戲視窗截圖（只抓 Maple 視窗）
------------------------------------------------------------
local function captureWindowToFile(outPath)
  local app = findTargetApp()
  if not app then
    log("monster capture: app not found")
    return false
  end

  local win = app:mainWindow()
  if not win then
    log("monster capture: mainWindow not found")
    return false
  end

  -- 只抓這個視窗
  local img = win:snapshot()
  if not img then
    log("monster capture: window snapshot failed")
    return false
  end

  img:saveToFile(outPath)          -- 保持 PNG 就好
  local sz = img:size()
  log(string.format("monster capture saved (WINDOW), size=%dx%d", sz.w, sz.h))
  return true
end

------------------------------------------------------------
-- 怪物偵測（Python 輸出：FOUND / NOT_FOUND / UNKNOWN）
------------------------------------------------------------
local function parseMonsterResult(output)
  if not output or output == "" then return "UNKNOWN" end
  if output:find("NOT_FOUND", 1, true) then
    return "NOT_FOUND"
  elseif output:find("FOUND", 1, true) then
    return "FOUND"
  else
    return "UNKNOWN"
  end
end

local MONSTER_SERVER_HOST = "127.0.0.1"
local MONSTER_SERVER_PORT = 8765

local function detectMonster()
  local okCap = captureWindowToFile(MONSTER_CAPTURE_PATH)
  if not okCap then return false end

  local cmd = string.format(
    "/Users/theo/data/github/artale/detect_client.sh '%s'",
    MONSTER_CAPTURE_PATH
  )
  local out = hs.execute(cmd):gsub("\n","")
  log("[monster] result = " .. out)

  return (out == "FOUND")
end

local function debugCaptureOnly()
  local ok = captureWindowToFile(MONSTER_CAPTURE_PATH)
  if ok then
    log("debug capture saved to: "..MONSTER_CAPTURE_PATH)
    hs.alert.show("已截圖 → "..MONSTER_CAPTURE_PATH)
  else
    log("debug capture failed")
    hs.alert.show("截圖失敗")
  end
end

------------------------------------------------------------
-- 狀態
------------------------------------------------------------
local enabled          = false
local uiTicker         = nil
local flowRunning      = false       -- 一輪 buff+打怪 是否在跑
local buffCasting      = false

local holdTimer        = nil
local afterHoldTimer   = nil
local preAttackTimer   = nil
local preAttackEndAt   = nil
local monsterPollTimer = nil

local holdEndAt        = nil
local nextFullCycleAt  = nil
local lastSkill0CastAt = nil

------------------------------------------------------------
-- Buff 0 判斷＆施放
------------------------------------------------------------
local function maybeCastSkill0(app)
  if not ENABLE_SKILL0 or not SKILL0_KEY then return end
  local now = hs.timer.secondsSinceEpoch()
  if lastSkill0CastAt then
    local elapsed = now - lastSkill0CastAt
    if elapsed < SKILL0_RECAST_THRESHOLD_SEC then
      return
    end
  end
  if not guardTap("skill0", 260) then
    log("guard: skip duplicate skill0")
    return
  end
  log(string.format("cast long buff: 0 (elapsed=%.1fs)", lastSkill0CastAt and (now-lastSkill0CastAt) or -1))
  if not tapKeyToApp(app, SKILL0_KEY, KEY_TAP_MS) then
    log("skill0 direct-app failed; fallback global")
    tapKeyGlobal(SKILL0_KEY, KEY_TAP_MS)
  end
  lastSkill0CastAt = now
end

------------------------------------------------------------
-- Buff 1/2/Q 施放
------------------------------------------------------------
local function castSkillSequence_once()
  local app = findTargetApp()
  if not app then log("castSkill: app not found"); return false end
  if REQUIRE_FRONTMOST and (not focusAppAndWait(FOCUS_WAIT_TIMEOUT_MS)) then
    log("castSkill: focus fail"); return false
  end

  ensureUSKeyboard()
  if CAST_FOCUS_SETTLE_MS>0 then hs.timer.usleep(CAST_FOCUS_SETTLE_MS*1000) end

  -- 0（長 CD）
  maybeCastSkill0(app)

  -- 1
  if ENABLE_SKILL1 and SKILL1_KEY and guardTap("skill1", 260) then
    log("cast buff 1")
    if not tapKeyToApp(app, SKILL1_KEY, KEY_TAP_MS) then
      tapKeyGlobal(SKILL1_KEY, KEY_TAP_MS)
    end
  end

  hs.timer.usleep(SKILL_CAST_GAP_MS*1000)

  -- 2（較長按＋一次 retry）
  if ENABLE_SKILL2 and SKILL2_KEY then
    if SKILL2_PRE_DELAY_MS>0 then hs.timer.usleep(SKILL2_PRE_DELAY_MS*1000) end
    log("cast buff 2 #1")
    local ok2 = tapKeyToApp(app, SKILL2_KEY, SKILL2_TAP_MS)
    if not ok2 then
      hs.timer.usleep(SKILL2_RETRY_DELAY_MS*1000)
      log("cast buff 2 #2")
      ok2 = tapKeyToApp(app, SKILL2_KEY, SKILL2_TAP_MS)
      if not ok2 then
        tapKeyGlobal(SKILL2_KEY, SKILL2_TAP_MS)
      end
    end
  end

  -- Q
  if ENABLE_SKILLQ and SKILLQ_KEY and guardTap("skillQ", 260) then
    hs.timer.usleep(SKILL_CAST_GAP_MS*1000)
    log("cast buff Q")
    if not tapKeyToApp(app, SKILLQ_KEY, KEY_TAP_MS) then
      tapKeyGlobal(SKILLQ_KEY, KEY_TAP_MS)
    end
  end

  return true
end

local function castSkillSequence(onDone)
  if buffCasting then
    log("buff casting already running; skip")
    if onDone then onDone(false) end
    return
  end
  buffCasting = true
  local ok = castSkillSequence_once()
  buffCasting = false
  if onDone then onDone(ok) end
end

------------------------------------------------------------
-- X 前喚醒 ＋ 收尾 X
------------------------------------------------------------
local function preWakeBeforeX(app)
  if not PRE_X_WAKE_ENABLED or not app then return end
  for _, k in ipairs(PRE_X_WAKE_KEYS or {}) do
    tapKeyToApp(app, k, PRE_X_WAKE_TAP_MS)
    hs.timer.usleep((PRE_X_WAKE_GAP_MS or 40)*1000)
  end
end

local function sendX_once(app)
  if POST_Z_TO_X_EXTRA_SETTLE_MS>0 then hs.timer.usleep(POST_Z_TO_X_EXTRA_SETTLE_MS*1000) end
  preWakeBeforeX(app)
  local okD = postKeycodeToApp(app, POST_ATTACK_KEYCODE, true)
  hs.timer.usleep(POST_ATTACK_PRESS_MS*1000)
  local okU = postKeycodeToApp(app, POST_ATTACK_KEYCODE, false)
  if not (okD and okU) then
    tapKeyGlobal(POST_ATTACK_KEYCODE, POST_ATTACK_PRESS_MS)
  end
  log("post-attack X sent")
  return okD and okU
end

------------------------------------------------------------
-- 攻擊段：Z 按住 → X 收尾 → 往右走回原位
------------------------------------------------------------
local function performAttackSegment(onDone)
  local app = findTargetApp()
  if not app then if onDone then onDone() end; return end
  focusAppAndWait()

  local holdSec = randf(ATTACK_HOLD_MIN_SEC, ATTACK_HOLD_MAX_SEC)
  holdEndAt = hs.timer.secondsSinceEpoch() + holdSec

  keyDownApp(app, "z")
  resetIdle("attack-start(Z-down)")

  holdTimer = stopTimer(holdTimer)
  holdTimer = hs.timer.doAfter(holdSec, function()
    keyUpApp(app, "z")
    log(string.format("Z hold finished (%.2fs)", holdSec))

    afterHoldTimer = stopTimer(afterHoldTimer)
    afterHoldTimer = hs.timer.doAfter(POST_Z_TO_X_DELAY_MS/1000, function()
      ensureUSKeyboard()

      if guardTap("postX", 800) then
        local ok = sendX_once(app)
        for i=1, (POST_ATTACK_X_RETRIES or 0) do
          if ok then break end
          hs.timer.usleep(POST_ATTACK_X_RETRY_GAP_MS*1000)
          ok = sendX_once(app)
        end
        resetIdle("post-attack-X")
      end

      -- ⭐ 打完後多往左走 N 秒（可選）
      if POST_ATTACK_EXTRA_LEFT_SEC and POST_ATTACK_EXTRA_LEFT_SEC > 0 then
        log(string.format("post-attack: EXTRA LEFT for %.2fs", POST_ATTACK_EXTRA_LEFT_SEC))
        keyDownApp(app, "left")
        hs.timer.usleep(POST_ATTACK_EXTRA_LEFT_SEC * 1000000)
        keyUpApp(app, "left")
      end

      -- ⭐ 最後往右走回原位（時間可以跟左邊不同）
      if MOVE_RIGHT_BACK_SEC and MOVE_RIGHT_BACK_SEC > 0 then
        log(string.format("post-attack: move RIGHT back for %.2fs", MOVE_RIGHT_BACK_SEC))
        keyDownApp(app, "right")
        hs.timer.usleep(MOVE_RIGHT_BACK_SEC * 1000000)
        keyUpApp(app, "right")
      end

      holdEndAt = nil
      if onDone then onDone() end
    end)
  end)
end

------------------------------------------------------------
-- 單輪流程：buff → 往左走到打怪點 → 等怪 → Z/X 打一次 → 回原位
------------------------------------------------------------
local function scheduleNextFullCycle(fromEpoch)
  local base = fromEpoch or hs.timer.secondsSinceEpoch()
  nextFullCycleAt = base + FULL_CYCLE_SEC
  log(string.format("next full cycle in %.1fs", nextFullCycleAt - base))
end

local function moveToHuntSpot()
  if not MOVE_LEFT_TO_SPOT_SEC or MOVE_LEFT_TO_SPOT_SEC <= 0 then return end
  local app = findTargetApp()
  if not app then return end
  focusAppAndWait(FOCUS_WAIT_TIMEOUT_MS)
  log(string.format("after-buff: move LEFT for %.2fs", MOVE_LEFT_TO_SPOT_SEC))
  keyDownApp(app, "left")
  hs.timer.usleep(MOVE_LEFT_TO_SPOT_SEC * 1000000)
  keyUpApp(app, "left")
end

local function waitMonsterThenAttack(onDone)
  -- 開始等怪的時間
  local waitStart = hs.timer.secondsSinceEpoch()

  local function poll()
    if not enabled or not flowRunning then
      monsterPollTimer = nil
      return
    end

    if detectMonster() then
      local foundAt = hs.timer.secondsSinceEpoch()
      local waited  = foundAt - waitStart

      monsterPollTimer = nil
      log(string.format("[watch] monster FOUND, start attack (waited=%.2fs)", waited))

      performAttackSegment(function()
        if onDone then onDone(waited) end
      end)
    else
      monsterPollTimer = hs.timer.doAfter(MONSTER_POLL_SEC, poll)
    end
  end

  poll()
end

local function runOneFullCycle()
  if flowRunning then
    log("full cycle already running; skip")
    return
  end
  flowRunning = true
  log("runOneFullCycle: start")

  local function doBuffAndHunt()
    castSkillSequence(function(ok)
      if not ok then
        flowRunning = false
        scheduleNextFullCycle()
        return
      end

      moveToHuntSpot()

      waitMonsterThenAttack(function(waitedSec)
        local now = hs.timer.secondsSinceEpoch()
        flowRunning = false

        local baseTime = now
        if waitedSec and waitedSec >= WAIT_BEFORE_ATTACK_THRESHOLD_SEC then
          local adjust = math.min(waitedSec, 60)
          baseTime = now - adjust
          log(string.format(
            "waited %.1fs before attack, adjust next cycle by -%.1fs",
            waitedSec, adjust
          ))
        end

        scheduleNextFullCycle(baseTime)
        safeSetBar(string.format("Buff輪 %s", fmt_mmss(FULL_CYCLE_SEC)))
      end)
    end)
  end

  -- 若有倒數則先跑倒數
  if PRE_ATTACK_COUNTDOWN_SEC>0 then
    preAttackEndAt = hs.timer.secondsSinceEpoch() + PRE_ATTACK_COUNTDOWN_SEC
    preAttackTimer = stopTimer(preAttackTimer)
    preAttackTimer = hs.timer.new(COUNTDOWN_TICK_MS/1000, function()
      local now = hs.timer.secondsSinceEpoch()
      local remain = math.max(0, math.ceil((preAttackEndAt or now)-now))
      safeSetBar("開打倒數 "..fmt_mmss(remain))
      if remain<=0 then
        preAttackTimer:stop(); preAttackTimer=nil; preAttackEndAt=nil
        doBuffAndHunt()
      end
    end)
    preAttackTimer:start()
    safeSetBar("開打倒數 "..fmt_mmss(PRE_ATTACK_COUNTDOWN_SEC))
  else
    doBuffAndHunt()
  end
end

------------------------------------------------------------
-- UI 更新（Buff 倒數 + 攻擊 hold 倒數）
------------------------------------------------------------
local function updateBar()
  local now = hs.timer.secondsSinceEpoch()

  if preAttackTimer and preAttackTimer:running() then
    return
  end

  local buffStr = "--:--"
  if nextFullCycleAt then
    local remFull = math.max(0, math.ceil(nextFullCycleAt - now))
    buffStr = fmt_mmss(remFull)
  end

  local atkStr = "--"
  if holdEndAt then
    atkStr = tostring(math.max(0, math.ceil(holdEndAt - now))).."s"
  end

  if flowRunning and holdEndAt then
    safeSetBar(string.format("Buff %s | 攻擊中 %s", buffStr, atkStr))
  elseif flowRunning then
    safeSetBar(string.format("Buff %s | 執行中", buffStr))
  else
    safeSetBar(string.format("Buff %s | 待機", buffStr))
  end
end

local function uiTick()
  if not enabled then return end
  local now = hs.timer.secondsSinceEpoch()

  if flowRunning or buffCasting or (preAttackTimer and preAttackTimer:running()) then
    updateBar()
    return
  end

  if nextFullCycleAt and now>=nextFullCycleAt then
    runOneFullCycle()
    return
  end

  updateBar()
end

------------------------------------------------------------
-- 啟停 / 熱鍵
------------------------------------------------------------
local function stopTimerSafe(t) if t and t:running() then t:stop() end end

local function stopAll(reason)
  enabled = false
  stopTimerSafe(uiTicker);        uiTicker        = nil
  stopTimerSafe(preAttackTimer);  preAttackTimer  = nil
  stopTimerSafe(holdTimer);       holdTimer       = nil
  stopTimerSafe(afterHoldTimer);  afterHoldTimer  = nil
  stopTimerSafe(monsterPollTimer);monsterPollTimer= nil
  preAttackEndAt  = nil
  holdEndAt       = nil
  nextFullCycleAt = nil
  buffCasting     = false
  flowRunning     = false

  local app = findTargetApp()
  if app then keyUpApp(app, "z") end

  safeSetBar("待機")
  log("stopped, reason="..(reason or "stopAll"))
end

local function startRun()
  if enabled then return end
  enabled          = true
  lastSkill0CastAt = nil
  nextFullCycleAt  = nil

  runOneFullCycle()

  uiTicker = hs.timer.doEvery(UI_TICK_SEC, uiTick)
  log("enabled")
end

local function manualTriggerOnce()
  runOneFullCycle()
end

ensureMenuBar()
local lastMenuClickAt = 0
if menuBar then
  menuBar:setClickCallback(function()
    local now = hs.timer.secondsSinceEpoch()
    if now - lastMenuClickAt < MENU_CLICK_DEBOUNCE_SEC then return end
    lastMenuClickAt = now
    resetIdle("menubar-click")
    hs.timer.doAfter(MENU_CLICK_TO_ACTION_DELAY_MS/1000, function()
      if FOCUS_ON_MENU_CLICK then focusAppAndWait(FOCUS_WAIT_TIMEOUT_MS) end
      if ENABLE_MANUAL_TRIGGER_ON_CLICK then manualTriggerOnce() end
    end)
  end)
end

-- 只用來 reset idle 顯示
local Z_KEY_CODE = 6
local keyboardWatcher = hs.eventtap.new(
  { hs.eventtap.event.types.keyDown },
  function(ev)
    local ar = ev:getProperty(hs.eventtap.event.properties.keyboardEventAutorepeat)
    if ar == 0 and ev:getKeyCode() == Z_KEY_CODE then resetIdle("Z-key") end
    return false
  end
)
keyboardWatcher:start()
log("keyboardWatcher started – only keyCode "..Z_KEY_CODE.." resets idle display")

-- 熱鍵：F10 啟停、F8 手動一輪、F9 緊急停止、F7 截圖
hs.hotkey.bind({"cmd","alt"}, "F10", function()
  if enabled then
    log("F10 stopRun")
    stopAll("hotkey-F10-toggle")
  else
    log("F10 startRun")
    startRun()
  end
end)
hs.hotkey.bind({"cmd","alt"}, "F8", function() manualTriggerOnce() end)
hs.hotkey.bind({"cmd","alt"}, "F9", function()
  log("F9 emergency stop")
  stopAll("hotkey-F9")
end)
hs.hotkey.bind({"cmd","alt"}, "F7", function() debugCaptureOnly() end)

safeSetBar("待機")
log("✔ 全自動魚屋 loaded（buff + 打怪單輪循環）")

mod.start = startRun
mod.stop  = stopAll
mod.once  = manualTriggerOnce

return mod