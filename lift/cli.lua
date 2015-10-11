-------------------------------------------------------------------------------
-- Simple, composable Command-Line Interfaces with command hierarchies
-------------------------------------------------------------------------------

local config = require 'lift.config'
local diagnostics = require 'lift.diagnostics'
local to_bool = require('lift.string').to_bool

-------------------------------------------------------------------------------
-- Option (an optional value specified for a command)
-------------------------------------------------------------------------------

local Option = {
  name = 'unknown', -- option name
  is_flag = false,  -- whether the option is a flag (boolean)
}
Option.__index = Option

local function new_option(cmd, name, is_flag)
  return setmetatable({ cmd = cmd, name = name, is_flag = is_flag }, Option)
end

-- called with bool or string; returns nil on success, string on error
function Option:__call(value) return self:matched(value) end
function Option:matched(value) self.value = value end
function Option:action(f) self.matched = f ; return self end

-- first and second columns of the option help line
-- for example: opt:desc('-h, --help', 'Print help and exit')
function Option:desc(usage, short_desc)
  self.help_usage = usage ; self.help_short = short_desc ; return self
end

function Option:default(value) self.value = value ; return self end
function Option:alias(alias)
  self.help_alias = alias
  return self.cmd:add_option(alias, self)
end

-------------------------------------------------------------------------------
-- Command (has options, subcommands and an action)
-------------------------------------------------------------------------------

local Command = {
  name = '',      -- command name (the empty string is the root command)
  options = {},   -- map of options [string: alias or action]
  commands = {},  -- map of subcommands [string: alias or subcommand]
}
Command.__index = Command

local function new_cmd(parent, name)
  if parent and parent.parent then name = parent.name .. ' ' .. name end
  return setmetatable({ parent = parent, name = name, options = {},
    commands = {} }, Command)
end

-- called with a string list; return nil on success, string on error
function Command:__call(args) self.args = args ; return self:run() end

-- the default action for all commands is to print help and exit
local function help(cmd)
  io.stdout:write(table.unpack(cmd:get_help()))
  os.exit(true)
end
function Command:action(f) self.run = f ; return self end
Command:action(help)

Command.desc = Option.desc
function Command:epilog(text) self.help_long = text ; return self end
function Command:get(option_name)
  local opt = self.options[option_name]
  if not opt then error("no such option '"..option_name.."'") end
  return opt.value
end
function Command:alias(alias)
  return self.parent:add_command(alias, self)
end
function Command:add_option(name, option) -- adds an existing option
  if self.options[name] then
    error("redefinition of option '"..name.."'", 2)
  end
  self.options[name] = option
  return option
end
function Command:add_command(name, command) -- adds an existing command
  if self.commands[name] then
    error("redefinition of command '"..name.."'", 2)
  end
  self.commands[name] = command
  return command
end
function Command:flag(name) -- defines a new flag
  return self:option(name, true)
