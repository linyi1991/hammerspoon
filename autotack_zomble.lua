-- ~/.hammerspoon/autotack_zomble.lua
-- 死亡森林2 殭屍：相對視窗 + 血條偵測 + 可拖曳/可縮放 ROI
-- F6 開/關、F7 停止、F9 校色報告、F10 顯示/隱藏 ROI、F11 編輯模式、F12 輸出 ROI 百分比

local M = {}

-- ===== 基本設定 =====
local APP_NAME_SUBSTR = "Maple"   -- 遊戲 App 名稱包含字串
local ATTACK_KEY           = "z"
local ATTACK_PRESS_MS      = 40
local ATTACK_INTERVAL_MS   = 150
local TP_PRESS_MS          = 38
local TP_COOLDOWN_MS       = 60
local FOCUS_CHECK_MS       = 300

-- 去抖
local ENTER_DETECT_FRAMES  = 2
local LEAVE_DETECT_FRAMES  = 6

-- 巡邏策略
local H_SWEEP_STEPS        = 4
local V_SWEEP_EVERY_ROUNDS = 3
local V_SWEEP_STEPS        = 1

-- 方向鍵（若是數字鍵區請改 pad4/pad6/pad8/pad2）
local KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN = "left","right","up","down"

-- ===== ROI（相對視窗百分比；可在編輯模式中調整） =====
local ROI_REL_LEFT  = { x=0.28, y=0.30, w=0.16, h=0.045 }
local ROI_REL_RIGHT = { x=0.56, y=0.30, w=0.16, h=0.045 }

-- ===== 血條顏色門檻 =====
local GREEN_MIN           = 0.35
local GREEN_DOMINANCE_K   = 1.30
local SAT_MIN             = 0.25
local MIN_RUN_PIXELS      = 28
local SAMPLE_LINES        = 3

-- ===== 工具 =====
local function sleep(ms) hs.timer.usleep(ms*1000) end
local function frontApp() return hs.application.frontmostApplication() end
local function frontIsGame()
  local app = frontApp()
  return app and app:name() and app:name():find(APP_NAME_SUBSTR) ~= nil
end
local function gameWindow()
  local app = frontApp()
  if not app then return nil end
  local win = app:focusedWindow() or hs.window.frontmostWindow()
  if not win or not frontIsGame() then return nil end
  return win
end

local function keyDown(mods, key) hs.eventtap.event.newKeyEvent(mods or {}, key, true):post() end
local function keyUp(mods, key)   hs.eventtap.event.newKeyEvent(mods or {}, key, false):post() end
local function releaseAllModifiers()
  for _, m in ipairs({"shift","ctrl","alt","cmd","fn"}) do
    hs.eventtap.event.newKeyEvent({m}, true):setType(hs.eventtap.event.types.flagsChanged):post()
    hs.eventtap.event.newKeyEvent({m}, false):setType(hs.eventtap.event.types.flagsChanged):post()
  end
end
local function attackZ(pressMs)
  releaseAllModifiers()
  keyDown({}, ATTACK_KEY)
  sleep(pressMs or ATTACK_PRESS_MS)
  keyUp({}, ATTACK_KEY)
end
local function teleport(dirKey, pressMs, cooldownMs)
  keyDown({"shift"}, dirKey)
  sleep(pressMs or TP_PRESS_MS)
  keyUp({"shift"}, dirKey)
  sleep(cooldownMs or TP_COOLDOWN_MS)
end

-- 百分比 <-> 視窗絕對座標
local function relToAbs(winFrame, rel)
  return {
    x = math.floor(winFrame.x + rel.x * winFrame.w),
    y = math.floor(winFrame.y + rel.y * winFrame.h),
    w = math.max(1, math.floor(rel.w * winFrame.w)),
    h = math.max(1, math.floor(rel.h * winFrame.h)),
  }
end
local function absToRel(winFrame, abs)
  return {
    x = (abs.x - winFrame.x) / winFrame.w,
    y = (abs.y - winFrame.y) / winFrame.h,
    w = abs.w / winFrame.w,
    h = abs.h / winFrame.h,
  }
end

-- 取樣影像（在視窗所在螢幕）
local function snapshotOnWindowScreen(win, rectAbs)
  local scr = win:screen()
  if not scr then return nil end
  return scr:snapshot(hs.geometry.rect(rectAbs.x, rectAbs.y, rectAbs.w, rectAbs.h))
end

-- 飽和度近似
local function approxSat(r,g,b)
  local M=math.max(r,g,b); local m=math.min(r,g,b)
  if M==0 then return 0 end
  return 1 - (m/M)
