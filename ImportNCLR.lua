-- ImportNCLR.lua
-- Import palette from Nintendo DS NCLR (RLCN) file

-- Part of Aseprite Nitro Plugins (https://github.com/RavenDS/Aseprite-Nitro-Plugins)
-- by ravenDS 

-- little-endian reader 
local function u16le(b, i) return b[i+1] | (b[i+2] << 8) end
local function u32le(b, i)
  return b[i+1] | (b[i+2] << 8) | (b[i+3] << 16) | (b[i+4] << 24)
end

-- find block by fourcc
local function find_block(bytes, fourcc)
  local n = #bytes
  for i = 0, n - 8 do
    if bytes[i+1]==string.byte(fourcc,1)
    and bytes[i+2]==string.byte(fourcc,2)
    and bytes[i+3]==string.byte(fourcc,3)
    and bytes[i+4]==string.byte(fourcc,4) then
      local size = u32le(bytes, i+4)
      if size >= 8 and i+8+size-8 <= n then
        return i+8, size-8
      end
    end
  end
  return nil,nil
end

local function ds555_to_color(w)
  local r5 =  w        % 32
  local g5 = (w // 32) % 32
  local b5 = (w // 1024) % 32
  return Color{ r=r5*8+(r5//4), g=g5*8+(g5//4), b=b5*8+(b5//4), a=255 }
end

-- parse NCLR
local function read_nclr_palette(path)
  local f,err = io.open(path,"rb")
  if not f then error("Cannot open file: "..tostring(err)) end
  local data=f:read("*all"); f:close()
  local bytes={data:byte(1,#data)}

  local off,len=find_block(bytes,"PLTT"); if not off then off,len=find_block(bytes,"TTLP") end
  assert(off and len,"PLTT/TTLP block not found.")
  local bitsCode=u32le(bytes,off+0)
  local bits=1<<(bitsCode-1); if bits~=4 and bits~=8 then bits=8 end
  local dataBytes=u32le(bytes,off+8)
  local dataOff=u32le(bytes,off+12)
  local palStart=off+dataOff
  local avail=len-dataOff
  local nColors=math.floor(math.min(avail,dataBytes)/2)
  assert(nColors>0,"Palette has 0 colors.")
  local cols={}
  for i=0,nColors-1 do
    local w=u16le(bytes,palStart+i*2)
    cols[#cols+1]=ds555_to_color(w)
  end
  return{bits=bits,colors=cols}
end

-- dialog with count/bank mode
local function prompt_count_or_bank(totalColors,bits)
  local banks=math.max(1,math.floor(totalColors/16))
  local d=Dialog{title="NCLR Import Options"}

  local function toggle(mode)
    d:modify{id="count",enabled=(mode=="count")}
    d:modify{id="startbank",enabled=(mode=="count")}
    d:modify{id="bank",enabled=(mode=="bank")}
  end

  d:label{id="info",label="Detected",text=string.format("%d colors • %dbpp",totalColors,bits)}

  -- bank dropdown options
  local bankOptions={}
  for i=0,banks-1 do
    local a=i*16; local bnd=math.min(totalColors-1,a+15)
    bankOptions[#bankOptions+1]=string.format("Bank %d [%d..%d]",i,a,bnd)
  end

  d:radio{id="mode_count",text="By color count",selected=true,
          onclick=function()toggle("count")end}
  d:number{id="count",label="Count",text=tostring(totalColors),decimals=0,enabled=true}
  d:combobox{id="startbank",label="Start bank",options=bankOptions,option=bankOptions[1],enabled=true}

  d:radio{id="mode_bank",text="By 16-color bank",onclick=function()toggle("bank")end}
  d:combobox{id="bank",label="Bank",options=bankOptions,option=bankOptions[1],enabled=false}

  local result = nil
  d:button{id="ok",text="OK",focus=true,onclick=function()
    local data=d.data
    if data.mode_count then
      local count=tonumber(data.count)or 0
      local startIdx=tonumber(string.match(data.startbank or "","^Bank%s+(%d+)"))or 0
      local start=startIdx*16
      if count<1 or count>totalColors then
        app.alert{title="Invalid count",text=string.format("Enter 1–%d.",totalColors)}
        return
      end
      if (start+count)>totalColors then
        app.alert{
          title="Range error",
          text=string.format(
            "With selected starting bank, max count can be %d",
            totalColors - start)
        }
        return
      end
      result={mode="count",count=count,startBank=startIdx}
      d:close()
    else
      local idx=tonumber(string.match(data.bank or "","^Bank%s+(%d+)"))or 0
      result={mode="bank",bank=idx}
      d:close()
    end
  end}
  d:button{id="cancel",text="Cancel",onclick=function()
    result = nil
    d:close()
  end}
  d:show()
  return result
end

-- MAIN
local pick=Dialog{title="Import NCLR Palette"}
local selectedPath = nil
pick:file{id="nclr",label="NCLR file",open=true,filetypes={"nclr","rlcn"}}
pick:button{id="ok",text="Next",focus=true,onclick=function()
  local data = pick.data
  local p = data and data.nclr
  if not p or p=="" then
    app.alert{title="NCLR Import",text="Please choose a .nclr/.rlcn file."}
    return -- keep dialog open
  end
  selectedPath = p
  pick:close()
end}
pick:button{id="cancel",text="Cancel",onclick=function()
  selectedPath = nil
  pick:close()
end}
pick:show()

local path = selectedPath
if not path then return end

local ok,parsed=pcall(read_nclr_palette,path)
if not ok then app.alert{title="NCLR Import",text=tostring(parsed)};return end

local choice=prompt_count_or_bank(#parsed.colors,parsed.bits)
if not choice then return end

-- select colors
local colorsToImport={}
if choice.mode=="count" then
  local start=choice.startBank*16
  for i=start+1,start+choice.count do
    table.insert(colorsToImport,parsed.colors[i])
  end
else
  local start=choice.bank*16
  local finish=math.min(#parsed.colors,start+16)
  for i=start+1,finish do
    table.insert(colorsToImport,parsed.colors[i])
  end
end

-- apply palette
local pal=Palette(#colorsToImport)
for i=0,#colorsToImport-1 do pal:setColor(i,colorsToImport[i+1]) end
local spr=app.activeSprite or Sprite(1,1)
app.transaction(function()spr:setPalette(pal)end)
app.alert{
  title="NCLR Import",
  text=(choice.mode=="count"
        and string.format("Imported %d color(s) from start bank %d.",#pal,choice.startBank)
        or string.format("Imported %d color(s) from bank %d.",#pal,choice.bank))
}
