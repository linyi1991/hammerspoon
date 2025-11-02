-- ~/.hammerspoon/scripts/祈禱機-活7-施放被動技能.lua
-- keyCode 判定版 + menubar 點擊重置：僅當 keyCode == 6（Z 鍵）或點擊 menubar 時才重置掛機；含調試 log

local mod = {}

-- === 可調參數 ===
local TARGET_APP_NAME   = "MapleStory"
local REQUIRE_FRONTMOST = false
local FOCUS_ON_CAST     = true
local TICK_SEC          = 0.5

local SKILLS = {
  { name="skill1", key="1", duration=300 },
  { name="skill2", key="2", duration=300 },
}

local EARLY_PCT_MIN, EARLY_PCT_MAX = 0.05, 0.10
local HUMAN_GRACE_SEC     = 5    -- 無 Z 鍵（或 menubar 點擊）操作 10 秒後才開始計入掛機倒數
local IDLE_TOTAL_SEC      = 295
local IDLE_WARN_LAST      = 30

local DEBUG = true
local function log(...) if DEBUG then print("[skillbot]", ...) end end

-- === 工具函式 ===
math.randomseed(os.time())
local function randf(a,b) return a + math.random()*(b-a) end
local function randi(a,b) return math.floor(a + math.random()*(b-a+1)) end
local function fmt_mmss(sec)
  sec = math.max(0, math.floor(sec or 0))
  local m = math.floor(sec / 60)
  local s = sec % 60
  return string.format("%d:%02d", m, s)
end

-- === Menu Bar ===
local menuBar = nil
local function ensureMenuBar()
  if not menuBar then
    menuBar = hs.menubar.new()
    if menuBar then
      menuBar:setTitle("待機")
      menuBar:setTooltip("點一下可重置掛機倒數（等效 Z）")
    end
  end
end
local function setBar(text)
  ensureMenuBar()
  if menuBar then menuBar:setTitle(text) end
end

-- === 前景切換 ===
local function focusApp()
  if not FOCUS_ON_CAST then return end
  local app = hs.appfinder.appFromName(TARGET_APP_NAME)
  if app then app:activate(true) end
end

-- === 鍵盤事件監聽（僅指定 keyCode）===
local lastHumanAt = hs.timer.secondsSinceEpoch()
local Z_KEY_CODE = 6  -- Z 鍵（美式鍵盤）的 keyCode，若不同可用 EventViewer 觀察

local function resetIdle(source)
  lastHumanAt = hs.timer.secondsSinceEpoch()
  log("🔔 idle reset by:", source or "unknown", "at", lastHumanAt)
end

-- menubar 點擊 → 手動重置 idle（等同於按 Z）
local function enableMenuClickReset()
  ensureMenuBar()
  if menuBar then
    menuBar:setClickCallback(function()
      resetIdle("menubar-click")
      hs.alert.show("⟳ 掛機倒數已重置", 0.8)
      -- 點一下也順便更新一次顯示
      local now = hs.timer.secondsSinceEpoch()
      local remain = IDLE_TOTAL_SEC
      setBar(("補施 --:-- | 掛機 %s"):format(fmt_mmss(remain)))
    end)
  end
end

local keyboardWatcher = hs.eventtap.new(
  { hs.eventtap.event.types.keyDown },
  function(ev)
    local ar = ev:getProperty(hs.eventtap.event.properties.keyboardEventAutorepeat)
    local kc = ev:getKeyCode()
    local flags = ev:getFlags()
    log("key event (watcher): keyCode =", kc, "flags =", flags, "autorepeat =", ar)
    if ar == 0 and kc == Z_KEY_CODE then
      resetIdle("Z-key")
    end
    return false
  end
)
keyboardWatcher:start()
log("keyboardWatcher started – only keyCode "..Z_KEY_CODE.." (Z) resets idle")

-- === 掛機倒數計算 ===
local function currentIdleRemain(now)
  local idleFor = now - lastHumanAt
  if idleFor < HUMAN_GRACE_SEC then
    return nil
  end
  local remain = IDLE_TOTAL_SEC - math.floor(idleFor - HUMAN_GRACE_SEC)
  if remain < 0 then remain = 0 end
  return remain
end

-- === 技能施放邏輯 ===
local function rawKeyPress(keyChar)
  hs.eventtap.keyStroke({}, keyChar)
  hs.timer.usleep(randi(150,200)*1000)
end