end
local function isGreenHP(r,g,b)
  if g < GREEN_MIN then return false end
  if g < GREEN_DOMINANCE_K * math.max(r,b) then return false end
  if approxSat(r,g,b) < SAT_MIN then return false end
  return true
end

-- ROI 內是否存在「連續綠色像素」（血條）
local function hasHPBar(win, relROI)
  local frame = win:frame()
  local rect  = relToAbs(frame, relROI)
  local img   = snapshotOnWindowScreen(win, rect)
  if not img then return false end

  local w,h = img:size().w, img:size().h
  if w < MIN_RUN_PIXELS or h < 2 then return false end

  for li = 1, SAMPLE_LINES do
    local y = math.floor((li) * (h / (SAMPLE_LINES + 1)))
    local run = 0
    for x = 0, w-1 do
      local c = img:colorAt({x=x, y=y})
      if c then
        local r,g,b = c.red,c.green,c.blue
        if isGreenHP(r,g,b) then
          run = run + 1
          if run >= MIN_RUN_PIXELS then return true end
        else
          run = 0
        end
      end
    end
  end
  return false
end

-- ===== 疊圖與編輯模式 =====
local overlayRects, overlayOn = {}, false
local editMode, currentTarget = false, "LEFT"  -- "LEFT" 或 "RIGHT"
local dragSession = { active=false, startMouse=nil, startRect=nil, resize=false }

local function clearOverlay()
  for _,d in ipairs(overlayRects) do d:delete() end
  overlayRects = {}
end
local function drawOverlay(win)
  clearOverlay()
  if not overlayOn or not win then return end
  local f = win:frame()
  local rL = relToAbs(f, ROI_REL_LEFT)
  local rR = relToAbs(f, ROI_REL_RIGHT)
  local function rectDraw(r, color, selected)
    local d = hs.drawing.rectangle(hs.geometry.rect(r.x, r.y, r.w, r.h))
    d:setStrokeColor(color):setFill(false):setStrokeWidth(selected and 4 or 2):setAlpha(0.95)
    d:bringToFront(true):show()
    table.insert(overlayRects, d)
  end
  rectDraw(rL, currentTarget=="LEFT"  and {red=0,green=1,blue=0}   or {red=0,green=0.7,blue=0},   currentTarget=="LEFT")
  rectDraw(rR, currentTarget=="RIGHT" and {red=0,green=0.6,blue=1} or {red=0,green=0.5,blue=0.8}, currentTarget=="RIGHT")
end
function M.toggleOverlay()
  overlayOn = not overlayOn
  drawOverlay(gameWindow())
end

-- 是否點在矩形內
local function pointInRect(pt, r)
  return pt.x>=r.x and pt.x<=r.x+r.w and pt.y>=r.y and pt.y<=r.y+r.h
end

-- 滑鼠拖曳調整
local mouseTap
local function ensureMouseTap()
  if mouseTap then return end
  mouseTap = hs.eventtap.new({
    hs.eventtap.event.types.leftMouseDown,
    hs.eventtap.event.types.leftMouseDragged,
    hs.eventtap.event.types.leftMouseUp
  }, function(e)
    if not editMode then return false end
    local win = gameWindow(); if not win then return false end
    local f = win:frame()
    local absL = relToAbs(f, ROI_REL_LEFT)
    local absR = relToAbs(f, ROI_REL_RIGHT)
    local pos  = hs.mouse.getAbsolutePosition()
    local ev   = e:getType()
    local shiftHeld = e:getFlags().shift

    local targetAbs
    if ev == hs.eventtap.event.types.leftMouseDown then
      if pointInRect(pos, absL) then currentTarget="LEFT";  targetAbs=absL
      elseif pointInRect(pos, absR) then currentTarget="RIGHT"; targetAbs=absR
      else return false end

      dragSession.active = true
      dragSession.startMouse = pos
      dragSession.startRect  = {x=targetAbs.x, y=targetAbs.y, w=targetAbs.w, h=targetAbs.h}
      dragSession.resize = shiftHeld -- Shift+拖曳 = resize
      drawOverlay(win)
      return true

    elseif ev == hs.eventtap.event.types.leftMouseDragged and dragSession.active then
      local dx = pos.x - dragSession.startMouse.x
      local dy = pos.y - dragSession.startMouse.y
      local newAbs = {x=dragSession.startRect.x, y=dragSession.startRect.y, w=dragSession.startRect.w, h=dragSession.startRect.h}
      if dragSession.resize then
        newAbs.w = math.max(5, dragSession.startRect.w + dx)
        newAbs.h = math.max(4, dragSession.startRect.h + dy)
      else
        newAbs.x = dragSession.startRect.x + dx
        newAbs.y = dragSession.startRect.y + dy
      end
      if currentTarget=="LEFT" then ROI_REL_LEFT  = absToRel(f, newAbs) else ROI_REL_RIGHT = absToRel(f, newAbs) end
      drawOverlay(win)
      return true

    elseif ev == hs.eventtap.event.types.leftMouseUp and dragSession.active then
      dragSession.active=false
      return true
    end
    return false
  end)
