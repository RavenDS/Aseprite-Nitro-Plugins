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

  -- optional PMCP footer (experimental)
  local blocks = { mainBlock }
  if addPMCP then
    local banks = math.floor(total / 16)
    local nonEmpty = {}
    for b = 0, banks - 1 do
      local base = b * 16 * 2
      local any = false
      for j = 0, 15 do
        local o = base + j*2
        local lo = pal_blob:byte(o+1) or 0
        local hi = pal_blob:byte(o+2) or 0
        if (lo | (hi << 8)) ~= 0 then any = true break end
      end
      nonEmpty[b] = any
    end

    local startBank = 0
    if (banks > 1) and nonEmpty[1] then
      startBank = 1
    else
      for b = 0, banks - 1 do
        if nonEmpty[b] then startBank = b break end
      end
    end

    local pmcp_head = table.concat({
      le16(banks),
      le16(0xBEEF),
      le32(math.floor(dataOffset/2)),
      le32(startBank << 16)
    })

    local lst = {}
    for b = 0, banks - 1 do
      if nonEmpty[b] and (b ~= startBank) then
        lst[#lst+1] = le16(b + 1)
      end
    end

    local pmcpPayload = pmcp_head .. table.concat(lst)
    local pmcpBlock = table.concat({ "PMCP", le32(8 + #pmcpPayload), pmcpPayload })
    blocks[#blocks+1] = pmcpBlock
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

  d:check{ id="pmcp", label="Footer", text="Append optional PMCP (experimental)", selected=false }
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