local function castOne(skill)
  if REQUIRE_FRONTMOST then
    local fw = hs.window.frontmostWindow()
    local app = fw and fw:application()
    if not (app and app:name() == TARGET_APP_NAME) then
      return false
    end
  end
  focusApp()
  hs.timer.usleep(randf(1.2,1.2*(1+0.2))*1e6)
  rawKeyPress("up")
  hs.timer.usleep(randf(2.0,2.0*(1+0.2))*1e6)
  hs.eventtap.keyStroke({"alt"}, "left")
  hs.timer.usleep(60*1000)
  hs.eventtap.keyStroke({"alt"}, "right")
  rawKeyPress("left")
  hs.timer.usleep(randf(0.05,0.10)*1e6)
  rawKeyPress("right")
  rawKeyPress(skill.key)
  hs.timer.usleep(randi(30,80)*1000)
  rawKeyPress(skill.key)
  log("cast:", skill.name, "key", skill.key)
  return true
end

-- === 調度狀態 ===
local enabled, ticker = false, nil
local state = {}

local function scheduleNext(skill, baseEpoch)
  local e = randf(EARLY_PCT_MIN, EARLY_PCT_MAX)
  local due = baseEpoch + skill.duration * (1 - e)
  state[skill.name] = { nextDue = due }
  log(string.format("next %s in %.1fs (early %.1f%%)", skill.name, due - baseEpoch, e*100))
end

local function nearestRemaining()
  local now = hs.timer.secondsSinceEpoch()
  local best = nil
  for _, sk in ipairs(SKILLS) do
    local st = state[sk.name]
    if st and st.nextDue then
      local remain = math.max(0, math.floor(st.nextDue - now))
      best = (best == nil) and remain or math.min(best, remain)
    end
  end
  return best
end

local lastWarnShown = -1
local function updateBarDuringRun()
  local now = hs.timer.secondsSinceEpoch()
  local buffR = nearestRemaining()
  local buffTxt = (buffR ~= nil) and fmt_mmss(buffR) or "--:--"
  local idleRem = currentIdleRemain(now)
  if idleRem ~= nil then
    setBar(("補施 %s | 掛機 %s"):format(buffTxt, fmt_mmss(idleRem)))
    if idleRem <= IDLE_WARN_LAST and idleRem ~= lastWarnShown then
      lastWarnShown = idleRem
      -- 可選警告：
      -- hs.alert.show("掛機剩餘 "..idleRem.." 秒", 1.0)
    end
  else
    setBar("補施 " .. buffTxt)
  end
end

local function tick()
  if not enabled then return end
  local now = hs.timer.secondsSinceEpoch()
  for _, sk in ipairs(SKILLS) do
    local st = state[sk.name]
    if not st or not st.nextDue then
      scheduleNext(sk, now)
    elseif now >= st.nextDue then
      if castOne(sk) then
        scheduleNext(sk, now)
      else
        state[sk.name].nextDue = now + 2
      end
    end
  end
  updateBarDuringRun()
end

-- === 啟動／停止邏輯 ===
local function castBothNow()
  local now = hs.timer.secondsSinceEpoch()
  for _, sk in ipairs(SKILLS) do
    if castOne(sk) then scheduleNext(sk, now) end
  end
  resetIdle("castBothNow")
  updateBarDuringRun()
end

local function startAfterCountdown()
  local function go(n)
    if n == 0 then
      enabled = true
      castBothNow()
      if ticker then ticker:stop() end
      ticker = hs.timer.doEvery(TICK_SEC, tick)
      log("enabled")
      return
    end
    setBar("啟動 " .. tostring(n))
    hs.timer.doAfter(1, function() go(n-1) end)
  end
  go(3)
end

local function stopAll()
  enabled = false
  if ticker then ticker:stop() end
  ticker = nil
  setBar("待機")
  log("stopped")
end

-- === 熱鍵設定 ===
hs.hotkey.bind({"cmd","alt"}, "F10", function()
  if enabled then stopAll() else startAfterCountdown() end
end)
hs.hotkey.bind({"cmd","alt"}, "F8", function() castBothNow() end)
hs.hotkey.bind({"cmd","alt"}, "F9", function() stopAll() end)

-- === 初始化 ===
setBar("待機")
enableMenuClickReset()  -- ✅ 點擊 menu bar → 重置掛機倒數（等效 Z）
log("✔ keyCode 判定版 loaded – 只用 Z keyCode ("..Z_KEY_CODE..")／10 秒掛機 + menubar 點擊重置")

return mod