end
function Command:option(name, is_flag) -- defines a new option
  assert(type(name) == 'string' and #name > 0)
  return self:add_option(name, new_option(self, name, is_flag))
end
function Command:command(name) -- defines a new subcommand
  assert(type(name) == 'string' and #name > 0)
  return self:add_command(name, new_cmd(self, name))
end

-------------------------------------------------------------------------------
-- Command:consume(...) to read required command arguments
-------------------------------------------------------------------------------

local function _consume(self, args, used, name, ...)
  if not name then return end
  used = used + 1 ; args.used = used
  if used > #args then self:error('missing argument <${1}>', name) end
  return args[used], _consume(self, args, used, ...)
end

-- Usage: local a1, a2 = self:consume('<arg1>', '<arg2>')
function Command:consume(...)
  local args = assert(self.args, 'command was not called properly')
  local used = args.used ; if not used then used, args.used = 0, 0 end
  return _consume(self, args, used, ...)
end

-------------------------------------------------------------------------------
-- Process command-line arguments (Command:process)
-------------------------------------------------------------------------------

diagnostics.levels.cli_error = 'fatal'
diagnostics.styles.cli_error = {prefix = 'command-line error', fg = 'red'}

local function process_option(option, value, next_arg)
  local used_next = false
  if option.is_flag then
    local b = true
    if value then
      b = to_bool(value)
      if b == nil then return nil, "expected <bool>, got '"..value.."'" end
    end
    value = b
  else
    if not value then value, used_next = next_arg, true end
    if not value then return nil, 'missing argument' end
  end
  return used_next, option(value)
end

function Command:error(msg, ...)
  diagnostics.report{command = self, 'cli_error: '..msg, ...}
end

function Command:process(args)
  assert(type(args) == 'table', 'missing args')
  assert(self.parent == nil, 'not a root command')
  local opts, cmd_args, num_args, i, last = true, {}, 0, 1, #args
  while i <= last do
    local s, _, e, dash, key, op = args[i]
    if opts then _, e, dash, key, op = s:find('^(%-*)([^=]*)(=?)') end
    if not e or (dash == '' and op == '') then -- command arg
      local subcmd ; if num_args == 0 then subcmd = self.commands[s] end
      if subcmd then self = subcmd -- use subcommand instead
      else num_args = num_args + 1 ; cmd_args[num_args] = s end
    elseif s == '--' then opts = false  -- stop processing options
    else
      local option = self.options[key]
      if not option then
        local msg = 'unknown option ${1} for command ${2}'
        if not self.parent then msg = 'unknown option ${1}' end
        self:error(msg, dash..key, self.name)
      end
      local value ; if op ~= '' then value = s:sub(e + 1) end
      local used, err = process_option(option, value, args[i + 1])
      if err then self:error('option ${1}: ${2}', dash..key, err)
      elseif used then i = i + 1 end
    end
    i = i + 1
  end
  cmd_args[0] = self.name
  local err = self(cmd_args)
  if err then self:error('${1}', err) end
  local used = cmd_args.used
  if used and used < #cmd_args then
    diagnostics.report("warning: unused argument '${1}'", cmd_args[used + 1])
  end
end

-------------------------------------------------------------------------------
-- Help System
-------------------------------------------------------------------------------

local function root_epilog()
  return "Read about a specific subcommand via: "..
    config.EXE_NAME .. " help <command>\n"
end

-- if a help property is a function, it's called once to get a string
local function expand(obj, prop)
  local v = obj[prop]
  if type(v) == 'function' then v = v(obj, prop) ; obj[prop] = v end
  return v
end

function Option:help_usage()
  local str = '--'..self.name
  if self.help_alias then str = '-'..self.help_alias..', '..str end
  return str
end

function Command:help_usage()
  return self.name ..
    (next(self.options) and ' [options]' or '') ..
    (next(self.commands) and ' <command> [<args>]' or '')
end

-- extracts a list from the cmd.options and cmd.commands tables
local function name_comparator(a,b) return a.name < b.name end
local function prepare(options_or_commands)
  local t, width = {}, 0
  for _, v in pairs(options_or_commands) do
    if not t[v] then
      t[v] = true ; t[#t + 1] = v
      local usage = expand(v, 'help_usage')
      if usage then width = math.max(width, #usage) end
    end
  end
  table.sort(t, name_comparator)
  return t, width
end

local USAGE_MAX = 20 -- usage is omitted in some places if longer than this
local MARGIN_SIZE = 3 -- how many spaces between columns
local MARGIN = (' '):rep(MARGIN_SIZE)

local function add_usage(t, heading, list, width, limit)
  t[#t + 1] = heading
  local prop = 'help_usage' -- what we're going to print in the 1st column
  if width > limit then -- if usage is too long, try using only names
    width = 0
    for _, obj in ipairs(list) do
      if width < #obj.name then width = #obj.name end
    end
    if width <= limit then prop = 'name' end -- print only names
  end
  for i, obj in ipairs(list) do
    local first = expand(obj, prop)
    if first then
      t[#t + 1] = MARGIN ; t[#t + 1] = first
      local second = expand(obj, 'help_short')
      if second then
        if width > limit then -- print using two lines
          t[#t + 1] = '\n'..MARGIN..MARGIN
        else -- print using two columns
          t[#t + 1] = (' '):rep(width - #first + MARGIN_SIZE)
        end
        t[#t + 1] = second
      end
      if width > limit and i < #list then t[#t + 1] = '\n' end
      t[#t + 1] = '\n'
    end
  end
end

function Command:get_help()
  local options, opt_width = prepare(self.options)
  local commands, cmd_width = prepare(self.commands)
  local t = {'Usage:\n', MARGIN, config.EXE_NAME, ' '}
  if self.parent and self.parent.parent then -- add path to command
    t[#t + 1] = self.parent.name ; t[#t + 1] = ' '
  end
  local usage = expand(self, 'help_usage')
  t[#t + 1] = usage or self.name ; t[#t + 1] = '\n'
  local short = expand(self, 'help_short')
  if short then t[#t + 1] = '\n' ; t[#t + 1] = short ; t[#t + 1] = '\n' end
  -- options and subcommands
  if opt_width > 0 then
    add_usage(t, '\nOptions:\n', options, opt_width,
      math.max(opt_width, math.min(cmd_width, USAGE_MAX)))
  end
  if cmd_width > 0 then
    add_usage(t, '\nCommands:\n', commands, cmd_width,
      math.min(USAGE_MAX, math.max(opt_width, cmd_width)))
  end
  -- epilog
  local long = expand(self, 'help_long')
  if long then t[#t + 1] = '\n' ; t[#t + 1] = long end
  return t
end

-------------------------------------------------------------------------------
-- Module Functions
-------------------------------------------------------------------------------

-- default actions used by the root command
local function help_option(option) return help(option.cmd) end
local function help_command(command)
  local about, args = command.parent, command.args
  for _, name in ipairs(args) do
    about = about.commands[name]
    if not about then
      return "no help entry for '"..table.concat(args, ' ').."'"
    end
  end
  return help(about)
end

-- root command constructor
local function new()
  local app = new_cmd()
    :desc '[options] [key=value] <command> [<args>]'
    :epilog(root_epilog)

  app:command 'help' :action(help_command)
    :desc('help [command]', 'Print help for one command and exit')

  app:flag 'help' :alias 'h' :action(help_option)
    :desc('-h, --help', 'Print help information and exit')

  return app
end

-------------------------------------------------------------------------------
-- Module Table
-------------------------------------------------------------------------------

local M = {
  new = new,
}

return M