end

-- 鍵盤微調（只在編輯模式生效）
local keyTap
local function ensureKeyTap()
  if keyTap then return end
  keyTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
    if not editMode then return false end
    local win = gameWindow(); if not win then return false end
    local f = win:frame()
    local roi = (currentTarget=="LEFT") and ROI_REL_LEFT or ROI_REL_RIGHT
    local flags = e:getFlags()
    local code  = e:getKeyCode()
    local name  = hs.keycodes.map[code]
    local step  = flags.shift and 0.005 or 0.01 -- 0.5% 或 1%

    local changed = false
    if name == "up"    then roi.y = math.max(0, roi.y - step); changed=true
    elseif name == "down"  then roi.y = math.min(1 - roi.h, roi.y + step); changed=true
    elseif name == "left"  then roi.x = math.max(0, roi.x - step); changed=true
    elseif name == "right" then roi.x = math.min(1 - roi.w, roi.x + step); changed=true
    elseif name == "equal" or name == "kp+" then roi.h = math.min(1 - roi.y, roi.h + 0.005); changed=true
    elseif name == "minus" or name == "kp-" then roi.h = math.max(0.005, roi.h - 0.005); changed=true
    elseif name == "rightbracket" then roi.w = math.min(1 - roi.x, roi.w + 0.005); changed=true
    elseif name == "leftbracket"  then roi.w = math.max(0.005, roi.w - 0.005); changed=true
    elseif name == "tab" then currentTarget = (currentTarget=="LEFT") and "RIGHT" or "LEFT"; changed=true
    else return false end

    if changed then
      if currentTarget=="LEFT" then ROI_REL_LEFT=roi else ROI_REL_RIGHT=roi end
      drawOverlay(win)
      return true
    end

    return false
  end)
end

local function setEditMode(on)
  editMode = on
  if editMode then
    ensureMouseTap(); ensureKeyTap()
    mouseTap:start(); keyTap:start()
    hs.alert.show("ROI Edit: ON (拖曳移動, Shift+拖曳縮放)")
  else
    if mouseTap then mouseTap:stop() end
    if keyTap then keyTap:stop() end
    hs.alert.show("ROI Edit: OFF")
  end
end

-- 導出 ROI 百分比（Console + 置剪貼簿）
local function exportROI()
  local function fmt(r) return string.format("{ x=%.4f, y=%.4f, w=%.4f, h=%.4f }", r.x, r.y, r.w, r.h) end
  local s = ("ROI_REL_LEFT  = %s\nROI_REL_RIGHT = %s\n"):format(fmt(ROI_REL_LEFT), fmt(ROI_REL_RIGHT))
  hs.printf(s)
  hs.pasteboard.setContents(s)
  hs.alert.show("ROI exported → Console & Clipboard")
end

-- ===== FSM =====
local STATE = { active=false, mode="PATROL" }
local timers = {}
local leftward, roundCount = true, 0
local seenCount, noSeenCount = 0, 0
local lastAttackAt = 0

local function attackTick()
  if STATE.mode ~= "ENGAGE" then return end
  local win = gameWindow(); if not win then return end
  local now = hs.timer.absoluteTime()/1e6
  if now - lastAttackAt >= ATTACK_INTERVAL_MS then
    attackZ(ATTACK_PRESS_MS)
    lastAttackAt = now
  end
end

