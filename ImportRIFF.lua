-- ImportRIFFPalette.lua
-- Imports a Microsoft/Windows RIFF .pal palette into Aseprite.

-- Part of Aseprite Nitro Plugins (https://github.com/RavenDS/Aseprite-Nitro-Plugins)
-- by ravenDS 

local function u16le(f)
  local b1,b2=f:read(1),f:read(1); if not b1 or not b2 then return nil end
  return string.byte(b1) | (string.byte(b2)<<8)
end

local function u32le(f)
  local b1,b2,b3,b4=f:read(1),f:read(1),f:read(1),f:read(1)
  if not b1 or not b2 or not b3 or not b4 then return nil end
  return (string.byte(b1)) | (string.byte(b2)<<8) | (string.byte(b3)<<16) | (string.byte(b4)<<24)
end

local function fourcc(f)
  local s=f:read(4); if not s or #s<4 then return nil end; return s
end

local function importRiffPal(path)
  local f,err=io.open(path,"rb")
  if not f then app.alert{title="RIFF PAL",text=("Cannot open file:\n%s"):format(err)}; return nil end

  if f:read(4)~="RIFF" then f:close(); app.alert{title="RIFF PAL",text="Missing 'RIFF' header."}; return nil end
  if not u32le(f) then f:close(); app.alert{title="RIFF PAL",text="Corrupt RIFF size."}; return nil end
  local form=fourcc(f)
  if form~="PAL " then f:close(); app.alert{title="RIFF PAL",text=("Form type is '%s', expected 'PAL '"):format(tostring(form))}; return nil end

  -- find 'data' chunk
  local dataPos,dataSize
  while true do
    local id=fourcc(f); if not id then break end
    local size=u32le(f); if not size then break end
    if id=="data" then dataPos=f:seek(); dataSize=size; break
    else f:seek("cur", size + (size%2)) end
  end
  if not dataPos then f:close(); app.alert{title="RIFF PAL",text="No 'data' chunk found."}; return nil end

  f:seek("set", dataPos)
  local ver=u16le(f); local count=u16le(f)
  if not ver or not count then f:close(); app.alert{title="RIFF PAL",text="Corrupt LOGPALETTE header."}; return nil end
  if count<1 or count>256 then f:close(); app.alert{title="RIFF PAL",text=("Unsupported entry count: %d"):format(count)}; return nil end

  local pal=Palette(count)
  for i=0,count-1 do
    local rB,gB,bB,flags=f:read(1),f:read(1),f:read(1),f:read(1)
    if not rB or not gB or not bB or not flags then
      f:close(); app.alert{title="RIFF PAL",text=("Unexpected EOF at entry %d."):format(i+1)}; return nil
    end
    pal:setColor(i, Color{ r=string.byte(rB), g=string.byte(gB), b=string.byte(bB), a=255 })
  end
  f:close()
  return pal
end

-- pick a file using a dialog 
local d = Dialog{ title="Import RIFF Palette" }
d:file{ id="path", label="RIFF .pal", open=true, filetypes={"pal"} }
d:check{ id="append", label="Append colors", text="Append to current palette instead of replacing", selected=false }
d:button{ id="ok", text="Import", focus=true }
d:button{ id="cancel", text="Cancel" }
d:show()

local data = d.data
if not data or not data.path or data.path=="" then return end
local newPal = importRiffPal(data.path)
if not newPal then return end

local spr = app.activeSprite or Sprite(1,1)
local finalPal

if data.append then
  local current = spr.palette
  local combined = {}
  -- gather existing colors
  for i = 0, #current-1 do
    combined[#combined+1] = current:getColor(i)
  end
  -- add new colors
  for i = 0, #newPal-1 do
    combined[#combined+1] = newPal:getColor(i)
  end
  -- trim if exceeds 256 colors
  if #combined > 256 then
    app.alert{
      title="RIFF PAL",
      text=string.format("Appending exceeds 256 colors. Trimming to 256 (from %d).", #combined)
    }
    while #combined > 256 do table.remove(combined) end
  end
  finalPal = Palette(#combined)
  for i = 0, #combined-1 do finalPal:setColor(i, combined[i+1]) end
else
  finalPal = newPal
end

app.transaction(function() spr:setPalette(finalPal) end)
app.refresh()
app.alert{
  title="RIFF PAL",
  text=(data.append
    and string.format("Appended %d colors (total %d) from:\n%s", #newPal, #finalPal, data.path)
    or  string.format("Imported %d colors from:\n%s", #newPal, data.path))
}
