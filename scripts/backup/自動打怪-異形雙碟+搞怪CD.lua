-- ~/.hammerspoon/scripts/自動打怪-異形雙碟+搞怪CD.lua
-- 只做自動打怪：z 三連；異形雙碟 -> 1秒後衍生搞怪CD；被擊退會自動貼近
-- 需：Hammerspoon 0.9.100+，系統「輔助使用」權限

local mod = {}

-- ====== 可調參數 ======
local TARGET_APP_NAME    = "MapleStory"
local REQUIRE_FRONTMOST  = false          -- 只在前景才動作
local FOCUS_ON_CAST      = true           -- 出手前自動切回遊戲
local TICK_SEC           = 0.20           -- 迴圈頻率（秒）
local DEBUG              = true

-- 遊戲視窗位置（預設主螢幕左下角 1920x1080）；若不符，改成 "manual" 並填 MANUAL_RECT
local GAME_W, GAME_H     = 1920, 1080
local GAME_ANCHOR        = "bottom-left"  -- bottom-left / center / manual
local MANUAL_RECT        = {x=0, y=0, w=1920, h=1080}

-- 模板
local TEMPLATE_DIR = hs.fs.pathToAbsolute(os.getenv("HOME").."/.hammerspoon/monsters") or "~/.hammerspoon/monsters"
local YIXING_TEMPLATES   = {"yixing_head.png","yixing_half.png"}
local GAOGUAI_TEMPLATES  = {"gaoguai_head.png","gaoguai_half.png"}
local TOL_MONSTER        = 0.92           -- 模板匹配嚴格度（0~1；越大越嚴）

-- 近身/移動策略
local APPROACH = {
  centerBias = 0.06,   -- 視窗中心 ±6% 寬度內視為「已貼身」
  walkMs     = {40,70},
  shiftMs    = {60,90}, -- 瞬移後等待時間
  nearStep   = 2,       -- 貼身時短步次數
  farShift   = 2,       -- 距離大時瞬移次數
}

-- 巡邏（無怪）
local PATROL = {
  everySec = 1.8,       -- 巡邏頻率
  jitter   = {0, 0.4},  -- 額外抖動秒數
}

-- Z 連打（每輪三下）
local Z_BURST = {press=3, jitterMs={25,55}}

-- 「異形雙碟死亡 -> 1 秒後搞怪CD出現」處理
local SPLIT = { waitSec = 1.0, activeWindow = 1.8 } -- 等待1秒，之後 ~1.8秒優先就地掃怪

-- 掛機保護（保留你原邏輯：Z 實體按鍵或菜單點擊才重置）
local HUMAN_GRACE_SEC  = 5
local IDLE_TOTAL_SEC   = 295
local IDLE_WARN_LAST   = 30
local Z_KEY_CODE       = 6

-- ====== 工具 ======
local function log(...) if DEBUG then print("[autofight]", ...) end end
math.randomseed(os.time())
local function randf(a,b) return a + math.random()*(b-a) end
local function randi(a,b) return math.floor(a + math.random()*(b-a+1)) end
local function fmt_mmss(sec)
  sec = math.max(0, math.floor(sec or 0))
  local m = math.floor(sec/60); local s = sec%60
  return string.format("%d:%02d", m, s)
end

local function ensureMenuBar()
  if mod._bar then return end
  mod._bar = hs.menubar.new()
  if mod._bar then
    mod._bar:setTitle("待機")
    mod._bar:setTooltip("點一下重置掛機倒數（等效實體 Z）")
    mod._bar:setClickCallback(function()
      mod._resetIdle("menubar")
      hs.alert.show("⟳ 已重置掛機倒數", 0.6)
    end)
  end
end
local function setBar(s) ensureMenuBar(); if mod._bar then mod._bar:setTitle(s) end end

local function focusApp()
  if not FOCUS_ON_CAST then return end
  local app = hs.appfinder.appFromName(TARGET_APP_NAME)
  if app then app:activate(true) end
end

