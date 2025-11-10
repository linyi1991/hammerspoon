-- ~/.hammerspoon/scripts/祈禱機-活7-全自動魚屋.lua
-- 單一 5 分鐘節拍（補施放與掛機合併）：
-- 倒數3秒 → 人性化（左右輕點 + 下鍵2~3次）→ 施放 1 →（間隔）→ 2（含兩次保底）→ 延遲 → Z 按住 → 放開 → 收尾 X → 補血 X×2 → 安排下一輪
-- 重點：
-- 1) 送鍵改用「keycode 直投到特定 App」，失敗才全域 fallback（避免被別視窗/IME 吃鍵）
-- 2) 施放「2」採三段式：try#1(app) → try#2(app) → try#3(global)，並先方向鍵刷新焦點
-- 3) menubar 倒數顯示防呆；點 menubar 會聚焦 Maple 後觸發完整一輪
-- 4) 嚴格前景（可調），聚焦成功會 focus mainWindow，以降低吞鍵

local mod = {}

------------------------------------------------------------
-- 🔧 參數（可依手感微調）
------------------------------------------------------------
local TARGET_APP_NAMES              = { "MapleStory Worlds", "MapleStory" }

-- 聚焦策略
local REQUIRE_FRONTMOST             = true     -- 嚴格要求 Maple 在前景才施放
local FOCUS_ON_ACTION               = true     -- 每段動作前自動帶前景
local FOCUS_ON_MENU_CLICK           = true     -- 點 menubar 也會帶前景
local FOCUS_WAIT_TIMEOUT_MS         = 900      -- 等待前景上位最長時間
local CAST_FOCUS_SETTLE_MS          = 400      -- 聚焦後沉靜，避免菜單/IME 截流

-- 5 分鐘整合節拍
local CYCLE_SEC                     = 290
local CYCLE_EARLY_JITTER_PCT_MIN    = 0.003
local CYCLE_EARLY_JITTER_PCT_MAX    = 0.010

-- 倒數 & 人性化
local PRE_ATTACK_COUNTDOWN_SEC      = 3
local COUNTDOWN_TICK_MS             = 150
local HUMANIZE_ON_COUNTDOWN         = true
local HUMANIZE_LR_MODE              = "random" -- random/left/right
local HUMANIZE_TAP_MS               = 60
local HUMANIZE_GAP_MS               = 90
local HUMANIZE_DOWN_TAPS_MIN        = 2
local HUMANIZE_DOWN_TAPS_MAX        = 3
local HUMANIZE_TO_BUFF_DELAY_MS     = 160

-- Buff 1 / 2（keycode 直投 + 反連擊守門）
local SKILL1_KEY                    = "1"
local SKILL2_KEY                    = "2"
local KEY_TAP_MS                    = 85
local SAME_KEY_GUARD_MS             = 260      -- 同鍵 guard 時窗（防誤連擊）
local SKILL_CAST_GAP_MS             = 800      -- 1→2 主要間隔（可 650~800ms）
local SKILL_RETRY_DELAY_MS          = 300      -- 整套重試延遲（目前不啟用第二輪整套重試）

-- 攻擊段
local POST_CAST_DELAY_SEC           = 1.25
local ATTACK_HOLD_MODE              = "fixed"  -- fixed | random
local ATTACK_HOLD_SEC               = 3
local ATTACK_HOLD_MIN_SEC           = 10
local ATTACK_HOLD_MAX_SEC           = 15

-- 收尾與補血
local POST_ATTACK_KEY               = "x"
local POST_ATTACK_PRESS_MS          = 60
local HEAL_AFTER_ATTACK_ENABLED     = true
local HEAL_KEY                      = "x"
local HEAL_TAPS                     = 2
local HEAL_TAP_MS                   = 90
local HEAL_GAP_MS                   = 120

-- 施放階段微移動（預設關避免小跳）
local MOVE_STYLE                    = "none"   -- none | dash | tap
local DASH_GAP_MS                   = 120
local TAP_MIN_MS                    = 80
local TAP_MAX_MS                    = 80

