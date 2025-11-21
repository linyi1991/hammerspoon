-- ~/.hammerspoon/scripts/祈禱機-活7-全自動魚屋.lua
-- 流程：
--   啟動：先跑一次「完整流程（倒數→人性化→buff→攻擊→收尾移動）」。
--   之後：
--     - 每 FULL_CYCLE_SEC 秒：完整 buff + 攻擊。
--     - 每 ATTACK_ONLY_INTERVAL_SEC 秒：只跑攻擊段（不放 buff）（可開關）。
-- buff:
--   0：15 分鐘 buff，啟動時一定施放，之後每 14:55 補一次。
--   1/2/Q：依 ENABLE_SKILL? 開關控制。
--
-- 怪物偵測：
--   - 若 ENABLE_MONSTER_DETECT = true，攻擊段前會呼叫 Python + OpenCV 判斷畫面上是否有目標怪。
--   - 沒怪：當輪攻擊段直接略過，不按 Z/X、不走位。
--   - 有怪：照原本流程攻擊。

local mod = {}

------------------------------------------------------------
-- 🔧 參數區（全部集中這裡）
------------------------------------------------------------
local TARGET_APP_NAMES              = { "MapleStory Worlds", "MapleStory" }

-- 你實際裝 opencv-python 的 python3
local PYTHON_BIN                    = "/Users/theo/.pyenv/versions/3.11.9/bin/python3"

-- 是否啟用怪物影像偵測（搭配 Python）
local ENABLE_MONSTER_DETECT         = true

-- Python 偵測腳本與模板位置
local MONSTER_DETECT_SCRIPT         = "/Users/theo/data/github/artale/detect_multi_eye.py"
local MONSTER_TEMPLATE_PATH         = "/Users/theo/data/github/artale/monster_multi_eye_template.png"

-- 預設要截圖的區域（備援用；正常會用 window frame）
-- 螢幕 2056x1329，遊戲 1920x1080 放左下角，大致 y 往下偏一點
local MONSTER_CAPTURE_RECT          = { x = 0, y = 249, w = 1920, h = 1080 }

-- 聚焦/前景
local REQUIRE_FRONTMOST             = true
local FOCUS_ON_ACTION               = true
local FOCUS_ON_MENU_CLICK           = true
local FOCUS_WAIT_TIMEOUT_MS         = 900
local CAST_FOCUS_SETTLE_MS          = 400

-- 週期控制
local FULL_CYCLE_SEC                = 270   -- 每幾秒跑一次「完整流程：buff + 攻擊」
local ATTACK_ONLY_INTERVAL_SEC      = 180   -- 每幾秒跑一次「只攻擊段（不放 buff）」

-- 中途打怪（純攻擊輪）開關
local ENABLE_ATTACK_ONLY_CYCLE      = true  -- 想關掉中途打怪就設 false

-- 完整流程的內部 jitter（這裡設 0，讓它接近固定）
local CYCLE_EARLY_JITTER_PCT_MIN    = 0.0
local CYCLE_EARLY_JITTER_PCT_MAX    = 0.0

-- 倒數 & 人性化
local PRE_ATTACK_COUNTDOWN_SEC      = 2
local COUNTDOWN_TICK_MS             = 150
local HUMANIZE_ON_COUNTDOWN         = true  -- false/true
local HUMANIZE_LR_MODE              = "random"     -- random/left/right
local HUMANIZE_TAP_MS               = 60
local HUMANIZE_GAP_MS               = 90
local HUMANIZE_DOWN_TAPS_MIN        = 0     -- 關掉「下（down）」
local HUMANIZE_DOWN_TAPS_MAX        = 0
local HUMANIZE_TO_BUFF_DELAY_MS     = 160

-- Buff 0/1/2/Q：按鍵定義
local SKILL1_KEY                    = "1"
local SKILL2_KEY                    = "2"
local SKILL0_KEY                    = "0"          -- 15 分鐘大 buff
local SKILLQ_KEY                    = "q"          -- 跟 1/2 同週期 buff

-- Buff 啟用開關（想關掉某個 buff 就改成 false）
local ENABLE_SKILL0                 = false        -- 15 分鐘 buff（0）
local ENABLE_SKILL1                 = true
local ENABLE_SKILL2                 = true
local ENABLE_SKILLQ                 = false

