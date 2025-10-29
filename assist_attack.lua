local M = {}
local running = false
local timer

-- 按鍵設定
local ATTACK_KEY = "z"
local DIR_LEFT  = "left"
local DIR_RIGHT = "right"

-- 時序設定
local HOLD_MS   = 34000  -- 每次壓住 3 秒
local STEP_PAUSE = 200  -- 每個動作之間停頓 0.2 秒，避免卡鍵

local function sleep(ms) hs.timer.usleep(ms*1000) end

local function keyDown(mods, key) hs.eventtap.event.newKeyEvent(mods or {}, key, true):post() end
local function keyUp(mods, key)   hs.eventtap.event.newKeyEvent(mods or {}, key, false):post() end

-- 壓著 Shift+方向+Z
local function holdShiftZ(dirKey, ms)
  if dirKey then keyDown({"shift"}, dirKey) end
  keyDown({}, ATTACK_KEY)

  sleep(ms or HOLD_MS)

  if dirKey then keyUp({"shift"}, dirKey) end
  keyUp({}, ATTACK_KEY)
end

-- 一輪流程
local function oneCycle()
  -- 原地打
  holdShiftZ(nil, HOLD_MS); sleep(STEP_PAUSE)

  -- 左瞬移 + 打
  holdShiftZ(DIR_LEFT, HOLD_MS); sleep(STEP_PAUSE)

  -- 再往左瞬移 + 打
  holdShiftZ(DIR_LEFT, HOLD_MS); sleep(STEP_PAUSE)

  -- 再往右瞬移 + 打
  holdShiftZ(DIR_RIGHT, HOLD_MS); sleep(STEP_PAUSE)
end

-- 主 loop
local function loop()
  if not running then return end
  oneCycle()
end

function M.toggle()
  if running then
    M.stop()
  else
    running = true
    timer = hs.timer.doWhile(function() return running end, loop, 0.01)
    hs.alert.show("Assist Combo: START")
  end
end

function M.stop()
  running = false
  if timer then timer:stop() end
  -- 確保放開按鍵
  keyUp({"shift"}, DIR_LEFT)
  keyUp({"shift"}, DIR_RIGHT)
  keyUp({}, ATTACK_KEY)
  hs.alert.show("Assist Combo: STOP")
end

return M