-- UI / menubar / 熱鍵
local ENABLE_MANUAL_TRIGGER_ON_CLICK= true
local MENU_CLICK_DEBOUNCE_SEC       = 0.4
local MENU_CLICK_TO_ACTION_DELAY_MS = 250
local UI_TICK_SEC                   = 0.5

-- Debug
local DEBUG = true
local function log(...) if DEBUG then print("[skillbot]", ...) end end

------------------------------------------------------------
-- 🧰 工具
------------------------------------------------------------
math.randomseed(os.time())
local function randf(a,b) return a + math.random()*(b-a) end
local function randi(a,b) return math.floor(a + math.random()*(b-a+1)) end
local function fmt_mmss(sec) sec=math.max(0,math.floor(sec or 0)); return string.format("%d:%02d",math.floor(sec/60),sec%60) end

-- 安全 UI 顯示（避免 timer 回呼報錯）
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

-- 切英文鍵盤（避免 IME 吃鍵）
local function ensureUSKeyboard()
  local ok = hs.keycodes.setLayout("U.S.")
  if not ok then hs.keycodes.setLayout("ABC") end
end

-- 目標名稱判斷（精確或含 maplestory）
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

-- 嚴格聚焦 + 確認前景（含主視窗 focus）
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

-- 以 keycode 直投（回傳是否成功直投到 app）
local function postKeycodeToApp(app, keycode, isDown)
  local ev = hs.eventtap.event.newKeyEvent({}, keycode, isDown)
  if not ev then return false end
  local ok = pcall(function() ev:post(app) end)
  return ok
end

-- tap 單鍵到 app：先 app（回傳 {down,up}），失敗由呼叫端決定是否 fallback
local function tapKeyToApp_withResult(app, keyName, press_ms)
  local ms = (press_ms or KEY_TAP_MS)
  local kc = hs.keycodes.map[keyName]  -- keycode 直投更穩
  if not kc then return {down=false, up=false} end
  local okDown = postKeycodeToApp(app, kc, true)
  hs.timer.usleep(ms * 1000)
  local okUp   = postKeycodeToApp(app, kc, false)
  return {down=okDown, up=okUp}
end

-- 全域 fallback（最後保命）
local function tapKeyGlobal(keyName, press_ms)
  hs.eventtap.keyStroke({}, keyName, (press_ms or KEY_TAP_MS)/1000.0)
end

-- Z 專用：按下/放開（app 直投，失敗則全域）
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

------------------------------------------------------------
-- 📊 狀態
------------------------------------------------------------
local enabled=false
local uiTicker=nil

local flowRunning=false       -- 一輪鎖（防重入）
local buffCasting=false       -- Buff 鎖
local buffRetryTimer=nil

local holdTimer=nil
local afterHoldTimer=nil
local preAttackTimer=nil
local preAttackEndAt=nil
local holdEndAt=nil
local nextCycleAt=nil
local lastMenuClickAt=0

-- 反連擊守門（同鍵近時間隔不再送）
local lastKeySentAt = { }     -- key -> epoch
local function guardTap(key, window_ms)
  local now = hs.timer.secondsSinceEpoch()
  local last = lastKeySentAt[key] or 0
  if (now - last) * 1000 < (window_ms or SAME_KEY_GUARD_MS) then
    return false
  end
  lastKeySentAt[key] = now
  return true
end

local lastHumanAt = hs.timer.secondsSinceEpoch()
local function resetIdle(src) lastHumanAt = hs.timer.secondsSinceEpoch(); log("🔔 idle reset by:", src or "unknown") end
local function stopTimer(t) if t and t:running() then t:stop() end; return nil end

------------------------------------------------------------
-- 📅 週期排程
------------------------------------------------------------
local function scheduleNextCycle(baseEpoch)
  local base = baseEpoch or hs.timer.secondsSinceEpoch()
  local e = randf(CYCLE_EARLY_JITTER_PCT_MIN, CYCLE_EARLY_JITTER_PCT_MAX)
  nextCycleAt = base + CYCLE_SEC * (1 - e)
  log(string.format("next cycle in %.1fs (early %.2f%%)", nextCycleAt - base, e*100))
