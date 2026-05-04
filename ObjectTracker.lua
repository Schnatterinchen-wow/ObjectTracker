--[[
  ObjectTracker — Turtle WoW 1.12: tooltip snapshot + keybind → SavedVariables + optional screenshot.

  Recording runs only when you press the bound key or /ot record — no automatic saves on hover or tooltip events.

  Capture uses the visible GameTooltip (not a unit mouseover). Avoid pressing record while a UI tooltip is open
  if you only want world objects; other addons may change GameTooltip's owner away from WorldFrame.

  Screenshots use Blizzard TakeScreenshot() if present (UI is not hidden — avoids breaking other addons).
  Each record stores cursor (raw + scaled by uiScale) + fractions of screenW/H in UI space (origin bottom-left), 2 decimal places.

  screenshots[] entries: { stamp, sessionT, cursorX, cursorY, cursorScaledX, cursorScaledY,
    cursorFracX, cursorFracY, screenW, screenH, uiScale }. Fracs omit if screen size is 0.
]]

ObjectTrackerDB = ObjectTrackerDB or {}
ObjectTrackerDB.objects = ObjectTrackerDB.objects or {}

local shotSafety

local function round2(n)
  if not n then
    return nil
  end
  return math.floor(n * 100 + 0.5) / 100
end

local function isValidMapCoord(x, y)
  return x and y and x >= 0 and x <= 100 and y >= 0 and y <= 100
end

local function continentNameFromIndex(ci)
  if not ci or ci <= 0 then
    return nil
  end
  local c = { GetMapContinents() }
  return c[ci]
end

local function playerMapPercent()
  local px, py = GetPlayerMapPosition("player")
  if not px or not py or (px == 0 and py == 0) then
    return nil, nil
  end
  return px * 100, py * 100
end

local function resolveZoneContinent()
  local rz = GetRealZoneText()
  local mz = GetMinimapZoneText()
  if not rz or rz == "" then
    rz = "?"
  end
  local effectiveZone = rz
  if mz and mz ~= "" and mz ~= rz then
    effectiveZone = rz .. " / " .. mz
  end
  local dunMeta = TWOW_GetDungeonMetaForZoneText(rz)
  local cont = TWOW_ContinentForZone(rz)
  if not cont and dunMeta then
    cont = TWOW_ContinentForAssociatedZone(dunMeta.associatedZone)
  end
  if not cont then
    local ci = GetCurrentMapContinent()
    if ci and ci > 0 then
      cont = continentNameFromIndex(ci)
    end
  end
  if not cont then
    cont = "Unknown"
  end
  return cont, effectiveZone, (mz and mz ~= "" and mz ~= rz) and mz or nil, dunMeta
end

local function normalizeObjectName(name)
  if not name or name == "" then
    return nil
  end
  name = string.gsub(name, "^%s+", "")
  name = string.gsub(name, "%s+$", "")
  name = string.gsub(name, "%s+", " ")
  if name == "" then
    return nil
  end
  return name
end

local function objectStorageKey(zone, x, y, name)
  return string.format("%s_%.2f_%.2f_%s", zone, x, y, name)
end

local function timestampTag()
  if date then
    return date("%Y-%m-%d_%H-%M-%S")
  end
  return string.format("session_%.0f", GetTime())
end