-- 掛機倒數（只接受實體 Z 或菜單點擊）
local lastHumanAt = hs.timer.secondsSinceEpoch()
function mod._resetIdle(src) lastHumanAt = hs.timer.secondsSinceEpoch(); log("idle reset:", src) end
hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(ev)
  local ar = ev:getProperty(hs.eventtap.event.properties.keyboardEventAutorepeat)
  if ar == 0 and ev:getKeyCode() == Z_KEY_CODE then mod._resetIdle("Z-key") end
  return false
end):start()

local function currentIdleRemain(now)
  local idleFor = now - lastHumanAt
  if idleFor < HUMAN_GRACE_SEC then return nil end
  local remain = IDLE_TOTAL_SEC - math.floor(idleFor - HUMAN_GRACE_SEC)
  return remain < 0 and 0 or remain
end

-- 視窗
local function gameRect()
  if GAME_ANCHOR == "manual" then
    return hs.geometry.rect(MANUAL_RECT.x, MANUAL_RECT.y, MANUAL_RECT.w, MANUAL_RECT.h)
  end
  local f = hs.screen.primaryScreen():frame()
  if GAME_ANCHOR == "bottom-left" then
    return hs.geometry.rect(f.x, f.y + f.h - GAME_H, GAME_W, GAME_H)
  elseif GAME_ANCHOR == "center" then
    return hs.geometry.rect(f.x + (f.w - GAME_W)/2, f.y + (f.h - GAME_H)/2, GAME_W, GAME_H)
  else
    return hs.geometry.rect(f.x, f.y + f.h - GAME_H, GAME_W, GAME_H)
  end
end

local function snapRegion(rect)
  return hs.screen.primaryScreen():snapshot(rect)
end

-- 模板
local function loadImg(name)
  local p = TEMPLATE_DIR.."/"..name
  local ok,img = pcall(hs.image.imageFromPath, p)
  if ok and img then return img end
  log("template load failed:", p); return nil
end

local cache = {yixing={}, gaoguai={}}
for _,n in ipairs(YIXING_TEMPLATES)  do cache.yixing[n]  = loadImg(n) end
for _,n in ipairs(GAOGUAI_TEMPLATES) do cache.gaoguai[n] = loadImg(n) end

local function findAny(imgBig, bag, tol)
  for name,tmpl in pairs(bag) do
    if tmpl then
      local ok, rect = pcall(hs.image.findTemplate, imgBig, tmpl, {tolerance=tol})
      if ok and rect then return true, rect end
    end
  end
  return false, nil
end

-- 輸入
local function tap(key) hs.eventtap.keyStroke({}, key); hs.timer.usleep(randi(25,55)*1000) end
local function combo(mods,key) hs.eventtap.keyStroke(mods, key); hs.timer.usleep(randi(40,80)*1000) end

-- 接近怪：根據怪在視窗中的 X 位置，決定靠左/靠右
local function approachTarget(rect, gRect)
  local gx = gRect.x; local gw = gRect.w
  local cx = rect.x + rect.w/2
  local rel = (cx - gx) / gw  -- 0..1

  local centerLo = 0.5 - APPROACH.centerBias
  local centerHi = 0.5 + APPROACH.centerBias

  if rel < centerLo then
    -- 在左側：距離大 -> 瞬移，距離小 -> 短步
    local far = (centerLo - rel) > 0.12
    if far then
      for i=1, APPROACH.farShift do combo({"alt"}, "left"); hs.timer.usleep(randi(APPROACH.shiftMs[1], APPROACH.shiftMs[2])*1000) end
    else
      for i=1, APPROACH.nearStep do hs.eventtap.keyDown({}, "left"); hs.timer.usleep(randi(APPROACH.walkMs[1], APPROACH.walkMs[2])*1000); hs.eventtap.keyUp({}, "left") end
    end
  elseif rel > centerHi then
    local far = (rel - centerHi) > 0.12
    if far then
      for i=1, APPROACH.farShift do combo({"alt"}, "right"); hs.timer.usleep(randi(APPROACH.shiftMs[1], APPROACH.shiftMs[2])*1000) end
    else
      for i=1, APPROACH.nearStep do hs.eventtap.keyDown({}, "right"); hs.timer.usleep(randi(APPROACH.walkMs[1], APPROACH.walkMs[2])*1000); hs.eventtap.keyUp({}, "right") end
    end
  else
    -- 已接近中心，微調一下增加貼身穩定性
    if math.random() < 0.5 then hs.eventtap.keyDown({}, "left"); hs.timer.usleep(randi(35,55)*1000); hs.eventtap.keyUp({}, "left")
    else hs.eventtap.keyDown({}, "right"); hs.timer.usleep(randi(35,55)*1000); hs.eventtap.keyUp({}, "right") end
  end