end

------------------------------------------------------------
-- 👣 人性化（倒數期間）
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
-- 🧍 施放階段微移動（可關）
------------------------------------------------------------
local function maybeDoMoveStyle(app)
  if MOVE_STYLE == "dash" then
    hs.eventtap.keyStroke({"alt"}, "left", 0.03); hs.timer.usleep(DASH_GAP_MS*1000)
    hs.eventtap.keyStroke({"alt"}, "right", 0.03)
  elseif MOVE_STYLE == "tap" then
    local gap = randi(TAP_MIN_MS, TAP_MAX_MS)
    tapKeyToApp_withResult(app, "left", gap); hs.timer.usleep(gap*1000); tapKeyToApp_withResult(app, "right", gap)
  end
end

------------------------------------------------------------
-- ✨ Buff 施放：1 →（間隔）→ 2（app/app/global）
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

  maybeDoMoveStyle(app)

  -- 送 1（受守門保護）
  if guardTap(SKILL1_KEY, SAME_KEY_GUARD_MS) then
    log("cast buff: skill1 (", SKILL1_KEY, ")")
    local r1 = tapKeyToApp_withResult(app, SKILL1_KEY, KEY_TAP_MS)
    if not (r1.down and r1.up) then
      log("skill1 direct-app failed; fallback global")
      tapKeyGlobal(SKILL1_KEY, KEY_TAP_MS)
    end
  else
    log("guard: skip duplicate key 1")
  end

  -- 極短穩定，避免被視長按
  hs.timer.usleep(90 * 1000)

  -- 刷新焦點（方向鍵輕點）
  tapKeyToApp_withResult(app, "right", 40)
  hs.timer.usleep(60 * 1000)

  -- 主要間隔（1→2）
  hs.timer.usleep(SKILL_CAST_GAP_MS * 1000)

  -- 送 2：三段式（不經守門，避免重試被擋）
  log("cast buff: skill2 (", SKILL2_KEY, ") try#1(app)")
  local r2 = tapKeyToApp_withResult(app, SKILL2_KEY, KEY_TAP_MS)

  if not (r2.down and r2.up) then
    hs.timer.usleep(180 * 1000)
    log("cast buff: skill2 (", SKILL2_KEY, ") try#2(app)")
    local r2b = tapKeyToApp_withResult(app, SKILL2_KEY, KEY_TAP_MS)
    if not (r2b.down and r2b.up) then
      hs.timer.usleep(100 * 1000)
      log("cast buff: skill2 (", SKILL2_KEY, ") try#3(global)")
      tapKeyGlobal(SKILL2_KEY, KEY_TAP_MS)
    end
  end

  return true
end

local function castSkillSequence(onDone)
  if buffCasting then log("buff casting already running; skip"); return end
  buffCasting = true
  local ok = castSkillSequence_once()
  buffCasting = false
  if onDone then onDone(ok) end
end

------------------------------------------------------------
-- ⚔️ 攻擊段（Z 按住 → 放開 → X → 補血 X×2）
------------------------------------------------------------
local holdTimer=nil
local afterHoldTimer=nil

local function performAttackSegment(onDone)
  local app = findTargetApp(); if not app then if onDone then onDone() end; return end
  focusAppAndWait()

  local holdSec = (ATTACK_HOLD_MODE=="random") and randf(ATTACK_HOLD_MIN_SEC, ATTACK_HOLD_MAX_SEC) or ATTACK_HOLD_SEC
  holdEndAt = hs.timer.secondsSinceEpoch() + holdSec

  keyDownApp(app, "z")
  resetIdle("attack-start(Z-down)")

  holdTimer = stopTimer(holdTimer)
  holdTimer = hs.timer.doAfter(holdSec, function()
    keyUpApp(app, "z")
    log(string.format("Z hold finished (%.2fs)", holdSec))

    afterHoldTimer = stopTimer(afterHoldTimer)
    afterHoldTimer = hs.timer.doAfter(0.08, function()
      if POST_ATTACK_KEY then tapKeyToApp_withResult(app, POST_ATTACK_KEY, POST_ATTACK_PRESS_MS); resetIdle("post-attack-"..POST_ATTACK_KEY) end
      local function finish()
        holdEndAt=nil
        if onDone then onDone() end
      end
      if HEAL_AFTER_ATTACK_ENABLED then
        tapKeyNTimesToApp(app, HEAL_KEY, HEAL_TAP_MS, HEAL_GAP_MS, HEAL_TAPS, finish)
      else
        finish()
      end
    end)
  end)