local KEY_TAP_MS                    = 85    -- 一般按鍵時間
local SAME_KEY_GUARD_MS             = 260
local SKILL_CAST_GAP_MS             = 800

-- SKILL2 專用調整：避免 2 太快沒吃到
local SKILL2_TAP_MS                 = 200   -- 2 鍵按住時間（比一般鍵長）
local SKILL2_PRE_DELAY_MS           = 120   -- 在按 2 之前多等一點時間（毫秒）
local SKILL2_RETRY1_DELAY_MS        = 260   -- 第一次失敗後的延遲
local SKILL2_RETRY2_DELAY_MS        = 180   -- 第二次失敗後的延遲

-- 0 鍵 buff：實際為 15 分鐘，提前 5 秒重放（14:55）
local SKILL0_DURATION_SEC           = 15 * 60      -- 技能實際持續時間：900 秒
local SKILL0_RECAST_EARLY_SEC       = 5           -- 提前幾秒重放
local SKILL0_RECAST_THRESHOLD_SEC   = SKILL0_DURATION_SEC - SKILL0_RECAST_EARLY_SEC  -- 895 秒（14:55）

-- 攻擊段
local POST_CAST_DELAY_SEC           = 1.25
local ATTACK_HOLD_MODE              = "random"      -- fixed | random
local ATTACK_HOLD_SEC               = 15
local ATTACK_HOLD_MIN_SEC           = 16
local ATTACK_HOLD_MAX_SEC           = 18

-- 攻擊收尾後移動（左 → 右 → 左）
local END_MOVE_LEFT_SEC             = 1.2          -- 結束後往左走幾秒（0 = 不走）
local END_MOVE_RIGHT_SEC            = 2.1          -- 再往右走幾秒（0 = 不走）
local END_MOVE_LEFT2_SEC            = 1.6          -- 最後再往左走幾秒（0 = 不走）

-- ✅ 收尾 X：完全參數化 + 多路冗餘
--   X 的 macOS keycode = 7（避免輸入法/語系）
local POST_ATTACK_KEY               = "x"          -- 說明用途；實際送數值 keycode
local POST_ATTACK_KEYCODE           = 7            -- <== 主要用這個發送（down/up）
local POST_ATTACK_PRESS_MS          = 140          -- 建議 110~180；若沒觸發可再加
local POST_Z_TO_X_DELAY_MS          = 340          -- Z 放開後到送 X 的延遲
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
local function fmt_mmss(sec)
  sec = math.max(0, math.floor(sec or 0))
  return string.format("%d:%02d", math.floor(sec/60), sec%60)
end

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
-- 螢幕截圖 & 怪物偵測（呼叫 Python + OpenCV）
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

  -- 直接對遊戲視窗 snapshot，不吃整個螢幕
  local img = win:snapshot()
  if not img then
    log("monster capture: window snapshot failed")
    return false
  end

  img:saveToFile(outPath)
  log(string.format("monster capture: window snapshot saved, size=%dx%d",
    img:size().w, img:size().h))
  return true
end

local function detectMonster()
  if not ENABLE_MONSTER_DETECT then
    return true  -- 關掉偵測時，一律視為「可以攻擊」
  end

  local tmpPath = "/tmp/ham_monster_check.png"

  -- ✅ 改成只截 Maple 視窗
  local ok = captureWindowToFile(tmpPath)
  if not ok then
    log("monster detect: snapshot fail")
    return false
  end

  -- ✅ 帶 MONSTER_THRESH=0.36 給 Python（跟你 CLI 測試一致）
  local cmd = string.format(
    'MONSTER_THRESH=0.36 "%s" "%s" "%s" "%s"',
    PYTHON_BIN,
    MONSTER_DETECT_SCRIPT,
    tmpPath,
    MONSTER_TEMPLATE_PATH
  )

  log("[monster] run cmd=\t"..cmd)
  local out, success, _, rc = hs.execute(cmd, true)
  log("[monster] success=\t"..tostring(success).."\t rc=\t"..tostring(rc or "nil").."\t out=\t"..(out or ""))

  if not success then
    log("monster detect script failed, rc=", rc or "nil", " out=", out or "")
    return false
  end

  out = out or ""
  if out:find("FOUND") then
    log("monster detected by Python (FOUND)")
    return true
  else
    log("monster NOT_FOUND")
    return false
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

