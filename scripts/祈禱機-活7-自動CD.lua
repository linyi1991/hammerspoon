-- ~/.hammerspoon/scripts/祈禱機-活7-全自動魚屋.lua
-- 週期：倒數→人性化→1→(gap)→2(三段式)→延遲→Z按住→放開→X(一次，強化直投/冗餘)→排下一輪

local mod = {}

------------------------------------------------------------
-- 🔧 參數區（全部集中這裡）
------------------------------------------------------------
local TARGET_APP_NAMES              = { "MapleStory Worlds", "MapleStory" }

-- 聚焦/前景
local REQUIRE_FRONTMOST             = true
local FOCUS_ON_ACTION               = true
local FOCUS_ON_MENU_CLICK           = true
local FOCUS_WAIT_TIMEOUT_MS         = 900
local CAST_FOCUS_SETTLE_MS          = 400

-- 週期（約 5 分鐘）
local CYCLE_SEC                     = 290
local CYCLE_EARLY_JITTER_PCT_MIN    = 0.003
local CYCLE_EARLY_JITTER_PCT_MAX    = 0.010

-- 倒數 & 人性化
local PRE_ATTACK_COUNTDOWN_SEC      = 3
local COUNTDOWN_TICK_MS             = 150
local HUMANIZE_ON_COUNTDOWN         = true
local HUMANIZE_LR_MODE              = "random"     -- random/left/right
local HUMANIZE_TAP_MS               = 60
local HUMANIZE_GAP_MS               = 90
local HUMANIZE_DOWN_TAPS_MIN        = 2
local HUMANIZE_DOWN_TAPS_MAX        = 3
local HUMANIZE_TO_BUFF_DELAY_MS     = 160

-- Buff 1/2
local SKILL1_KEY                    = "1"
local SKILL2_KEY                    = "2"
local KEY_TAP_MS                    = 85
local SAME_KEY_GUARD_MS             = 260
local SKILL_CAST_GAP_MS             = 800
local SKILL2_RETRY1_DELAY_MS        = 180
local SKILL2_RETRY2_DELAY_MS        = 100

-- 攻擊段
local POST_CAST_DELAY_SEC           = 1.25
local ATTACK_HOLD_MODE              = "fixed"      -- fixed | random
local ATTACK_HOLD_SEC               = 3.5
local ATTACK_HOLD_MIN_SEC           = 10
local ATTACK_HOLD_MAX_SEC           = 15

-- ✅ 收尾 X：完全參數化 + 多路冗餘
--   X 的 macOS keycode = 7（避免輸入法/語系）
local POST_ATTACK_KEY               = "x"          -- 說明用途；實際送數值 keycode
local POST_ATTACK_KEYCODE           = 7            -- <== 主要用這個發送（down/up）
local POST_ATTACK_PRESS_MS          = 140          -- 建議 110~180；若沒觸發可再加
local POST_Z_TO_X_DELAY_MS          = 340          -- Z 放開後到送 X 的延遲（首要調參：280/320/340/380）
local POST_Z_TO_X_EXTRA_SETTLE_MS   = 60           -- 再加一點沉靜，避免剛放 Z 時被吃鍵
local POST_ATTACK_X_MODE            = "double"     -- app_first | global_first | double
local POST_ATTACK_X_RETRIES         = 1            -- 若想更兇可設 2（不會超發，因有 guard）
local POST_ATTACK_X_RETRY_GAP_MS    = 120
local POST_ATTACK_X_GUARD_MS        = 800          -- 防重入（避免多次觸發）

-- ✅ X 前喚醒鍵（方向鍵輕點，清輸入緩衝）
local PRE_X_WAKE_ENABLED            = true
local PRE_X_WAKE_KEYS               = { "right", "left" }
local PRE_X_WAKE_TAP_MS             = 45
local PRE_X_WAKE_GAP_MS             = 45

-- 施放階段微移動
local MOVE_STYLE                    = "none"       -- none | dash | tap
local DASH_GAP_MS                   = 120
local TAP_MIN_MS                    = 80
local TAP_MAX_MS                    = 80

-- UI / 熱鍵
local ENABLE_MANUAL_TRIGGER_ON_CLICK= true
local MENU_CLICK_DEBOUNCE_SEC       = 0.4
local MENU_CLICK_TO_ACTION_DELAY_MS = 250
local UI_TICK_SEC                   = 0.5

