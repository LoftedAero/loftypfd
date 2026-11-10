-- Byte and bit-field reading.
--
-- The core runs on Lua 5.3 (EdgeTX 2.11 and later) and 5.4 (Ethos), so it
-- uses the native integer operators. EdgeTX builds Lua with 32-bit integers
-- and single-precision floats: a 32-bit word divided as a float loses its
-- low bits, and integer arithmetic wraps at 2^31. Everything here stays in
-- integer operations and masks to 32 bits, which gives the same result with
-- 32-bit integers (EdgeTX) and 64-bit ones (Ethos).

local M = {}

local MASK32 = 0xFFFFFFFF

--- Unsigned field of `width` bits starting at bit `offset` of `v`.
function M.field(v, offset, width)
  return ((v & MASK32) >> offset) & ((1 << width) - 1)
end

--- Whether bit `bit` of `v` is set.
function M.flag(v, bit)
  return (v >> bit) & 1 == 1
end

--- The low `width` bits of `v` read as a two's-complement number.
function M.signed(v, width)
  local sign = 1 << (width - 1)
  return ((v & ((sign << 1) - 1)) ~ sign) - sign
end

-- Byte arrays are Lua tables of 0-255, indexed from `i`.

function M.u16be(b, i)
  return b[i] << 8 | b[i + 1]
end

function M.i16be(b, i)
  return M.signed(M.u16be(b, i), 16)
end

function M.u24be(b, i)
  return b[i] << 16 | b[i + 1] << 8 | b[i + 2]
end

--- A 32-bit word as its bit pattern; with 32-bit integers it may print
--- negative, which the field readers above do not mind.
function M.u32be(b, i)
  return b[i] << 24 | b[i + 1] << 16 | b[i + 2] << 8 | b[i + 3]
end

function M.i32be(b, i)
  return M.signed(M.u32be(b, i), 32)
end

function M.u16le(b, i)
  return b[i] | b[i + 1] << 8
end

function M.u32le(b, i)
  return b[i] | b[i + 1] << 8 | b[i + 2] << 16 | b[i + 3] << 24
end

--- Bytes of a 32-bit value, big-endian, appended to `out`.
function M.put32be(out, v)
  out[#out + 1] = (v >> 24) & 0xFF
  out[#out + 1] = (v >> 16) & 0xFF
  out[#out + 1] = (v >> 8) & 0xFF
  out[#out + 1] = v & 0xFF
  return out
end

--- A zero-terminated string starting at `i`; returns it and the index after
--- the terminator. A string with no terminator runs to the end of `b`.
function M.cstring(b, i)
  local j, n = i, #b
  while j <= n and b[j] ~= 0 do
    j = j + 1
  end
  -- One call for the whole string: per character it cost a status-text
  -- frame several hundred instructions of EdgeTX's budget.
  return string.char(table.unpack(b, i, j - 1)), j + 1
end

return M