-- 完整流程下一次時間
local nextFullCycleAt=nil
-- 純攻擊段下一次時間
local nextAttackOnlyAt=nil

-- 0 鍵長 CD：紀錄上次施放時間（nil = 尚未施放，第一次一定會放）
local lastSkill0CastAt = nil

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
-- 0 鍵長 CD buff 判斷 & 施放
------------------------------------------------------------
local function maybeCastSkill0(app)
  if (not ENABLE_SKILL0) or (not SKILL0_KEY) then return end

  local now = hs.timer.secondsSinceEpoch()

  -- 第一次一定要放
  if lastSkill0CastAt ~= nil then
    -- 還沒到 14:55 就先不補
    local elapsed = now - lastSkill0CastAt
    if elapsed < SKILL0_RECAST_THRESHOLD_SEC then
      return
    end
  end

  if not guardTap(SKILL0_KEY, SAME_KEY_GUARD_MS) then
    log("guard: skip duplicate key 0")
    return
  end

  log(string.format("cast long buff: skill0 (%s), elapsed=%.1fs", SKILL0_KEY, lastSkill0CastAt and (now-lastSkill0CastAt) or -1))
  local r0 = tapKeyToApp_withResult(app, SKILL0_KEY, KEY_TAP_MS)
  if not (r0.down and r0.up) then
    log("skill0 direct-app failed; fallback global")
    tapKeyGlobal_raw(SKILL0_KEY, KEY_TAP_MS)
  end

  lastSkill0CastAt = now
end