--- Cursor + viewport at record time. Raw = GetCursorPosition; scaled = raw / uiScale (same space as GetScreenWidth/Height).
--- cursorFracX/Y = scaled position / screen size; origin bottom-left (for bitmap top-left use y ≈ (1 - cursorFracY) * height).
local function pointerViewportSnapshot()
  local cx, cy = 0, 0
  if GetCursorPosition then
    cx, cy = GetCursorPosition()
  end
  local sw = GetScreenWidth and GetScreenWidth() or 0
  local sh = GetScreenHeight and GetScreenHeight() or 0
  local scale = 1
  if UIParent and UIParent.GetEffectiveScale then
    local ok, s = pcall(function()
      return UIParent:GetEffectiveScale()
    end)
    if ok and s and s > 0 then
      scale = s
    end
  end
  local sx = cx / scale
  local sy = cy / scale
  local rec = {
    sessionT = round2(GetTime()),
    cursorX = round2(cx),
    cursorY = round2(cy),
    cursorScaledX = round2(sx),
    cursorScaledY = round2(sy),
    screenW = round2(sw),
    screenH = round2(sh),
    uiScale = round2(scale),
  }
  if sw > 0 and sh > 0 then
    rec.cursorFracX = round2(sx / sw)
    rec.cursorFracY = round2(sy / sh)
  end
  return rec
end

local function collectTooltipLines()
  local lines = {}
  for i = 1, 32 do
    local l = getglobal("GameTooltipTextLeft" .. i)
    if not l then
      break
    end
    if l:IsShown() then
      local t = l:GetText()
      if t and t ~= "" then
        table.insert(lines, t)
      end
    end
  end
  return lines
end

--- Manual record only: whatever is currently shown on GameTooltip (see file header for caveats).
local function buildCaptureContext()
  if not GameTooltip or not GameTooltip.IsShown or not GameTooltip:IsShown() then
    return nil, "GameTooltip is not visible — hover the object or open the tooltip, then record."
  end
  if UnitExists("mouseover") then
    return nil, "Mouseover is a unit — use NPCTracker for NPCs."
  end
  local name = normalizeObjectName(GameTooltipTextLeft1:GetText())
  if not name then
    return nil, "No title line on GameTooltip."
  end
  local cont, zone, subHint, dunMeta = resolveZoneContinent()
  local x, y = playerMapPercent()
  if not x then
    return nil, "No valid player map position (open world map or stand in a mapped area)."
  end
  x = round2(x)
  y = round2(y)
  if not isValidMapCoord(x, y) then
    return nil, "Map coordinates out of range."
  end
  return {
    name = name,
    continent = cont,
    zone = zone,
    subzone = subHint,
    dungeonMeta = dunMeta,
    x = x,
    y = y,
    lines = collectTooltipLines(),
    stamp = timestampTag(),
    pointer = pointerViewportSnapshot(),
  }
end

local function persistCapture(ctx)
  local key = objectStorageKey(ctx.zone, ctx.x, ctx.y, ctx.name)
  local rec = ObjectTrackerDB.objects[key]
  if not rec then
    rec = {
      name = ctx.name,
      x = ctx.x,
      y = ctx.y,
      zone = ctx.zone,
      continent = ctx.continent,
      screenshots = {},
    }
    if ctx.subzone then
      rec.subzone = ctx.subzone
    end
    if ctx.dungeonMeta then
      rec.dungeon = ctx.dungeonMeta.name
      rec.parentZone = ctx.dungeonMeta.associatedZone
    end
    ObjectTrackerDB.objects[key] = rec
  end
  local p = ctx.pointer
  table.insert(rec.screenshots, {
    stamp = ctx.stamp,
    sessionT = p.sessionT,
    cursorX = p.cursorX,
    cursorY = p.cursorY,
    cursorScaledX = p.cursorScaledX,
    cursorScaledY = p.cursorScaledY,
    cursorFracX = p.cursorFracX,
    cursorFracY = p.cursorFracY,
    screenW = p.screenW,
    screenH = p.screenH,
    uiScale = p.uiScale,
  })
  rec.lastCapture = ctx.stamp
  rec.tooltipLinesLast = ctx.lines
  return key
end

shotSafety = CreateFrame("Frame")

local function clearShotSafetyTimer()
  shotSafety:SetScript("OnUpdate", nil)
end

