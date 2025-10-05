-- ExportNCLR.lua
-- Export current palette to Nintendo DS NCLR/RLCN file

-- Part of Aseprite Nitro Plugins (https://github.com/RavenDS/Aseprite-Nitro-Plugins)
-- by ravenDS

-- helpers
local function le16(v)
  local lo = v & 0xFF
  local hi = (v >> 8) & 0xFF
  return string.char(lo, hi)
end

local function le32(v)
  local b0 = v        & 0xFF
  local b1 = (v >> 8) & 0xFF
  local b2 = (v >>16) & 0xFF
  local b3 = (v >>24) & 0xFF
  return string.char(b0, b1, b2, b3)
end

local function rgb_to_ds555(r, g, b)
  local r5 = math.floor(r * 31 / 255 + 0.5)
  local g5 = math.floor(g * 31 / 255 + 0.5)
  local b5 = math.floor(b * 31 / 255 + 0.5)
  if r5 < 0 then r5 = 0 elseif r5 > 31 then r5 = 31 end
  if g5 < 0 then g5 = 0 elseif g5 > 31 then g5 = 31 end
  if b5 < 0 then b5 = 0 elseif b5 > 31 then b5 = 31 end
  local w = (b5 << 10) | (g5 << 5) | r5
  return le16(w)
end

-- build file from palette
-- fileMagic: RLCN or NCLR
-- bomVal: FE FF (RLCN), FF FE (NCLR)
-- tagFourCC: "TTLP" (RLCN) or "PLTT" (NCLR)
local function build_from_palette(colors, bits, fileMagic, bomVal, tagFourCC, addPMCP)
  local origN = #colors
  if origN > 256 then origN = 256 end
  local pad = (16 - (origN % 16)) % 16
  local total = origN + pad
  if total > 256 then total = 256 end

  local pal_bytes = {}
  for i = 1, origN do
    local c = colors[i]
    pal_bytes[#pal_bytes+1] = rgb_to_ds555(c.red, c.green, c.blue)
  end
  for _ = 1, pad do
    pal_bytes[#pal_bytes+1] = rgb_to_ds555(0, 0, 0)
  end
  local pal_blob = table.concat(pal_bytes)

  -- PLTT/TTLP payload
  local bitsCode = (bits == 4) and 3 or 4
  local dataBytes = #pal_blob
  local dataOffset = 0x10
  local payload = table.concat({
    le32(bitsCode),
    le32(0),               -- extPalette = 0
    le32(dataBytes),
    le32(dataOffset),
    pal_blob
  })
  local mainBlock = table.concat({ tagFourCC, le32(8 + #payload), payload })

  -- optional PMCP footer
  local blocks = { mainBlock }
  if addPMCP then
    -- pcmpColorNum = colourNum / (bitdepth==4 ? 16 : 256)
    -- block FourCC: RLCN -> "PMCP", NCLR -> "PCMP"
    -- block size = 16 + pcmpColorNum*2
    -- payload after size:
    --   +0x08: u16 count (pcmpColorNum)
    --   +0x0A: u16 0xBEEF
    --   +0x0C: u32 0x00000008
    --   +0x10: u16 indices [0..count-1]
    local colours = total -- already padded to bank boundary
    local perBank = (bits == 4) and 16 or 256
    local pcmpColorNum = math.floor(colours / perBank)
    if pcmpColorNum < 1 then pcmpColorNum = 1 end

    local fourcc = (fileMagic == "RLCN") and "PMCP" or "PCMP"

    -- header fields after the 8-byte block header
    local headerPayload = table.concat({
      le16(pcmpColorNum),   -- count
      le16(0xBEEF),         -- magic per C code
      le32(0x00000008)      -- constant 8
    })

    -- u16 indices 0..count-1
    local idx = {}
    for i = 0, pcmpColorNum-1 do
      idx[#idx+1] = le16(i)
    end
    local idxBlob = table.concat(idx)

    local fullPayload = headerPayload .. idxBlob
    local blockSize = 8 + #fullPayload -- matches C: 16 + count*2

    local pcmpBlock = table.concat({
      fourcc,
      le32(blockSize),
      fullPayload
    })
    blocks[#blocks+1] = pcmpBlock
  end

  local nBlocks = #blocks
  local head = table.concat({
    fileMagic,
    le16(bomVal),
    le16(0x0100),
    le32(0),
    le16(0x0010),
    le16(nBlocks)
  })

  local blob = head .. table.concat(blocks)
  local totalSize = #blob
  blob = table.concat({ blob:sub(1,8), le32(totalSize), blob:sub(13) })
  return blob, total
end

-- dialog
local function show_export_dialog()
  local d = Dialog{ title="Export NCLR/RLCN" }
  d:radio{ id="bpp4", label="Mode", text="4bpp", selected=true }
  d:radio{ id="bpp8", text="8bpp" }

  d:combobox{
    id="ftype", label="Type",
    options={"RLCN","NCLR"}, option="RLCN",
    onchange=function()
      local newType = d.data.ftype
      if newType == "NCLR" then
        d:modify{id="out", filename="palette.nclr"}
      else
        d:modify{id="out", filename="palette.rlcn"}
      end
    end
  }

  d:check{ id="pmcp", label="Footer", text="Append optional PMCP footer", selected=false }
  d:file{ id="out", label="Output", save=true, filename="palette.rlcn", filetypes={"nclr","rlcn"} }
  d:button{ id="ok", text="Export", focus=true }
  d:button{ id="cancel", text="Cancel" }
  d:show()

  local data = d.data
  if not data or data.cancel then return nil end
  if not data.out or data.out == "" then
    app.alert{ title="Export NCLR/RLCN", text="Please choose an output file." }
    return nil
  end

  local bits = data.bpp8 and 8 or 4
  local ftype = (data.ftype == "NCLR") and "NCLR" or "RLCN"

  local fileMagic, bomVal, tagFourCC
  if ftype == "RLCN" then
    fileMagic = "RLCN"
    bomVal = 0xFEFF
    tagFourCC = "TTLP"
  else
    fileMagic = "NCLR"
    bomVal = 0xFFFE
    tagFourCC = "PLTT"
  end

  return {
    bits = bits,
    ftype = ftype,
    fileMagic = fileMagic,
    bomVal = bomVal,
    tag = tagFourCC,
    pmcp = (data.pmcp and true or false),
    out = data.out
  }
end

-- MAIN
local spr = app.activeSprite
if not spr then
  app.alert{ title="Export NCLR/RLCN", text="No active sprite. Open or create a sprite to export its palette." }
  return
end

local pal = spr.palettes[1] or spr.palette
local palSize = #pal
if palSize == 0 then
  app.alert{ title="Export NCLR/RLCN", text="Current palette is empty." }
  return
end

local colors = {}
local maxc = math.min(palSize, 256)
for i = 0, maxc-1 do
  colors[#colors+1] = pal:getColor(i)
end
if palSize > 256 then
  app.alert{ title="Export NCLR/RLCN", text="Palette has more than 256 colors; extra colors will be truncated." }
end

local opts = show_export_dialog()
if not opts then return end

local blob, totalWritten = build_from_palette(
  colors, opts.bits, opts.fileMagic, opts.bomVal, opts.tag, opts.pmcp
)

local f, err = io.open(opts.out, "wb")
if not f then
  app.alert{ title="Export NCLR/RLCN", text=("Cannot write file:\n%s"):format(tostring(err)) }
  return
end
f:write(blob)
f:close()

app.alert{
  title="Export NCLR/RLCN",
  text=string.format(
    "Exported %d color(s) (padded to multiple of 16) as %dbpp, Type=%s, Block=%s%s:\n%s",
    totalWritten, opts.bits, opts.ftype, opts.tag,
    (opts.pmcp and " + PMCP" or ""), opts.out
  )
}