------------------------------------------------------------
-- 完整流程排程
------------------------------------------------------------
local function scheduleNextFullCycle(baseEpoch)
  local base = baseEpoch or hs.timer.secondsSinceEpoch()
  local e = randf(CYCLE_EARLY_JITTER_PCT_MIN, CYCLE_EARLY_JITTER_PCT_MAX)
  nextFullCycleAt = base + FULL_CYCLE_SEC * (1 - e)
  log(string.format("next FULL cycle in %.1fs (early %.2f%%)", nextFullCycleAt - base, e*100))
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
-- 施放：0(視需要) → 1 → gap → 2(三段式) → Q
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
    hs.timer.usleep(40*1000)
    hs.eventtap.keyStroke({"alt"}, "right", 0.03)
  elseif MOVE_STYLE == "tap" then
    local gap = randi(TAP_MIN_MS, TAP_MAX_MS)
    tapKeyToApp_withResult(app, "left", gap)
    hs.timer.usleep(gap*1000)
    tapKeyToApp_withResult(app, "right", gap)
  end

  -- 0：長 CD buff
  maybeCastSkill0(app)

  -- 1
  if ENABLE_SKILL1 and SKILL1_KEY then
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
  else
    log("skill1 disabled or key nil")
  end

  -- 小沉靜
  hs.timer.usleep(90 * 1000)

  -- 刷焦點一下（方向鍵）
  tapKeyToApp_withResult(app, "right", 40)
  hs.timer.usleep(60 * 1000)

  -- 1→2 gap
  hs.timer.usleep(SKILL_CAST_GAP_MS * 1000)

  -- 2（三段式，加強版）
  if ENABLE_SKILL2 and SKILL2_KEY then
    if SKILL2_PRE_DELAY_MS and SKILL2_PRE_DELAY_MS > 0 then
      hs.timer.usleep(SKILL2_PRE_DELAY_MS * 1000)
    end

    log("cast buff: skill2 (", SKILL2_KEY, ") try#1(app)")
    local r2 = tapKeyToApp_withResult(app, SKILL2_KEY, SKILL2_TAP_MS)
    if not (r2.down and r2.up) then
      hs.timer.usleep(SKILL2_RETRY1_DELAY_MS * 1000)
      log("cast buff: skill2 (", SKILL2_KEY, ") try#2(app)")
      local r2b = tapKeyToApp_withResult(app, SKILL2_KEY, SKILL2_TAP_MS)
      if not (r2b.down and r2b.up) then
        hs.timer.usleep(SKILL2_RETRY2_DELAY_MS * 1000)
        log("cast buff: skill2 (", SKILL2_KEY, ") try#3(global)")
        tapKeyGlobal_raw(SKILL2_KEY, SKILL2_TAP_MS)
      end
    end
  else
    log("skill2 disabled or key nil")
  end

  -- Q
  if ENABLE_SKILLQ and SKILLQ_KEY then
    hs.timer.usleep(SKILL_CAST_GAP_MS * 1000)
    if guardTap(SKILLQ_KEY, SAME_KEY_GUARD_MS) then
      log("cast buff: skillQ (", SKILLQ_KEY, ")")
      local rq = tapKeyToApp_withResult(app, SKILLQ_KEY, KEY_TAP_MS)
      if not (rq.down and rq.up) then
        log("skillQ direct-app failed; fallback global")
        tapKeyGlobal_raw(SKILLQ_KEY, KEY_TAP_MS)
      end
    else
      log("guard: skip duplicate key Q")
    end
  else
    log("skillQ disabled or key nil")
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
-- 攻擊段：Z 按住 → 放開 → X → 收尾走位（左→右→左）
------------------------------------------------------------
local function sendX_once(app)
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

  --------------------------------------------------------
  -- ✅ 怪物偵測：沒怪就跳過這次攻擊段
  --------------------------------------------------------
  if ENABLE_MONSTER_DETECT then
    local hasMonster = detectMonster()
    if not hasMonster then
      log("performAttackSegment: no monster detected, skip this attack round")
      holdEndAt = nil
      if onDone then onDone() end
      return
    end
  end

  local holdSec = (ATTACK_HOLD_MODE=="random")
      and randf(ATTACK_HOLD_MIN_SEC, ATTACK_HOLD_MAX_SEC)
      or ATTACK_HOLD_SEC
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

      if POST_ATTACK_KEY and guardTap(POST_ATTACK_KEY, POST_ATTACK_X_GUARD_MS) then
        local ok = sendX_once(app)
        for i=1, (POST_ATTACK_X_RETRIES or 0) do
          if ok then break end
          hs.timer.usleep(POST_ATTACK_X_RETRY_GAP_MS*1000)
          ok = sendX_once(app)
        end
        resetIdle("post-attack-"..POST_ATTACK_KEY)
      else
        log("post-attack: skipped due to guard or key nil")
      end

      --------------------------------------------------------
      -- ✅ 收尾移動：左 → 右 → 左
      --------------------------------------------------------

      if END_MOVE_LEFT_SEC and END_MOVE_LEFT_SEC > 0 then
        log(string.format("end-move-left1: hold LEFT for %.2fs", END_MOVE_LEFT_SEC))
        keyDownApp(app, "left")
        hs.timer.usleep(END_MOVE_LEFT_SEC * 1000000)
        keyUpApp(app, "left")
      end

      if END_MOVE_RIGHT_SEC and END_MOVE_RIGHT_SEC > 0 then
        log(string.format("end-move-right: hold RIGHT for %.2fs", END_MOVE_RIGHT_SEC))
        keyDownApp(app, "right")
        hs.timer.usleep(END_MOVE_RIGHT_SEC * 1000000)
        keyUpApp(app, "right")
      end

      if END_MOVE_LEFT2_SEC and END_MOVE_LEFT2_SEC > 0 then
        log(string.format("end-move-left2: hold LEFT for %.2fs", END_MOVE_LEFT2_SEC))
        keyDownApp(app, "left")
        hs.timer.usleep(END_MOVE_LEFT2_SEC * 1000000)
        keyUpApp(app, "left")
      end

      holdEndAt=nil
      if onDone then onDone() end
    end)
  end)
end