--- Fallback if client never fires screenshot events (should be rare). Uses GetTime — some 1.12 builds pass nil as OnUpdate elapsed.
local function armScreenshotSafetyTimer()
  local deadline = GetTime() + 2.5
  shotSafety:SetScript("OnUpdate", function()
    if GetTime() >= deadline then
      clearShotSafetyTimer()
    end
  end)
end

local function takeScreenshotIfPossible()
  if type(TakeScreenshot) ~= "function" then
    DEFAULT_CHAT_FRAME:AddMessage(
      "|cff99ccffObjectTracker|r: TakeScreenshot() not available — no screenshot taken (check Turtle/SuperWoW build)."
    )
    return
  end
  local ok, err = pcall(TakeScreenshot)
  if not ok then
    clearShotSafetyTimer()
    DEFAULT_CHAT_FRAME:AddMessage("|cff99ccffObjectTracker|r: TakeScreenshot error: " .. tostring(err))
    return
  end
  armScreenshotSafetyTimer()
end

local shotEvents = CreateFrame("Frame")
shotEvents:RegisterEvent("SCREENSHOT_SUCCEEDED")
shotEvents:RegisterEvent("SCREENSHOT_FAILED")
shotEvents:SetScript("OnEvent", function()
  clearShotSafetyTimer()
end)

function ObjectTracker_RunCaptureBinding()
  local ctx, err = buildCaptureContext()
  if not ctx then
    DEFAULT_CHAT_FRAME:AddMessage("|cff99ccffObjectTracker|r: " .. (err or "record failed."))
    return
  end
  local key = persistCapture(ctx)
  DEFAULT_CHAT_FRAME:AddMessage(
    "|cff99ccffObjectTracker|r: saved |cff00ff00" .. key .. "|r shot " .. ctx.stamp
  )
  takeScreenshotIfPossible()
end

local function slashHandler(msg)
  local m = string.lower(string.gsub(msg or "", "^%s+", ""))
  if m == "" or m == "help" or m == "?" then
    DEFAULT_CHAT_FRAME:AddMessage("|cff99ccffObjectTracker|r commands:")
    DEFAULT_CHAT_FRAME:AddMessage(
      "  |cffdddddd/ot rec|r or |cffdddddd/ot record|r — save visible GameTooltip + coords + screenshot (manual only; no auto-save)."
    )
    DEFAULT_CHAT_FRAME:AddMessage(
      "  Bind a key: Escape → Key Bindings → AddOns → ObjectTracker — same idea as NPCTracker |cffddddddrecord|r."
    )
    DEFAULT_CHAT_FRAME:AddMessage(
      "  |cff888888Screenshots:|r Blizzard folder — match file time to |cffddddddstamp|r / |cffddddddsessionT|r with a few seconds margin."
    )
    DEFAULT_CHAT_FRAME:AddMessage(
      "  |cff888888Pointer:|r raw + |cffddddddcursorScaled|r (÷ uiScale), |cffddddddcursorFrac|r from bottom-left — flip Y for image top-left crops."
    )
    DEFAULT_CHAT_FRAME:AddMessage(
      "  |cff888888Optional:|r /console screenshotFormat jpeg (or SetCVar) if your client supports it — smaller than TGA."
    )
    return
  end
  if m == "rec" or m == "record" then
    ObjectTracker_RunCaptureBinding()
    return
  end
  DEFAULT_CHAT_FRAME:AddMessage("|cff99ccffObjectTracker|r: unknown — |cffdddddd/ot help|r")
end

SLASH_OBJECTTRACKER1 = "/objecttracker"
SLASH_OBJECTTRACKER2 = "/ot"
SlashCmdList["OBJECTTRACKER"] = slashHandler

local boot = CreateFrame("Frame")
boot:RegisterEvent("ADDON_LOADED")
boot:SetScript("OnEvent", function()
  if arg1 ~= "ObjectTracker" then
    return
  end
  DEFAULT_CHAT_FRAME:AddMessage("|cff99ccffObjectTracker|r loaded — |cffdddddd/ot help|r")
end)