-- Debug
local DEBUG                         = true
local function log(...) if DEBUG then print("[skillbot]", ...) end end

------------------------------------------------------------
-- 🧰 小工具
------------------------------------------------------------
math.randomseed(os.time())
local function randf(a,b) return a + math.random()*(b-a) end
local function randi(a,b) return math.floor(a + math.random()*(b-a+1)) end
local function fmt_mmss(sec) sec=math.max(0,math.floor(sec or 0)); return string.format("%d:%02d",math.floor(sec/60),sec%60) end

-- UI
local menuBar=nil
local function ensureMenuBar()
  if not menuBar then
    menuBar = hs.menubar.new()
    menuBar:setTitle("待機")
    menuBar:setTooltip("點一下：倒數→施放→攻擊")
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
  for _, n in ipairs(TARGET_APP_NAMES) do if name == n then return true end end
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
    hs.timer.usleep(step * 1000); waited = waited + step
  end
  local fw = hs.window.frontmostWindow(); local a = fw and fw:application()
  log("focus fail, frontmost=", a and a:name() or "nil")
  return false
end

-- event 發送
local function postKeycodeToApp(app, keycode, isDown)
  local ev = hs.eventtap.event.newKeyEvent({}, keycode, isDown)
  if not ev then return false end
  local ok = pcall(function() ev:post(app) end)
  return ok
end
local function tapKeyToApp_withResult(app, keyName, press_ms)
  local ms = (press_ms or KEY_TAP_MS)
  local kc = hs.keycodes.map[keyName]
  if not kc then return {down=false, up=false} end
  local okD = postKeycodeToApp(app, kc, true)
  hs.timer.usleep(ms * 1000)
  local okU = postKeycodeToApp(app, kc, false)
  return {down=okD, up=okU}
end
local function tapKeyGlobal_raw(keyOrCode, press_ms)
  local isNum = type(keyOrCode)=="number"
  local d = hs.eventtap.event.newKeyEvent({}, (isNum and keyOrCode or keyOrCode), true)
  local u = hs.eventtap.event.newKeyEvent({}, (isNum and keyOrCode or keyOrCode), false)
  if d then d:post() end
  hs.timer.usleep((press_ms or KEY_TAP_MS)*1000)
  if u then u:post() end
end

-- Z 控制
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

-- X 前喚醒
local function preWakeBeforeX(app)
  if not PRE_X_WAKE_ENABLED then return end
  if not app then return end
  for _, k in ipairs(PRE_X_WAKE_KEYS or {}) do
    tapKeyToApp_withResult(app, k, PRE_X_WAKE_TAP_MS)
    hs.timer.usleep((PRE_X_WAKE_GAP_MS or 40) * 1000)
  end
end

------------------------------------------------------------
-- 狀態
------------------------------------------------------------
local enabled=false
local uiTicker=nil
local flowRunning=false
local buffCasting=false

local holdTimer=nil
local afterHoldTimer=nil
local preAttackTimer=nil
local preAttackEndAt=nil
local holdEndAt=nil
local nextCycleAt=nil

-- 守門：防誤連擊
local lastKeySentAt = { }
local function guardTap(key, window_ms)
  local now = hs.timer.secondsSinceEpoch()
  local last = lastKeySentAt[key] or 0
  if (now - last) * 1000 < (window_ms or SAME_KEY_GUARD_MS) then return false end
  lastKeySentAt[key] = now
  return true
end

local function resetIdle(src) log("🔔 idle reset by:", src or "unknown") end
local function stopTimer(t) if t and t:running() then t:stop() end; return nil end

------------------------------------------------------------
-- 週期排程
------------------------------------------------------------
local function scheduleNextCycle(baseEpoch)
  local base = baseEpoch or hs.timer.secondsSinceEpoch()
  local e = randf(CYCLE_EARLY_JITTER_PCT_MIN, CYCLE_EARLY_JITTER_PCT_MAX)
  nextCycleAt = base + CYCLE_SEC * (1 - e)
  log(string.format("next cycle in %.1fs (early %.2f%%)", nextCycleAt - base, e*100))
end

