-- ImportNCGR.lua
-- Import NCGR (RGCN) using a NCLR/RLCN palette into the current sprite.
-- Based on DSlibGFX.vb

-- Part of Aseprite Nitro Plugins (https://github.com/RavenDS/Aseprite-Nitro-Plugins)
-- by ravenDS 

-- helpers
local function u16(b, i) return (b[i+1] or 0) | ((b[i+2] or 0) << 8) end
local function s16(b, i) local v=u16(b,i); if v>=0x8000 then v=v-0x10000 end; return v end
local function u32(b, i) return (b[i+1] or 0)|((b[i+2] or 0)<<8)|((b[i+3] or 0)<<16)|((b[i+4] or 0)<<24) end
local function bytes_of(s) return { s:byte(1,#s) } end

local function ds555_to_color(w)
  local r5 =  w        % 32
  local g5 = (w // 32) % 32
  local b5 = (w // 1024) % 32
  return Color{ r=r5*8+(r5//4), g=g5*8+(g5//4), b=b5*8+(b5//4), a=255 }
end

-- nitro block finder (scan after 0x10 header)
local function find_block(bytes, fourcc)
  local n=#bytes
  local f1,f2,f3,f4=string.byte(fourcc,1,4)
  local off=0x10
  while off+8<=n do
    if bytes[off+1]==f1 and bytes[off+2]==f2 and bytes[off+3]==f3 and bytes[off+4]==f4 then
      local size=u32(bytes,off+4)
      return off,size
    end
    local size=u32(bytes,off+4)
    if size<8 then break end
    off=off+size
  end
  return nil,nil
end

-- read NCGR
-- returns raw header tiles (may be -1), computed numTiles, etc
local function read_ncgr(path)
  local f,e=io.open(path,"rb"); if not f then return nil,"Cannot open NCGR: "..tostring(e) end
  local data=f:read("*all"); f:close()
  if data:sub(1,4) ~= "RGCN" and data:sub(1,4) ~= "NCGR" then return nil,"Not a valid NCGR (RGCN)." end
  local b=bytes_of(data)

  local charOff,charSize = find_block(b,"RAHC")
  if not charOff then charOff,charSize = find_block(b,"CHAR") end
  if not charOff then return nil,"RAHC/CHAR (CHAR) block not found." end
  if charSize < 0x20 then return nil,"RAHC/CHAR payload too small." end

  -- depth: 3->4bpp, else 8bpp
  local depthCode=b[charOff+0x0C+1] or 0
  local bits=(depthCode==3) and 4 or 8

  -- raw header values (can be -1)
  local hdrTilesTall=s16(b,charOff+0x08)
  local hdrTilesWide=s16(b,charOff+0x0A)

  local gfxBytes=u32(b,charOff+0x18)
  local scanned=(b[charOff+0x14+1] or 0)~=0 -- BMP/scanned mode (unsupported here)

  local imageDataOff=charOff+0x20
  local imageDataEnd=imageDataOff+gfxBytes-1
  if imageDataEnd>#b then return nil,"NCGR pixel data truncated." end

  local bytesPerTile=(64/(8/bits)) -- 32(4bpp) / 64(8bpp)
  local numTiles=math.floor(gfxBytes/bytesPerTile)

  return {
    bits=bits,
    headerTilesX=hdrTilesWide,
    headerTilesY=hdrTilesTall,
    numTiles=numTiles,
    scanned=scanned,
    data=data:sub(imageDataOff+1,imageDataEnd+1)
  }, nil
end

-- default pixel size from NCGR header + numTiles
-- if both header dims are -1, choose the pair closest to sqrt(numTiles)
-- if one dim is valid, edit other to fit all tiles
local function best_factor_pair(n)
  if n <= 0 then return 1,1 end
  local r = math.floor(math.sqrt(n))
  for x = r, 1, -1 do
    if n % x == 0 then
      return x, math.floor(n / x)
    end
  end
  return 1, n
end

local function default_dims_from_ncgr(ncgr)
  local tx_raw, ty_raw = ncgr.headerTilesX, ncgr.headerTilesY
  local tilesX, tilesY
  if (tx_raw or -1) < 0 and (ty_raw or -1) < 0 then
    -- both -1
    tilesX, tilesY = best_factor_pair(ncgr.numTiles)
  else
    tilesX = (tx_raw and tx_raw > 0) and tx_raw or 1
    if ty_raw and ty_raw > 0 then
      tilesY = ty_raw
    else
      tilesY = math.ceil(ncgr.numTiles / tilesX)
    end
  end
  return tilesX*8, tilesY*8, tilesX, tilesY
end

-- condensed NCLR palette reader
local function read_nclr(path)
  local f,e=io.open(path,"rb"); if not f then return nil,"Cannot open NCLR/NCPR: "..tostring(e) end
  local data=f:read("*all"); f:close()
  local sig=data:sub(1,4)
  local b=bytes_of(data)

  local plttOff,plttSize=find_block(b,"TTLP")
  if not plttOff then plttOff,plttSize=find_block(b,"PLTT") end
  if not plttOff then return nil,"PLTT/TTLP block not found." end
  if plttSize<0x18 then return nil,"PLTT payload too small." end

  -- header bitdepth: 3 => 4bpp, else 8bpp
  local code=b[plttOff+0x08+1] or 3
  local bits=(code==3) and 4 or 8

  local palSizeBytes=u32(b,plttOff+0x10)
  local palDataOff=plttOff+0x18
  local palDataEnd=palDataOff+palSizeBytes-1
  if palDataEnd>#b then return nil,"Palette data truncated." end

  local nColors=math.floor(palSizeBytes/2)
  local cols={}
  for i=0,nColors-1 do
    local w = u16(b, palDataOff + i*2)
    cols[#cols+1] = ds555_to_color(w)
  end

  -- pad to multiple of 16 (max 256)
  local want=math.min(256,(#cols + (16-(#cols%16))%16))
  while #cols<want do cols[#cols+1]=Color{r=0,g=0,b=0,a=255} end

  return { bits=bits, colors=cols }, nil
end

-- tile decoders to row-major buffer of indices
local function decode4bpp_to_buffer(raw, tilesX, tilesY)
  local pos=1
  local w=tilesX*8; local h=tilesY*8; local pitch=w
  local out={}
  for ty=0,tilesY-1 do
    for tx=0,tilesX-1 do
      for j=0,7 do
        local rowBase=(ty*8+j)*pitch
        for k=0,3 do
          local byte=string.byte(raw,pos) or 0; pos=pos+1
          local left  = byte & 0x0F
          local right = (byte >> 4) & 0x0F
          local x0=tx*8+k*2
          out[rowBase+x0+1]=left
          out[rowBase+x0+2]=right
        end
      end
    end
  end
  return out,w,h
end

local function decode8bpp_to_buffer(raw, tilesX, tilesY)
  local pos=1
  local w=tilesX*8; local h=tilesY*8; local pitch=w
  local out={}
  for ty=0,tilesY-1 do
    for tx=0,tilesX-1 do
      for j=0,7 do
        local rowBase=(ty*8+j)*pitch
        for k=0,7 do
          local x=tx*8+k
          out[rowBase+x+1]=string.byte(raw,pos) or 0; pos=pos+1
        end
      end
    end
  end
  return out,w,h
end

-- UI
local function ask_paths()
  local d=Dialog{ title="Import NCGR using NCLR" }
  d:file{ id="ncgr", label="NCGR", open=true, filetypes={"ncgr","rgcn"} }
  d:file{ id="nclr", label="NCLR", open=true, filetypes={"nclr","rlcn","ncpr","rpcn"} }
  d:button{ id="ok", text="Next", focus=true, onclick=function()
    local dt=d.data
    if not dt or not dt.ncgr or dt.ncgr=="" or not dt.nclr or dt.nclr=="" then
      app.alert{ title="Import NCGR/NCLR", text="Select both NCGR and NCLR files." }; return
    end
    d:close()
  end}
  d:button{ id="cancel", text="Cancel", onclick=function() d:close() end }
  d:show()
  local dt=d.data
  if not dt or dt.ncgr=="" or dt.nclr=="" then return nil end
  return dt.ncgr, dt.nclr
end

-- ask for for final WIDTH/HEIGHT in pixels (multiple of 8)
local function ask_target_pixels(defaultW, defaultH)
  local d=Dialog{ title="Final Image Size (pixels)" }
  d:number{ id="w", label="Width (px)",  decimals=0, text=tostring(defaultW) }
  d:number{ id="h", label="Height (px)", decimals=0, text=tostring(defaultH) }
  d:button{ id="ok", text="Import", focus=true, onclick=function() d:close() end }
  d:button{ id="cancel", text="Cancel", onclick=function() d:close() end }
  d:show()
  local dt=d.data
  if not dt or not dt.w or not dt.h then return nil end
  local wnum = tonumber(dt.w) or defaultW
  local hnum = tonumber(dt.h) or defaultH
  local W = math.max(8, math.floor((wnum + 7)/8)*8) -- make multiple of 8
  local H = math.max(8, math.floor((hnum + 7)/8)*8) -- make multiple of 8 (may increase later)
  return W, H
end

local function ask_bank(nBanks)
  if nBanks<=1 then return 0 end
  local opts={}
  for i=0,nBanks-1 do opts[#opts+1]=string.format("Bank %d [%d..%d]", i, i*16, i*16+15) end
  local d=Dialog{ title="4bpp Palette Bank" }
  d:combobox{ id="bank", label="Bank", options=opts, option=opts[1] }
  d:button{ id="ok", text="Use", focus=true, onclick=function() d:close() end }
  d:button{ id="cancel", text="Cancel", onclick=function() d:close() end }
  d:show()
  local dd=d.data; if not dd or not dd.bank then return nil end
  return tonumber(dd.bank:match("^Bank%s+(%d+)")) or 0
end

-- canvas resize
local function ensure_canvas_size(sprite, W, H)
  if sprite.width==W and sprite.height==H then return true end
  -- try CanvasSize (preferred)
  local ok = pcall(function()
    app.transaction(function()
      app.command.CanvasSize{ ui=false, width=W, height=H, anchor="top-left" }
    end)
  end)
  if ok and sprite.width==W and sprite.height==H then return true end

  -- try SpriteSize
  ok = pcall(function()
    app.transaction(function()
      app.command.SpriteSize{ ui=false, method="nearest", width=W, height=H, lockRatio=false }
    end)
  end)
  if ok and sprite.width==W and sprite.height==H then return true end

  -- last resort lol
  if sprite.resize then
    local ok2 = pcall(function() sprite:resize(W,H) end)
    if ok2 and sprite.width==W and sprite.height==H then return true end
  end
  return sprite.width==W and sprite.height==H
end

-- MAIN
local ncgrPath, nclrPath = ask_paths()
if not ncgrPath then return end

local ncgr, e1 = read_ncgr(ncgrPath)
if not ncgr then app.alert{title="Import NCGR/NCLR", text=e1}; return end
if ncgr.scanned then
  app.alert{ title="Import NCGR/NCLR", text="This NCGR is in 'scanned/BMP' mode, which this script doesn't decode yet." }
  return
end

-- compute good default from header + numTiles (square-ish if both -1)
local defW, defH, defTilesX, defTilesY = default_dims_from_ncgr(ncgr)

-- ask for final pixel size
local W, H = ask_target_pixels(defW, defH)
if not W then return end

-- derive tile layout from W/H, if not enough rows, increase HEIGHT
local tilesX = math.max(1, math.floor(W / 8))
local tilesNeeded = ncgr.numTiles
local tilesY = math.ceil(tilesNeeded / tilesX)
local finalH = tilesY * 8
if finalH > H then
  -- auto-extend height to fit all tiles
  H = finalH
end

-- decode with computed tile layout (tilesX × tilesY covers all tiles)
local pal, e2 = read_nclr(nclrPath)
if not pal then app.alert{title="Import NCGR/NCLR", text=e2}; return end

-- validate palette vs mode
if ncgr.bits==8 then
  if #pal.colors<256 then
    app.alert{ title="Import NCGR/NCLR", text=("8bpp NCGR requires 256 colors in NCLR (has %d)."):format(#pal.colors) }
    return
  end
else
  if #pal.colors<16 then
    app.alert{ title="Import NCGR/NCLR", text="4bpp NCGR requires at least 16 colors in NCLR." }
    return
  end
end

-- bank selection for 4bpp
local bankIndex=0
if ncgr.bits==4 then
  local banks=math.max(1, math.floor(#pal.colors/16))
  local chosen=ask_bank(banks); if chosen==nil then return end
  if chosen<0 then chosen=0 end
  if chosen>banks-1 then chosen=banks-1 end
  bankIndex=chosen
end

-- decode to buffer (indices 0..15 for 4bpp!)
local buffer,w,h
if ncgr.bits==8 then
  buffer,w,h=decode8bpp_to_buffer(ncgr.data, tilesX, tilesY)
else
  buffer,w,h=decode4bpp_to_buffer(ncgr.data, tilesX, tilesY)
end
-- ensure target canvas matches decoded size (HEIGHT could be increased)
local targetW, targetH = w, math.max(h, H)

-- prepare current sprite (create tiny placeholder only if none)
local spr=app.activeSprite
local createdNew = false
if not spr then
  spr=Sprite(8,8,ColorMode.INDEXED)
  createdNew = true
end

-- ensure indexed mode
if spr.colorMode~=ColorMode.INDEXED then
  pcall(function() app.command.ChangePixelFormat{ ui=false, format="indexed", dithering="none" } end)
end

-- build and set palette
local targetPal
if ncgr.bits==8 then
  targetPal=Palette(256)
  for i=0,255 do
    targetPal:setColor(i, pal.colors[i+1] or pal.colors[#pal.colors])
  end
else
  -- 16 colors from the chosen bank
  targetPal=Palette(16)
  local base=bankIndex*16
  for i=0,15 do
    targetPal:setColor(i, pal.colors[base+i+1] or Color{r=0,g=0,b=0,a=255})
  end
end
spr:setPalette(targetPal)

-- resize canvas to target size
if not ensure_canvas_size(spr, targetW, targetH) then
  app.alert{ title="Import NCGR/NCLR", text="Could not resize canvas to the required size." }
  return
end

-- choose a layer (first or create)
local layer = spr.layers[1]
if not layer then layer = spr:newLayer() end

-- put pixels into image and place as cel(1)
local img=Image(w,h,ColorMode.INDEXED)
do
  local idx=1
  for it in img:pixels() do
    local v = buffer[idx] or 0
    it(v)
    idx=idx+1
  end
end

app.transaction(function()
  local cel = layer:cel(1)
  if cel then
    cel.image = img
    cel.position = Point(0,0)
  else
    spr:newCel(layer, 1, img, Point(0,0))
  end
end)

-- disable transparent index at the very end
if createdNew then
  spr.transparentColor = -1
else
  spr.transparentColor = -1
end

app.refresh()
local usedDefaultsNote = string.format("default tiles %dx%d → %dx%d px",
  defTilesX, defTilesY, defTilesX*8, defTilesY*8)
local grewNote = (h ~= defH or w ~= defW) and " (computed layout from width / auto-extended height)" or ""
app.alert{
  title="Import NCGR/NCLR",
  text=string.format(
    "Imported %dx%d (%dbpp). Layout: %d×%d tiles. Bank: %s",
    w,h,ncgr.bits, tilesX, tilesY,
    (ncgr.bits==4 and tostring(bankIndex) or "N/A"), ncgrPath, nclrPath)
}