local function mainTick()
  if not STATE.active then return end
  local win = gameWindow(); if not win then return end
  if overlayOn then drawOverlay(win) end

  local roiRel = leftward and ROI_REL_LEFT or ROI_REL_RIGHT
  local seen = hasHPBar(win, roiRel)

  if STATE.mode == "PATROL" then
    if seen then
      seenCount = seenCount + 1
      if seenCount >= ENTER_DETECT_FRAMES then
        STATE.mode = "ENGAGE"
        noSeenCount = 0
        attackZ(ATTACK_PRESS_MS)
        lastAttackAt = hs.timer.absoluteTime()/1e6
        return
      end
    else
      seenCount = 0
    end

    for _=1,H_SWEEP_STEPS do
      teleport(leftward and KEY_LEFT or KEY_RIGHT, TP_PRESS_MS, TP_COOLDOWN_MS)
      attackZ(35)
    end
    leftward = not leftward
    roundCount = roundCount + 1
    if V_SWEEP_EVERY_ROUNDS>0 and (roundCount % V_SWEEP_EVERY_ROUNDS == 0) then
      for _=1,V_SWEEP_STEPS do teleport(KEY_UP, TP_PRESS_MS, TP_COOLDOWN_MS); attackZ(40) end
      for _=1,V_SWEEP_STEPS do teleport(KEY_DOWN, TP_PRESS_MS, TP_COOLDOWN_MS); attackZ(40) end
    end

  elseif STATE.mode == "ENGAGE" then
    if seen then
      noSeenCount = 0
    else
      noSeenCount = noSeenCount + 1
      if noSeenCount >= LEAVE_DETECT_FRAMES then
        STATE.mode = "CONFIRM_CLEAR"
      end
    end

  elseif STATE.mode == "CONFIRM_CLEAR" then
    leftward = not leftward
    if hasHPBar(win, leftward and ROI_REL_LEFT or ROI_REL_RIGHT) then
      STATE.mode = "ENGAGE"
      noSeenCount = 0
    else
      STATE.mode = "PATROL"
      seenCount, noSeenCount = 0, 0
    end
  end
end

-- ===== 對外介面 =====
local function start()
  if STATE.active then return end
  STATE.active=true
  STATE.mode="PATROL"
  leftward, roundCount = true, 0
  seenCount, noSeenCount = 0, 0
  lastAttackAt = 0

  timers.main   = hs.timer.doEvery(0.06, mainTick)
  timers.attack = hs.timer.doEvery(0.01, attackTick)
  timers.focus  = hs.timer.doEvery(FOCUS_CHECK_MS/1000, function()
    if not STATE.active then return end
    if not frontIsGame() then
      if timers.main and timers.main:running() then timers.main:stop() end
      if timers.attack and timers.attack:running() then timers.attack:stop() end
      clearOverlay()
    else
      if timers.main and not timers.main:running() then timers.main:start() end
      if timers.attack and not timers.attack:running() then timers.attack:start() end
      if overlayOn then drawOverlay(gameWindow()) end
    end
  end)

  hs.alert.show("Zombie FSM: START")
end

local function stop()
  if timers.main   then timers.main:stop()   end
  if timers.attack then timers.attack:stop() end
  if timers.focus  then timers.focus:stop()  end
  STATE.active=false
  clearOverlay()
  setEditMode(false)
  hs.alert.show("Zombie FSM: STOP")
end

function M.toggle()
  if STATE.active then stop() else start() end
end
function M.stop()
  stop()
end

-- 校色：輸出當前左右 ROI 的綠像素資訊（中線），便於調門檻
function M.debugHPBar()
  local win = gameWindow()
  if not win then hs.alert.show("No game window"); return end
  local function scan(relROI, tag)
    local rect = relToAbs(win:frame(), relROI)
    local img  = snapshotOnWindowScreen(win, rect)
    if not img then return end
    local w,h = img:size().w, img:size().h
    local y = math.floor(h/2)
    local total, greenCnt, maxRun, run = 0,0,0,0
    for x=0,w-1 do
      local c = img:colorAt({x=x, y=y})
      if c then
        local r,g,b=c.red,c.green,c.blue
        if isGreenHP(r,g,b) then
          greenCnt=greenCnt+1
          run=run+1
          if run>maxRun then maxRun=run end
        else
          run=0
        end
        total=total+1
      end
    end
    hs.printf("[%s] mid-line: green=%d/%d (%.1f%%), maxRun=%d rect=(%d,%d,%d,%d)",
      tag, greenCnt, total, (greenCnt/math.max(total,1))*100, maxRun,
      rect.x, rect.y, rect.w, rect.h)
  end
  scan(ROI_REL_LEFT,  "HP_LEFT")
  scan(ROI_REL_RIGHT, "HP_RIGHT")
  hs.alert.show("HPBar scan → Console")
end

-- 疊圖/編輯/匯出
function M.toggleOverlay()
  overlayOn = not overlayOn
  drawOverlay(gameWindow())
end
function M.toggleEdit()
  setEditMode(not editMode)
  if overlayOn==false and editMode then M.toggleOverlay() end
end
function M.exportROI()
  exportROI()
end

-- 也在模組內綁 F11/F12，方便即用
hs.hotkey.bind({"ctrl","alt","cmd"}, "F11", function() M.toggleEdit() end)
hs.hotkey.bind({"ctrl","alt","cmd"}, "F12", function() M.exportROI() end)

return M
