-- These tasks will fetch the list of all official Lua releases, select
-- the latest release in branches 5.3, 5.2 and 5.1, and download and
-- build these releases in parallel.

local fs = require 'lift.fs'
local task = require 'lift.task'
local async = require 'lift.async'
local stream = require 'lift.stream'
local request = require 'lift.request'
local diagnostics = require 'lift.diagnostics'
local sh = require'lift.os'.sh

-- Returns the contents of a web page
function task.fetch_page(url)
  local buf = {}
  request(url):pipe(stream.to_array(buf)):wait_finish()
  return table.concat(buf)
end

-- Returns a sorted list of Lua releases (also a map: version => release)
function task.get_lua_releases()
  local t = {}
  local url = 'http://www.lua.org/ftp/'
  local html = task.fetch_page(url)
  for f, v in html:gmatch[[HREF="(lua%-([%d.]+)%.tar%.gz)"]] do
    if not t[v] then
      local release = {version = v, filename = f, url = url..f}
      t[v] = release
      t[#t+1] = release
    end
  end
  return t
end

-- Returns the abs path to a subdir created with the given name
function task.get_dir(name)
  local dir = fs.cwd()..'/'..name
  fs.mkdir(dir)
  return dir
end

-- Downloads a Lua release archive (tar.gz)
function task.download(release)
  print('Downloading '..release.url)
  local dest = task.get_dir('archives')..'/'..release.filename
  request(release.url):pipe(fs.write_to(dest)):wait_finish()
  return dest
end

-- helper function to print the elapsed time
local function get_elapsed(t0)
  return string.format('%.2fs', (async.now() - t0) / 1000)
end

-- Downloads and builds a given Lua release
function task.build_release(release)
  local t0 = async.now()
  local filename = task.download(release)
  sh('tar -xzf '..filename)
  sh('cd lua-'..release.version..' && make generic > build.log')
  print('Lua '..release.version..' built in '..get_elapsed(t0))
end

-- Given a list of version strings, builds a set of Lua releases in parallel
function task.build_versions(versions)
  local t0 = async.now()
  local releases = task.get_lua_releases()
  local futures = {}
  for i, version in ipairs(versions) do
    if version:sub(1, 1) ~= '5' then
      diagnostics.report('fatal: version must be >= 5.x (${1} is too old)',
        version)
    end
    local release = releases[version]
    if not release then
      diagnostics.report("fatal: no such release '${1}'", version)
    end
    futures[#futures+1] = task.build_release:async(release)
  end
  async.wait_all(futures)
  print('Total time '..get_elapsed(t0))
end

-- Determines the latest Lua release versions in multiple 5.x branches
-- and calls build_versions to build them in parallel
function task.default()
  local releases = task.get_lua_releases()
  local branches = {
    ['5.3'] = true,
    ['5.2'] = true,
    ['5.1'] = true,
  }
  local versions = {}
  for i, release in ipairs(releases) do
    local branch = release.version:sub(1, 3)
    if branches[branch] then
      print('Latest '..branch..' release is '..release.version)
      branches[branch] = nil
      versions[#versions+1] = release.version
    end
  end
  task.build_versions(versions)
end
