local M = {}
local events = {}
local startTime
local tap

local path = os.getenv("HOME") .. "/.hammerspoon/recording.json"

-- 開始錄製
function M.startRecording()
  events = {}
  startTime = hs.timer.absoluteTime()/1e9 -- 秒
  if tap then tap:stop() end

  tap = hs.eventtap.new({
    hs.eventtap.event.types.keyDown,
    hs.eventtap.event.types.keyUp,
  }, function(e)
    local now = hs.timer.absoluteTime()/1e9
    local delay = now - startTime
    local info = {
      time = delay,
      type = (e:getType() == hs.eventtap.event.types.keyDown) and "down" or "up",
      key = hs.keycodes.map[e:getKeyCode()],
      mods = e:getFlags()
    }
    table.insert(events, info)
    return false
  end)
  tap:start()
  hs.alert.show("Recording started")
end

-- 停止錄製並存檔
function M.stopRecording()
  if tap then tap:stop() end
  local f = io.open(path, "w")
  f:write(hs.json.encode(events))
  f:close()
  hs.alert.show("Recording saved: " .. path)
end

-- 播放錄製
function M.playRecording()
  local f = io.open(path, "r")
  if not f then
    hs.alert.show("No recording found")
    return
  end
  local data = f:read("*a")
  f:close()
  local seq = hs.json.decode(data)
  if not seq then
    hs.alert.show("Invalid recording file")
    return
  end

  local base = hs.timer.absoluteTime()/1e9
  for _, ev in ipairs(seq) do
    hs.timer.doAfter(ev.time, function()
      hs.eventtap.event.newKeyEvent(ev.mods or {}, ev.key, ev.type=="down"):post()
    end)
  end
  hs.alert.show("Playback started")
end

return M