------------------------------------------------------------
-- 倒數人性化
------------------------------------------------------------
local function tapKeyNTimesToApp(app, keyName, tap_ms, gap_ms, taps, onDone)
  local i=0
  local function go()
    i=i+1
    if i>taps then if onDone then onDone() end; return end
    tapKeyToApp_withResult(app, keyName, tap_ms)
    hs.timer.doAfter(gap_ms/1000, go)
  end
  go()
end

local function doHumanizeMoves(nextStep)
  if not HUMANIZE_ON_COUNTDOWN then nextStep(); return end
  local app = findTargetApp(); if not app then nextStep(); return end
  focusAppAndWait()
  local lr = HUMANIZE_LR_MODE
  if lr=="random" then lr = (math.random()<0.5) and "left" or "right" end
  tapKeyToApp_withResult(app, lr, HUMANIZE_TAP_MS)
  resetIdle("humanize-"..lr)
  hs.timer.doAfter(HUMANIZE_GAP_MS/1000, function()
    local taps = randi(HUMANIZE_DOWN_TAPS_MIN, HUMANIZE_DOWN_TAPS_MAX)
    tapKeyNTimesToApp(app, "down", HUMANIZE_TAP_MS, HUMANIZE_GAP_MS, taps, function()
      hs.timer.doAfter(HUMANIZE_TO_BUFF_DELAY_MS/1000, nextStep)
    end)
  end)
end

------------------------------------------------------------
-- 施放：1 → gap → 2(三段式)
------------------------------------------------------------
local function castSkillSequence_once()
  local app = findTargetApp()
  if not app then log("focus not confirmed; app not found"); return false end
  if REQUIRE_FRONTMOST and (not focusAppAndWait(FOCUS_WAIT_TIMEOUT_MS)) then
    log("focus not confirmed; abort casting (strict)"); return false
  end

  ensureUSKeyboard()
  if CAST_FOCUS_SETTLE_MS>0 then hs.timer.usleep(CAST_FOCUS_SETTLE_MS*1000) end
  local mw = app and app:mainWindow(); if mw then mw:focus() end

  -- 可選微移動
  if MOVE_STYLE == "dash" then
    hs.eventtap.keyStroke({"alt"}, "left", 0.03); hs.timer.usleep(DASH_GAP_MS*1000)
    hs.eventtap.keyStroke({"alt"}, "right", 0.03)
  elseif MOVE_STYLE == "tap" then
    local gap = randi(TAP_MIN_MS, TAP_MAX_MS)
    tapKeyToApp_withResult(app, "left", gap)
    hs.timer.usleep(gap*1000)
    tapKeyToApp_withResult(app, "right", gap)
  end

  -- 1（守門）
  if guardTap(SKILL1_KEY, SAME_KEY_GUARD_MS) then
    log("cast buff: skill1 (", SKILL1_KEY, ")")
    local r1 = tapKeyToApp_withResult(app, SKILL1_KEY, KEY_TAP_MS)
    if not (r1.down and r1.up) then
      log("skill1 direct-app failed; fallback global")
      tapKeyGlobal_raw(SKILL1_KEY, KEY_TAP_MS)
    end
  else
    log("guard: skip duplicate key 1")
  end

  -- 小沉靜
  hs.timer.usleep(90 * 1000)

  -- 刷焦點一下（方向鍵）
  tapKeyToApp_withResult(app, "right", 40)
  hs.timer.usleep(60 * 1000)

  -- 1→2 gap
  hs.timer.usleep(SKILL_CAST_GAP_MS * 1000)

  -- 2（三段式）
  log("cast buff: skill2 (", SKILL2_KEY, ") try#1(app)")
  local r2 = tapKeyToApp_withResult(app, SKILL2_KEY, KEY_TAP_MS)
  if not (r2.down and r2.up) then
    hs.timer.usleep(SKILL2_RETRY1_DELAY_MS * 1000)
    log("cast buff: skill2 (", SKILL2_KEY, ") try#2(app)")
    local r2b = tapKeyToApp_withResult(app, SKILL2_KEY, KEY_TAP_MS)
    if not (r2b.down and r2b.up) then
      hs.timer.usleep(SKILL2_RETRY2_DELAY_MS * 1000)
      log("cast buff: skill2 (", SKILL2_KEY, ") try#3(global)")
      tapKeyGlobal_raw(SKILL2_KEY, KEY_TAP_MS)
    end
  end
  return true
