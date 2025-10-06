-- ReduceIndex.lua
-- Reduce colors and index image (top-N frequency + nearest-color remap)
-- Based on DSTME "ColorReducer.vb"

-- Part of Aseprite Nitro Plugins (https://github.com/RavenDS/Aseprite-Nitro-Plugins)
-- by ravenDS


-- helpers
local pc = app.pixelColor

local function rgb_key(r,g,b) return (r<<16)|(g<<8)|b end

local function get_src_image_and_meta(spr)
  local w,h = spr.width, spr.height
  local pal = (spr.colorMode == ColorMode.INDEXED) and (spr.palette or spr.palettes and spr.palettes[1]) or nil
  local layer = spr.layers[1] or spr:newLayer()
  local cel = layer:cel(1)
  if cel and cel.image then
    -- work on a copy so we never mutate a deleted ImageObj
    return Image(cel.image), w, h, pal, spr.colorMode, layer
  else
    return Image(spr.spec), w, h, pal, spr.colorMode, layer
  end
end

-- extract RGB from a pixel value according to color mode
local function pixel_to_rgb(px, mode, pal)
  if mode == ColorMode.RGB then
    return pc.rgbaR(px), pc.rgbaG(px), pc.rgbaB(px)
  elseif mode == ColorMode.GRAY then
    local v = pc.grayaV(px)
    return v, v, v
  elseif mode == ColorMode.INDEXED then
    local idx = pc.indexedI(px)
    local c = pal and pal:getColor(idx) or Color{r=idx,g=idx,b=idx,a=255}
    return c.red, c.green, c.blue
  else
    local c = Color(px)
    return c.red, c.green, c.blue
  end
end

-- squared distance
local function dist2(r,g,b, pr,pg,pb)
  local dr = r - pr; local dg = g - pg; local db = b - pb
  return dr*dr + dg*dg + db*db
end

-- build frequency table of RGB colors
local function build_frequency(img, mode, pal)
  local freq, uniq = {}, {}
  for it in img:pixels() do
    local r,g,b = pixel_to_rgb(it(), mode, pal)
    local key = rgb_key(r,g,b)
    if freq[key] then
      freq[key] = freq[key] + 1
    else
      freq[key] = 1
      uniq[key] = {r=r,g=g,b=b}
    end
  end
  local list = {}
  for k,count in pairs(freq) do
    local c = uniq[k]
    list[#list+1] = { r=c.r, g=c.g, b=c.b, count=count }
  end
  table.sort(list, function(a,b)
    if a.count ~= b.count then return a.count > b.count end
    if a.r ~= b.r then return a.r < b.r end
    if a.g ~= b.g then return a.g < b.g end
    return a.b < b.b
  end)
  return list
end

-- build palette from top N colors
local function palette_from_topN(list, N)
  local n = math.max(1, math.min(N, 256, #list))
  local pal = Palette(n)
  for i=0,n-1 do
    local c = list[i+1]
    pal:setColor(i, Color{ r=c.r, g=c.g, b=c.b, a=255 })
  end
  return pal, n
end

-- nearest index (0-based)
local function nearest_index(r,g,b, palRGB)
  local bestIdx = 0
  local best = 0x7fffffffffffffff
  for i=1,#palRGB do
    local p = palRGB[i]
    local d = dist2(r,g,b, p.r,p.g,p.b)
    if d < best then
      best = d
      bestIdx = i-1
    end
  end
  return bestIdx
end

-- MAIN
local spr = app.activeSprite
if not spr then
  app.alert{ title="Reduce & Index Colors", text="Open a sprite first." }
  return
end

local srcImg, w, h, srcPal, srcMode, layer = get_src_image_and_meta(spr)
local freqList = build_frequency(srcImg, srcMode, srcPal)
local uniqueCount = #freqList
if uniqueCount == 0 then
  app.alert{ title="Reduce & Index Colors", text="Image appears to be empty." }
  return
end

local defaultN = math.min(256, math.max(1, uniqueCount))
local dlg = Dialog{ title="Reduce & Index Colors" }
dlg:label{ id="info", label="Detected", text=string.format("%d unique colors", uniqueCount) }
dlg:number{ id="n", label="Keep colors (max. 256)", decimals=0, text=tostring(defaultN) }
dlg:button{ id="ok", text="OK", focus=true, onclick=function() dlg:close() end }
dlg:button{ id="cancel", text="Cancel", onclick=function() dlg:close() end }
dlg:show()
local dd = dlg.data
if not dd or not dd.n then return end
local N = math.floor(tonumber(dd.n) or defaultN)
N = math.max(1, math.min(256, N))

local targetPal, palCount = palette_from_topN(freqList, N)

-- prepack palette rgb
local palRGB = {}
for i=0,palCount-1 do
  local c = targetPal:getColor(i)
  palRGB[i+1] = { r=c.red, g=c.green, b=c.blue }
end

-- build output indexed image
local outImg = Image(w, h, ColorMode.INDEXED)
for it in outImg:pixels() do
  local x,y = it.x, it.y
  local r,g,b = pixel_to_rgb(srcImg:getPixel(x,y), srcMode, srcPal)
  it(nearest_index(r,g,b, palRGB))
end

if spr.colorMode == ColorMode.INDEXED then
  app.transaction(function()
    spr:setPalette(targetPal)
    spr.transparentColor = -1               -- index 0 is OPAQUE
    local cel = layer:cel(1)
    if cel then
      cel.image = outImg
      cel.position = Point(0,0)
    else
      spr:newCel(layer, 1, outImg, Point(0,0))
    end
  end)
  app.refresh()
  app.alert{ title="Reduce & Index Colors", text=("Done. Kept "..palCount.." colors.") }
else
  local newSpr = Sprite(w, h, ColorMode.INDEXED)
  app.transaction(function()
    newSpr:setPalette(targetPal)
    newSpr.transparentColor = -1           -- index 0 NOT transparent
    local lyr = newSpr.layers[1] or newSpr:newLayer()
    newSpr:newCel(lyr, 1, outImg, Point(0,0))
  end)
  app.refresh()
  app.alert{ title="Reduce & Index Colors", text=("Done. Kept "..palCount.." colors.") }
end
