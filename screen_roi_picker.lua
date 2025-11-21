-- ~/.hammerspoon/screen_roi_picker.lua
-- 用滑鼠框選螢幕區域，輸出 ROI_X1/X2/Y1/Y2 一次後就停止

local mod = {}

local drawing    = nil
local startPoint = nil
local screenFrame = nil
local eventTap   = nil
local active     = false

------------------------------------------------------------
-- 工具：像素座標 → 比例
------------------------------------------------------------
local function calcRatios(x1, y1, x2, y2)
  local W = screenFrame.w
  local H = screenFrame.h
  return {
    X1 = x1 / W,
    X2 = x2 / W,
    Y1 = y1 / H,
    Y2 = y2 / H,
  }
end

------------------------------------------------------------
-- 工具：輸出比例 + 寫檔
------------------------------------------------------------
local function printRatios(rt)
  local msg = string.format(
    "ROI_RATIOS = { X1=0.%.4f, X2=0.%.4f, Y1=0.%.4f, Y2=0.%.4f }",
    rt.X1 * 10, rt.X2 * 10, rt.Y1 * 10, rt.Y2 * 10
  )

  -- 給你看用的 log
  print("[ROI-PICKER]\t" .. msg)
  hs.alert.show("ROI 已輸出到 Console")

  -- 寫入 roi.env，給 shell / Python 用
  local path = os.getenv("HOME") .. "/data/github/artale/roi.env"
  local f = io.open(path, "w")
  if f then
    f:write(string.format(
      "export ROI_X1=%.4f\nexport ROI_X2=%.4f\nexport ROI_Y1=%.4f\nexport ROI_Y2=%.4f\n",
      rt.X1, rt.X2, rt.Y1, rt.Y2
    ))
    f:close()
    print("[ROI-PICKER] 已寫入：" .. path)
  else
    print("[ROI-PICKER] 無法寫入：" .. path)
  end
end

------------------------------------------------------------
-- 停止 / 清理（一次圈選完就會呼叫）
------------------------------------------------------------
local function stop()
  active = false

  if eventTap then
    eventTap:stop()
    eventTap = nil
  end

  if drawing then
    drawing:delete()
    drawing = nil
  end

  startPoint  = nil
  screenFrame = nil
end

------------------------------------------------------------
-- 啟動圈選（由 init.lua 綁定 ⌘⌥P）
------------------------------------------------------------
function mod.start()
  -- 若前一次沒收乾淨，先清一次
  stop()

  active = true
  hs.alert.show("滑鼠拖曳選擇 ROI 區域")

  local screen = hs.screen.mainScreen()
  screenFrame = screen:fullFrame()

  drawing = hs.drawing.rectangle(hs.geometry.rect(0, 0, 0, 0))
  drawing:setStrokeColor({ red = 0, green = 0.6, blue = 1, alpha = 0.9 })
  drawing:setStrokeWidth(3)
  drawing:setFill(false)
  drawing:setLevel(hs.drawing.windowLevels.overlay)
  drawing:show()

  eventTap = hs.eventtap.new(
    {
      hs.eventtap.event.types.leftMouseDown,
      hs.eventtap.event.types.leftMouseDragged,
      hs.eventtap.event.types.leftMouseUp,
    },
    function(e)
      if not active then
        return false
      end

      local typ = e:getType()
      local pos = e:location()

      if typ == hs.eventtap.event.types.leftMouseDown then
        -- 起點
        startPoint = pos

      elseif typ == hs.eventtap.event.types.leftMouseDragged then
        if startPoint and drawing then
          local x = math.min(startPoint.x, pos.x)
          local y = math.min(startPoint.y, pos.y)
          local w = math.abs(startPoint.x - pos.x)
          local h = math.abs(startPoint.y - pos.y)
          drawing:setFrame(hs.geometry.rect(x, y, w, h))
        end

      elseif typ == hs.eventtap.event.types.leftMouseUp then
        if startPoint and screenFrame then
          local x = math.min(startPoint.x, pos.x)
          local y = math.min(startPoint.y, pos.y)
          local w = math.abs(startPoint.x - pos.x)
          local h = math.abs(startPoint.y - pos.y)

          -- 換成以主螢幕為原點的座標
          local x1 = x - screenFrame.x
          local y1 = y - screenFrame.y
          local x2 = x1 + w
          local y2 = y1 + h

          local rt = calcRatios(x1, y1, x2, y2)
          printRatios(rt)
        end

        -- ⭐ 關鍵：只輸出一次，立刻停止所有監聽與畫面
        stop()
      end

      return false
    end
  )

  eventTap:start()
end

return mod