end

local function castSkillSequence(onDone)
  if buffCasting then log("buff casting already running; skip"); if onDone then onDone(false) end; return end
  buffCasting = true
  local ok = castSkillSequence_once()
  buffCasting = false
  if onDone then onDone(ok) end
end

------------------------------------------------------------
-- 攻擊段：Z 按住 → 放開 → X（一次，強化）
------------------------------------------------------------
local function sendX_once(app)
  -- X 前沉靜 + 喚醒鍵
  if POST_Z_TO_X_EXTRA_SETTLE_MS>0 then hs.timer.usleep(POST_Z_TO_X_EXTRA_SETTLE_MS*1000) end
  preWakeBeforeX(app)

  local mode = POST_ATTACK_X_MODE
  local function appTap()
    local okD = postKeycodeToApp(app, POST_ATTACK_KEYCODE, true)
    hs.timer.usleep(POST_ATTACK_PRESS_MS * 1000)
    local okU = postKeycodeToApp(app, POST_ATTACK_KEYCODE, false)
    return okD and okU
  end
  local function globalTap() tapKeyGlobal_raw(POST_ATTACK_KEYCODE, POST_ATTACK_PRESS_MS) end

  local appOK=false
  if mode=="app_first" then
    appOK = appTap()
    if not appOK then globalTap() end
  elseif mode=="global_first" then
    globalTap()
    hs.timer.usleep(50*1000)
    appOK = appTap()
  else -- "double"
    appOK = appTap()
    hs.timer.usleep(55*1000)
    globalTap()
  end
  log(string.format("post-attack X sent (app_ok=%s, mode=%s)", tostring(appOK), mode))
  return appOK
end

local function performAttackSegment(onDone)
  local app = findTargetApp(); if not app then if onDone then onDone() end; return end
  focusAppAndWait()

  local holdSec = (ATTACK_HOLD_MODE=="random") and randf(ATTACK_HOLD_MIN_SEC, ATTACK_HOLD_MAX_SEC) or ATTACK_HOLD_SEC
  holdEndAt = hs.timer.secondsSinceEpoch() + holdSec

  -- Z down
  keyDownApp(app, "z")
  resetIdle("attack-start(Z-down)")

  -- 放開 Z → 延遲 → 送 X（一次 + retry）
  holdTimer = stopTimer(holdTimer)
  holdTimer = hs.timer.doAfter(holdSec, function()
    keyUpApp(app, "z")
    log(string.format("Z hold finished (%.2fs)", holdSec))

    afterHoldTimer = stopTimer(afterHoldTimer)
    afterHoldTimer = hs.timer.doAfter(POST_Z_TO_X_DELAY_MS/1000, function()
      ensureUSKeyboard()

      if POST_ATTACK_KEY and guardTap(POST_ATTACK_KEY, POST_ATTACK_X_GUARD_MS) then
        local ok = sendX_once(app)
        -- 可選 retry（仍算「一次語義」，只是為確保落地）
        for i=1, (POST_ATTACK_X_RETRIES or 0) do
          if ok then break end
          hs.timer.usleep(POST_ATTACK_X_RETRY_GAP_MS*1000)
          ok = sendX_once(app)
        end
        resetIdle("post-attack-"..POST_ATTACK_KEY)
      else
        log("post-attack: skipped due to guard or key nil")
      end

      holdEndAt=nil
      if onDone then onDone() end
    end)
  end)
end

------------------------------------------------------------
-- 一輪流程
------------------------------------------------------------
local function runOneFullCycle()
  if flowRunning then log("full cycle already running; skip"); return end
  flowRunning = true

  local function startHumanizeThenCast()
    doHumanizeMoves(function()
      castSkillSequence(function(_ok)
        hs.timer.doAfter(POST_CAST_DELAY_SEC, function()
          performAttackSegment(function()
            scheduleNextCycle()
            flowRunning = false
            local now = hs.timer.secondsSinceEpoch()
            local rem = nextCycleAt and math.max(0, math.ceil(nextCycleAt - now)) or 0
            safeSetBar("下一輪 "..fmt_mmss(rem))
          end)
        end)
      end)
    end)
  end

  if PRE_ATTACK_COUNTDOWN_SEC > 0 then
    preAttackEndAt = hs.timer.secondsSinceEpoch() + PRE_ATTACK_COUNTDOWN_SEC
    preAttackTimer = stopTimer(preAttackTimer)
    preAttackTimer = hs.timer.new(COUNTDOWN_TICK_MS/1000, function()
      local now = hs.timer.secondsSinceEpoch()
      local remain = math.max(0, math.ceil((preAttackEndAt or now) - now))
      safeSetBar("開打倒數 "..fmt_mmss(remain))
      if remain <= 0 then
        preAttackTimer:stop(); preAttackTimer=nil; preAttackEndAt=nil
        startHumanizeThenCast()
      end
    end)
    preAttackTimer:start()
    safeSetBar("開打倒數 "..fmt_mmss(PRE_ATTACK_COUNTDOWN_SEC))
  else
    startHumanizeThenCast()
  end
