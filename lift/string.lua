------------------------------------------------------------------------------
-- Utility String Manipulation Routines
------------------------------------------------------------------------------

local getmetatable, tostring, type = getmetatable, tostring, type
local str_find = string.find
local str_format = string.format
local str_gsub = string.gsub
local str_sub = string.sub
local str_upper = string.upper
local tbl_concat = table.concat
local keys_sorted_by_type = require('lift.utils').keys_sorted_by_type
local lpeg = require 'lpeg'
local P, R, V, Ca, Cs = lpeg.P, lpeg.R, lpeg.V, lpeg.Carg, lpeg.Cs

-- Returns the Capitalized form of a string
local function capitalize(str)
  return (str_gsub(str, '^%l', str_upper))
end

-- Returns the camelCase form of a string keeping the 1st word unchanged
local function camelize(str)
  return (str_gsub(str, '%W+(%w+)', capitalize))
end

-- Returns the UpperCamelCase form of a string
local function classify(str)
  return (str_gsub(str, '%W*(%w+)', capitalize))
end

-- Separates a camelized string by underscores, keeping capitalization
local function decamelize(str)
  return (str_gsub(str, '(%l)(%u)', '%1_%2'))
end

-- Replaces each word separator with a single dash
local function dasherize(str)
  return (str_gsub(str, '%W+', '-'))
end

local BOOLEANS = {
  ['1'] = true, ON = true, TRUE = true, Y = true, YES = true,
  ['0'] = false, FALSE = false, N = false, NO = false, OFF = false,
}

-- Returns true/false for well-defined bool constants, or nil otherwise
local function to_bool(str)
  return BOOLEANS[str_upper(str)]
end

-- Escapes any "magic" character in str for use in a Lua pattern.
local function escape_magic(str)
  return (str_gsub(str, '[$^%().[%]*+-?]', '%%%1'))
end

-- Converts a file globbing pattern to a Lua pattern. Supports '**/', '*', '?'
-- and Lua-style [character sets]. Note that '**' must always precede a '/'.
-- Does not support escaping with '\', use charsets instead: '[*?]'.
local glob_to_lua = { ['^'] = '%^', ['$'] = '%$', ['%'] = '%%',
  ['('] = '%(', [')'] = '%)', ['.'] = '%.', ['['] = '%[', [']'] = '%]',
  ['+'] = '%+', ['-'] = '%-', ['?'] = '[^/]', ['*'] = '[^/]*' }
local function from_glob(glob)
  -- copy [charsets] verbatim; translate magic chars everywhere else
  local i, res = 1, ''
  repeat
    local s, e, charset = str_find(glob, '(%[.-%])', i)
    local before = str_sub(glob, i, s and s - 1)
    res = res..str_gsub(before, '[$^%().[%]*+-?]', glob_to_lua)..(charset or '')
    i = e and e + 1
  until not i
  -- handle '**/' as a last gsub pass
  return (str_gsub(res, '%[^/]%*%[^/]%*/', '.*/'))
end

------------------------------------------------------------------------------
-- String Interpolation (recursive variable expansions using LPeg)
------------------------------------------------------------------------------

local VB, VE = P'${', P'}'
local INTEGER = R'09'^1 / tonumber
local function map_var(f, m, k)
  local v = f(m, k)
  if not v then v = '${MISSING:'..k..'}' end
  return tostring(v)
end
local Xpand = P{
  Cs( (1-VB)^0 * V'Str' * P(1)^0 ),
  Str = ( (1-VB-VE)^1 + V'Var' )^1,
  Var = Ca(1) * Ca(2) * VB * (INTEGER*VE + Cs(V'Str')*VE) / map_var
}

local function index_table(t, k) return t[k] end -- default var_f

-- Replaces '${vars}' with the result of var_f(var_table, 'varname').
-- If var_f is omitted, var_table must be a table with string/integer keys.
local function expand(str, var_table, var_f)
  return lpeg.match(Xpand, str, nil, var_f or index_table, var_table) or str
end

------------------------------------------------------------------------------
-- String Formatting
------------------------------------------------------------------------------