------------------------------------------------------------
-- 一輪「完整流程」：倒數→人性化→buff→攻擊→收尾
------------------------------------------------------------
local function runOneFullCycle()
  if flowRunning then log("full cycle already running; skip"); return end
  flowRunning = true

  local function startHumanizeThenCast()
    doHumanizeMoves(function()
      castSkillSequence(function(_ok)
        hs.timer.doAfter(POST_CAST_DELAY_SEC, function()
          performAttackSegment(function()
            local now = hs.timer.secondsSinceEpoch()
            scheduleNextFullCycle(now)
            flowRunning = false
            local remFull = nextFullCycleAt and math.max(0, math.ceil(nextFullCycleAt - now)) or 0
            local remAtk  = nextAttackOnlyAt and math.max(0, math.ceil(nextAttackOnlyAt - now)) or 0
            safeSetBar(string.format("Buff輪 %s | 攻擊輪 %ss", fmt_mmss(remFull), remAtk))
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
-- 純攻擊輪：只跑攻擊段，不放 buff（可關閉）
------------------------------------------------------------
local function runAttackOnlyCycle()
  if not ENABLE_ATTACK_ONLY_CYCLE then
    log("attack-only cycle skipped (disabled)")
    return
  end

  if flowRunning then
    log("attack-only: flow already running; skip")
    return
  end
  flowRunning = true
  log("attack-only cycle start")

  performAttackSegment(function()
    local now = hs.timer.secondsSinceEpoch()
    if ENABLE_ATTACK_ONLY_CYCLE then
      nextAttackOnlyAt = now + ATTACK_ONLY_INTERVAL_SEC
    else
      nextAttackOnlyAt = nil
    end
    flowRunning = false
    local remFull = nextFullCycleAt and math.max(0, math.ceil(nextFullCycleAt - now)) or 0
    local remAtk  = nextAttackOnlyAt and math.max(0, math.ceil(nextAttackOnlyAt - now)) or 0
    safeSetBar(string.format("Buff輪 %s | 攻擊輪 %ss", fmt_mmss(remFull), remAtk))
  end)
end

------------------------------------------------------------
-- UI/狀態循環（新版：專注顯示怪物攻擊冷卻）
------------------------------------------------------------

-- lastMonsterAttackAt：你的主程式已有，不需重複宣告
-- MONSTER_ATTACK_COOLDOWN_SEC：你的冷卻秒數（如 300 秒）

local function updateBar()
  if not menubarIcon then return end

  local now = hs.timer.secondsSinceEpoch()
  local cd  = MONSTER_ATTACK_COOLDOWN_SEC or 300
  local text = ""

  if lastMonsterAttackAt == nil then
    -- 從未攻擊過
    text = "❌ never"
  else
    local diff = now - lastMonsterAttackAt
    if diff >= cd then
      -- 冷卻完成：顯示 ready + 經過秒數
      text = string.format("⏳ ready (%ds)", math.floor(diff))
    else
      -- 尚未冷卻：顯示剩餘秒數
      local remain = math.floor(cd - diff)
      text = string.format("⛔ cool: %ds", remain)
    end
  end

  menubarIcon:setTitle(text)
end

-- 這是 UI 每秒刷新
local function uiTick()
  if not enabled then return end

  -- Buff flow / 攻擊前預備期間維持顯示
  if flowRunning or buffCasting or (preAttackTimer and preAttackTimer:running()) then
    updateBar()
    return
  end

  -- 不再處理舊的 nextFullCycleAt / nextAttackOnlyAt
  -- 因為你現在是「看到怪 → 打一次」模型
  -- 所以 UI 僅更新顯示，不主動安排任何攻擊排程

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
  nextFullCycleAt=nil; nextAttackOnlyAt=nil
  local app = findTargetApp(); if app then keyUpApp(app, "z") end
  buffCasting=false
  flowRunning=false
  safeSetBar("待機"); log("stopped")
end

local function startRun()
  if enabled then return end
  enabled=true

  local now = hs.timer.secondsSinceEpoch()

  -- 啟動時：先跑一次完整流程
  runOneFullCycle()

  -- 接著排程中途攻擊輪（若啟用）
  if ENABLE_ATTACK_ONLY_CYCLE then
    nextAttackOnlyAt = now + ATTACK_ONLY_INTERVAL_SEC
  else
    nextAttackOnlyAt = nil
  end

  uiTicker=hs.timer.doEvery(UI_TICK_SEC, uiTick)
  log("enabled")
end

local function manualTriggerOnce()
  -- 手動點 menubar 或 F8：跑一次完整 buff + 攻擊
  runOneFullCycle()
end

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

-- 初始化（不預排任何輪，等 startRun 再排）
safeSetBar("待機")
log("✔ 全自動魚屋 loaded（啟動先完整一輪 → FULL_CYCLE buff 輪 → ATTACK_ONLY 可開關，含 0/1/2/Q buff 與怪物偵測）")

return mod