end

-- Z 三連
local function zBurst()
  focusApp()
  for i=1, Z_BURST.press do
    tap("z")
    hs.timer.usleep(randi(Z_BURST.jitterMs[1], Z_BURST.jitterMs[2])*1000)
  end
end

-- 狀態
local enabled, ticker = false, nil
local lastPatrolAt = 0
local lastYixingSeen = false
local lastYixingGoneAt = -1

local function patrol(now)
  if now - lastPatrolAt >= (PATROL.everySec + randf(PATROL.jitter[1], PATROL.jitter[2])) then
    if math.random() < 0.5 then combo({"alt"}, "left") else combo({"alt"}, "right") end
    lastPatrolAt = now
  end
end

-- 顯示列
local function updateBar(now, hasYixing, hasGaoguai)
  local idleRem = currentIdleRemain(now)
  local splitTxt = (lastYixingGoneAt>0 and (now-lastYixingGoneAt)<=SPLIT.activeWindow) and "分裂期" or ""
  local mtxt = (hasYixing and "異形✓" or "異形✗").."|"..(hasGaoguai and "搞怪✓" or "搞怪✗")
  local main = mtxt .. (splitTxt~="" and (" · "..splitTxt) or "")
  if idleRem then setBar(main.." | 掛機 "..fmt_mmss(idleRem)) else setBar(main) end
end

-- 主循環
local function tick()
  if not enabled then return end
  local now = hs.timer.secondsSinceEpoch()
  local gRect = gameRect()
  local img = snapRegion(gRect)
  local hasYixing, yRect = findAny(img, cache.yixing, TOL_MONSTER)
  local hasGaoguai, gRectMon = findAny(img, cache.gaoguai, TOL_MONSTER)

  -- 異形 -> 搞怪CD 的分裂偵測
  if lastYixingSeen and not hasYixing then
    lastYixingGoneAt = now
    log("yixing disappeared: mark split timing")
  end
  lastYixingSeen = hasYixing

  local inSplitWindow = (lastYixingGoneAt>0) and ((now - lastYixingGoneAt) >= SPLIT.waitSec) and ((now - lastYixingGoneAt) <= (SPLIT.waitSec + SPLIT.activeWindow))

  -- 有怪就貼近後打；分裂窗口也會原地積極掃怪
  if hasYixing then
    approachTarget(yRect, gRect)
    zBurst()
  elseif hasGaoguai or inSplitWindow then
    if hasGaoguai then
      approachTarget(gRectMon, gRect)
    end
    zBurst()
  else
    patrol(now)  -- 無怪巡邏
  end

  updateBar(now, hasYixing, hasGaoguai)
end

-- 啟停
local function startAfterCountdown()
  local function go(n)
    if n==0 then
      enabled = true
      if ticker then ticker:stop() end
      ticker = hs.timer.doEvery(TICK_SEC, tick)
      log("enabled"); setBar("啟動")
      return
    end
    setBar("啟動 "..tostring(n))
    hs.timer.doAfter(1, function() go(n-1) end)
  end
  go(3)
end
local function stopAll() enabled=false; if ticker then ticker:stop() end; ticker=nil; setBar("待機"); log("stopped") end

hs.hotkey.bind({"cmd","alt"}, "F10", function() if enabled then stopAll() else startAfterCountdown() end end)
hs.hotkey.bind({"cmd","alt"}, "F9",  function() stopAll() end)

-- 初始化
ensureMenuBar(); setBar("待機")
log("自動打怪腳本 loaded：z三連 / 目標貼近 / 異形->搞怪分裂處理 / Z實體鍵或菜單重置")
return mod