end

------------------------------------------------------------
-- UI/狀態循環
------------------------------------------------------------
local function updateBar()
  local now = hs.timer.secondsSinceEpoch()
  if preAttackTimer and preAttackTimer:running() then return end
  local cycleRemain = nextCycleAt and math.max(0, math.ceil(nextCycleAt - now)) or nil
  if flowRunning and holdEndAt then
    safeSetBar(string.format("下一輪 %s | 攻擊中 %ss", cycleRemain and fmt_mmss(cycleRemain) or "--:--", math.max(0, math.ceil(holdEndAt - now))))
    return
  end
  if flowRunning then
    safeSetBar(string.format("下一輪 %s | 執行中", cycleRemain and fmt_mmss(cycleRemain) or "--:--"))
    return
  end
  if cycleRemain ~= nil then safeSetBar("下一輪 "..fmt_mmss(cycleRemain)) else safeSetBar("待機") end
end

local function uiTick()
  if not enabled then return end
  local now = hs.timer.secondsSinceEpoch()
  if nextCycleAt and (now >= nextCycleAt) and (not flowRunning) and (not buffCasting) then
    runOneFullCycle(); return
  end
  updateBar()
end

------------------------------------------------------------
-- 啟停/觸發 & menubar
------------------------------------------------------------
local function stopTimerSafe(t) if t and t:running() then t:stop() end end
local function stopAll()
  enabled=false
  stopTimerSafe(uiTicker); uiTicker=nil
  stopTimerSafe(preAttackTimer); preAttackTimer=nil
  stopTimerSafe(holdTimer); holdTimer=nil
  stopTimerSafe(afterHoldTimer); afterHoldTimer=nil
  preAttackEndAt=nil; holdEndAt=nil
  local app = findTargetApp(); if app then keyUpApp(app, "z") end
  buffCasting=false
  flowRunning=false
  safeSetBar("待機"); log("stopped")
end

local function startRun()
  if enabled then return end
  enabled=true
  runOneFullCycle()
  uiTicker=hs.timer.doEvery(UI_TICK_SEC, uiTick)
  log("enabled")
end

local function manualTriggerOnce() runOneFullCycle() end

ensureMenuBar()
local lastMenuClickAt=0
if menuBar then
  menuBar:setClickCallback(function()
    local now = hs.timer.secondsSinceEpoch()
    if now - lastMenuClickAt < MENU_CLICK_DEBOUNCE_SEC then return end
    lastMenuClickAt = now
    resetIdle("menubar-click")
    hs.timer.doAfter((MENU_CLICK_TO_ACTION_DELAY_MS/1000), function()
      if FOCUS_ON_MENU_CLICK then focusAppAndWait(FOCUS_WAIT_TIMEOUT_MS) end
      if ENABLE_MANUAL_TRIGGER_ON_CLICK then manualTriggerOnce() end
    end)
  end)
end

-- 只用來更新 idle 顯示
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

hs.hotkey.bind({"cmd","alt"}, "F10", function() if enabled then stopAll() else startRun() end end)
hs.hotkey.bind({"cmd","alt"}, "F8",  function() manualTriggerOnce() end)
hs.hotkey.bind({"cmd","alt"}, "F9",  function() stopAll() end)

-- 初始化
scheduleNextCycle()
safeSetBar("待機")
log("✔ 全自動魚屋（X 強化：數值keycode + 模式化冗餘 + 可調時序 + 喚醒鍵）loaded")

return mod