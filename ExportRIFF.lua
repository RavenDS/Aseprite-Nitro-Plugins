-- ExportRIFF.lua
-- Export current palette to Microsoft/Windows RIFF .pal (LOGPALETTE 0x0300)

-- Part of Aseprite Nitro Plugins (https://github.com/RavenDS/Aseprite-Nitro-Plugins)
-- by ravenDS

-- helpers
local function le16(v)
  local lo = v & 0xFF
  local hi = (v >> 8) & 0xFF
  return string.char(lo, hi)
end

local function le32(v)
  local b0 =  v        & 0xFF
  local b1 = (v >> 8)  & 0xFF
  local b2 = (v >> 16) & 0xFF
  local b3 = (v >> 24) & 0xFF
  return string.char(b0, b1, b2, b3)
end

-- build RIFF from RGB colors
local function build_riff_pal(colors, targetCount)
  local n = #colors
  local target
  if targetCount == nil then
    target = math.max(1, math.min(n, 256))
  else
    target = math.max(1, math.min(256, math.floor(targetCount)))
  end

  local entries = {}
  local take = math.min(n, target)
  for i = 1, take do
    local c = colors[i]
    entries[#entries+1] = string.char(c.red & 0xFF, c.green & 0xFF, c.blue & 0xFF, 0x00)
  end
  for i = take+1, target do
    entries[#entries+1] = string.char(0, 0, 0, 0)
  end
  local entriesBlob = table.concat(entries)

  local dataPayload = table.concat({
    le16(0x0300),
    le16(target),
    entriesBlob
  })
  local dataChunk = table.concat({
    "data",
    le32(#dataPayload),
    dataPayload
  })
  local riffSize = 4 + #dataChunk
  local blob = table.concat({
    "RIFF",
    le32(riffSize),
    "PAL ",
    dataChunk
  })
  return blob, target
end

-- dialog returns from OK button, X/Cancel returns nil
local function show_export_dialog(defaultCount)
  local d = Dialog{ title = "Export Microsoft/Windows .PAL" }
  local defaultCountClamped = math.max(1, math.min(defaultCount or 256, 256))
  local result = nil  -- will be set ONLY if user presses OK successfully

  d:radio{
    id="autoMode", label="Mode", text="Auto (all up to 256)", selected=true,
    onclick=function()
      d:modify{ id="count", enabled=false }
    end
  }
  d:radio{
    id="customMode", text="Custom count",
    onclick=function()
      local val = tonumber(d.data and d.data.count)
      if not val or val == 0 then val = defaultCountClamped end
      d:modify{ id="count", enabled=true, text=tostring(val) }
    end
  }

  -- pre-filled count box (use text= so it shows in the UI)
  d:number{
    id="count", label="Custom Count", decimals=0,
    text=tostring(defaultCountClamped),
    min=1, max=256, enabled=false
  }

  d:file{
    id="out", label="Output .pal", save=true,
    filename="palette.pal", filetypes={"pal"}
  }

  d:button{ id="ok", text="Export", focus=true, onclick=function()
    local data = d.data or {}

    if data.customMode then
      local val = tonumber(data.count)
      if not val or val <= 0 or val > 256 then
        app.alert{ title="Export Microsoft/Windows .PAL", text="Please enter a valid color count (1–256)." }
        return -- keep dialog open
      end
    end

    if not data.out or data.out == "" then
      app.alert{ title="Export Microsoft/Windows .PAL", text="Please choose an output file." }
      return -- keep dialog open
    end

    local targetCount = nil
    if data.customMode then
      targetCount = tonumber(data.count)
    end

    result = { out=data.out, targetCount=targetCount }
    d:close()
  end }

  d:button{ id="cancel", text="Cancel", onclick=function()
    result = nil
    d:close()
  end }

  d:show()
  return result  -- nil if user pressed Cancel or closed with the X
end

-- MAIN
local spr = app.activeSprite
if not spr then
  app.alert{ title="Export Microsoft/Windows .PAL", text="No active sprite. Open or create a sprite to export its palette." }
  return
end

local pal = spr.palettes[1] or spr.palette
local palSize = #pal
if palSize == 0 then
  app.alert{ title="Export Microsoft/Windows .PAL", text="Current palette is empty." }
  return
end

local colors = {}
local maxc = math.min(palSize, 256)
for i = 0, maxc-1 do
  colors[#colors+1] = pal:getColor(i)
end

local opts = show_export_dialog(#colors)
if not opts then return end  -- <- nothing happens if user closed/cancelled

local blob, count = build_riff_pal(colors, opts.targetCount)

local f, err = io.open(opts.out, "wb")
if not f then
  app.alert{ title="Export Microsoft/Windows .PAL", text=("Cannot write file:\n%s"):format(tostring(err)) }
  return
end
f:write(blob)
f:close()

app.alert{
  title="Export Microsoft/Windows .PAL",
  text=string.format("Exported %d color entries to:\n%s", count, opts.out)
}