end

------------------------------------------------------------
-- ▶️ 一輪完整流程
------------------------------------------------------------
local preAttackTimer=nil
local preAttackEndAt=nil
local flowRunning=false

local function runOneFullCycle()
  if flowRunning then log("full cycle already running; skip"); return end
  flowRunning = true

  local function startHumanizeThenCast()
    doHumanizeMoves(function()
      castSkillSequence(function(_ok)
        -- 若想「Buff 失敗就不攻擊」→ 取消下一行註解並 return
        -- if not _ok then flowRunning=false; scheduleNextCycle(); safeSetBar("待機"); return end

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
  else
    startHumanizeThenCast()
  end

  safeSetBar("開打倒數 "..fmt_mmss(PRE_ATTACK_COUNTDOWN_SEC))
end

------------------------------------------------------------
-- ♻️ UI/狀態循環
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
-- ⏯️ 啟停 / 觸發
------------------------------------------------------------
local function stopAll()
  enabled=false
  uiTicker=stopTimer(uiTicker)
  preAttackTimer=stopTimer(preAttackTimer)
  holdTimer=stopTimer(holdTimer)
  afterHoldTimer=stopTimer(afterHoldTimer)
  buffRetryTimer=stopTimer(buffRetryTimer)
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
  uiTicker=stopTimer(uiTicker)
  uiTicker=hs.timer.doEvery(UI_TICK_SEC, uiTick)
  log("enabled")
end

local function manualTriggerOnce()
  runOneFullCycle()
end

------------------------------------------------------------
-- 🖱️ Menubar 點擊（等菜單收回 → 聚焦 → 觸發）
------------------------------------------------------------
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

------------------------------------------------------------
-- ⌨️ Z key 監聽（僅 reset 顯示）
------------------------------------------------------------
local Z_KEY_CODE = 6
local keyboardWatcher = hs.eventtap.new(
  { hs.eventtap.event.types.keyDown },
  function(ev)
    local ar = ev:getProperty(hs.eventtap.event.properties.keyboardEventAutorepeat)
    local kc = ev:getKeyCode()
    if ar == 0 and kc == Z_KEY_CODE then resetIdle("Z-key") end
    return false
  end
)
keyboardWatcher:start()
log("keyboardWatcher started – only keyCode "..Z_KEY_CODE.." resets idle display")

------------------------------------------------------------
-- 🔥 熱鍵
------------------------------------------------------------
hs.hotkey.bind({"cmd","alt"}, "F10", function() if enabled then stopAll() else startRun() end end)
hs.hotkey.bind({"cmd","alt"}, "F8",  function() manualTriggerOnce() end)
hs.hotkey.bind({"cmd","alt"}, "F9",  function() stopAll() end)

-- 初始化
local function scheduleNextCycle(baseEpoch)
  local base = baseEpoch or hs.timer.secondsSinceEpoch()
  local e = randf(CYCLE_EARLY_JITTER_PCT_MIN, CYCLE_EARLY_JITTER_PCT_MAX)
  nextCycleAt = base + CYCLE_SEC * (1 - e)
  log(string.format("next cycle in %.1fs (early %.2f%%)", nextCycleAt - base, e*100))
end
scheduleNextCycle()
safeSetBar("待機")
log("✔ 全自動魚屋（keycode直投 + 倒數防呆 + 2三段式保底）loaded")

return mod