-- Pretty formats an elementary value into a string.
local function format_value(v, tp)
  if (tp or type(v)) == 'string' then
    return str_format('%q', v)
  else
    return tostring(v)
  end
end

-- Pretty formats a value into a string for indexing a table.
local function format_key(v)
  local tp = type(v)
  if tp == 'string' and str_find(v, '^[%a_][%w_]*$') then
    return v, true
  end
  return '['..format_value(v, tp)..']'
end

-- Pretty formats a flat list of values into a string.
-- Returns nil if the list contains nested tables, or if the resulting
-- string would be longer than max_len (optional).
local function format_flat_list(t, max_len)
  local str, sep = '', ''
  for i = 1, #t do
    local v = t[i]
    local tp = type(v)
    if tp == 'table' then return end -- not flat!
    str = str..sep..format_value(v, tp)
    if max_len and #str > max_len then return end -- too long
    sep = ', '
  end
  return str
end

-- Pretty formats a flat table into a string.
-- Returns nil if `t` contains nested tables, or if the resulting
-- string would be longer than max_width (optional).
local function format_flat_table(t, max_len, keys)
  keys = keys or keys_sorted_by_type(t)
  local str, sep = '', ''
  for i = 1, #keys do
    local k = keys[i]
    local v = t[k]
    local tp = type(v)
    if tp == 'table' then return end -- oops, not flat!
    local vs = format_value(v, tp)
    if k == i then
      str = str..sep..vs
    else
      str = str..sep..format_key(k)..' = '..vs
    end
    if max_len and #str > max_len then return end -- too long
    sep = ', '
  end
  return str
end

-- Pretty formats any variable into a string buffer. Handles tables and cycles.
local function sb_format(sb, name, t, indent, max_len)
  -- handle plain values
  local tp = type(t)
  if tp ~= 'table' then
    sb[#sb+1] = format_value(t, tp)
    return
  end
  -- solve cycles
  if sb[t] then
    sb[#sb+1] = sb[t]
    return
  end
  -- handle nested tables
  sb[t] = name
  sb[#sb+1] = '{'
  local keys = keys_sorted_by_type(t)
  if #keys > 0 then
    local ml = max_len - #indent
    local flat = (#keys == #t and
      format_flat_list(t, ml) or format_flat_table(t, ml, keys))
    if flat then
      sb[#sb+1] = flat
    else
      sb[#sb+1] = '\n'
      local new_indent = indent..'  '
      for i = 1, #keys do
        local k = keys[i]
        local v = t[k]
        local fk, as_id = format_key(k)
        sb[#sb+1] = new_indent
        sb[#sb+1] = fk
        sb[#sb+1] = ' = '
        sb_format(sb, name..(as_id and '.'..fk or fk), v, new_indent, max_len)
        sb[#sb+1] = ',\n'
      end
      sb[#sb+1] = indent
    end
  end
  sb[#sb+1] = '}'
end

-- Pretty formats any variable into a string. Handles tables and cycles.
-- Treats objects with the __tostring metamethod as regular tables.
local function format_table(value, max_len)
  local sb = {}
  sb_format(sb, '@', value, '', max_len or 78)
  return tbl_concat(sb)
end

-- Pretty formats any variable into a string. Handles objects, tables and cycles.
-- Uses the __tostring metamethod to format objects that implement it.
local function format(value, max_len)
  local mt = getmetatable(value)
  if mt and mt.__tostring then return tostring(value) end
  return format_table(value, max_len)
end

------------------------------------------------------------------------------
-- Module Table
------------------------------------------------------------------------------

local M = {
  camelize = camelize,
  capitalize = capitalize,
  classify = classify,
  dasherize = dasherize,
  decamelize = decamelize,
  escape_magic = escape_magic,
  expand = expand,
  format = format,
  format_flat_list = format_flat_list,
  format_flat_table = format_flat_table,
  format_key = format_key,
  format_table = format_table,
  format_value = format_value,
  from_glob = from_glob,
  to_bool = to_bool,
}

return M
