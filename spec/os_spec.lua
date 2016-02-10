describe('lift.os', function()

  local WAIT = 100 -- how much to wait for a process to finish
  if os.getenv('CI') then
    WAIT = 300
  end

  local os = require 'lift.os'
  local ls = require 'lift.string'
  local async = require 'lift.async'
  local config = require 'lift.config'
  local su = require 'spec.util'

  it('offers try_sh() to try to execute a shell command', su.async(function()
    local out, err = assert(os.sh'echo Hello world!|cat')
    assert.equal('Hello world!\n', out)
    assert.equal('', err)

    out, err = assert(os.sh[[lua -e "io.write'Hello from stdout'"]])
    assert.equal('Hello from stdout', out)
    assert.equal('', err)

    out, err = assert(os.sh[[lua -e "io.stderr:write'Hello from stderr'"]])
    assert.equal('', out)
    assert.equal('Hello from stderr', err)

    out, err = os.try_sh'invalid_cmd error'
    assert.Nil(out)
    assert.match('shell command failed', err)
  end))

  it("offers sh() to execute a shell command or raise an error", su.async(function()
    os.sh'echo Hello'
    assert.error_match(function() os.sh'invalid_cmd error' end,
      'shell command failed with status')
  end))

  describe("child processes", function()

    it("can be started with spawn()", su.async(function()
      local c = assert(os.spawn{file = config.LUA_EXE_PATH, '-e', 'os.exit(7)',
        stdin = 'ignore', stdout = 'ignore', stderr = 'ignore'})
      assert.is_number(c.pid)
      assert.is_nil(c.status)
      assert.is_nil(c.signal)
      async.sleep(WAIT)
      assert.equal(7, c.status)
      assert.equal(0, c.signal)
    end))

    it("can be terminated with :kill()", su.async(function()
      local c = assert(os.spawn{file = 'sleep', '3',
        stdin = 'ignore', stdout = 'ignore', stderr = 'ignore'})
      assert.is_number(c.pid)
      assert.is_nil(c.status)
      assert.is_nil(c.signal)
      c:kill()
      async.sleep(WAIT)
      assert.equal(15, c.signal) -- sigterm
      assert.error(function() c:kill() end,
        'process:kill() called after process termination')
    end))

    it("can inherit fds from parent and be waited for", su.async(function()
      local c = assert(os.spawn{file = config.LUA_EXE_PATH,
        '-e', 'print[[Hello from child process]]',
        stdin = 'ignore', stdout = 'inherit', stderr = 'inherit'})
      assert.Nil(c.status)
      c:wait()
      assert.equal(0, c.status, c.signal)
    end))

    it("can be waited for with a timeout", su.async(function()
      -- with enough time
      local c = assert(os.spawn{file = config.LUA_EXE_PATH,
        '-e', 'print[[this is fast]]',
        stdin = 'ignore', stdout = 'ignore', stderr = 'ignore'})
      assert.Nil(c.status)
      local status, signal = c:wait(300)
      assert.equal(0, status, signal)
      -- without enough time
      c = assert(os.spawn{file = 'sleep', '5',
        stdin = 'ignore', stdout = 'ignore', stderr = 'ignore'})
      assert.Nil(c.status)
      status, signal = c:wait(300)
      c:kill()
      assert.False(status)
      assert.equal(signal, 'timed out')
    end))

    it("can be read from (stdout, stderr)", su.async(function()
      local c = assert(os.spawn{file = config.LUA_EXE_PATH,
        '-e', 'print[[Hello world]]', stdin = 'ignore'})
      assert.Nil(c:try_read())
      assert.Nil(c.stderr:try_read())
      c:wait() -- await exit before reading
      assert.equal('Hello world\n', ls.native_to_lf(c:try_read()))
      assert.Nil(c.stderr:try_read())
    end))

    it("can be written to (stdin) and read from (stdout)", su.async(function()
      local c = assert(os.spawn{file = 'cat'})
      c:write('One')
      c.stdin:write('Two')
      c:write() -- shuts down stdin, causing 'cat' to exit
      assert.Nil(c.stdout:try_read())
      assert.Nil(c.stderr:try_read())
      c:wait() -- await exit before reading
      local sb = {c:try_read()}
      sb[#sb+1] = c:try_read()
      assert.equal('OneTwo', table.concat(sb))
      assert.Nil(c.stderr:try_read())
    end))

    it("can be written to (stdin) and read from (stderr)", su.async(function()
      local c = assert(os.spawn{file = 'lua',
          '-e', 'io.stderr:write(io.read())', stdout = 'ignore'})
      c:write('Hello from stderr')
      c:write() -- shuts down stdin, causing the process to exit
      assert.Nil(c.stdout)
      assert.Nil(c.stderr:try_read())
      c:wait() -- await exit before reading
      assert.equal('Hello from stderr', c.stderr:try_read())
    end))

    it("can be written to (stdin) and read from (stdout) synchronously", su.async(function()
      local c = assert(os.spawn{file = 'cat'})
      c:write('One')
      c.stdin:write('Two')
      assert.equal('OneTwo', c:read())
      c:write('Three')
      assert.equal('Three', c:read())
      c:write()
      assert.Nil(c:read())
      assert.Nil(c.stderr:read())
    end))

    it("can be piped to another process", su.async(function()
      local echo1 = assert(os.spawn{file = config.LUA_EXE_PATH,
        '-e', 'io.write[[OneTwoThree]]', stdin = 'ignore'})
      local echo2 = assert(os.spawn{file = config.LUA_EXE_PATH,
        '-e', 'io.write[[FourFive]]', stdin = 'ignore'})
      local cat1 = assert(os.spawn{file = 'cat'})
      local cat2 = assert(os.spawn{file = 'cat'})
      cat1:pipe(cat2)
      echo1:pipe(cat1, true) -- pipe to cat1 and keep cat1 open
      echo1.stdout:wait_end()
      echo2:pipe(cat1) -- pipe to cat1 and shut down cat1
      echo2.stdout:wait_end()
      local sb = {cat2:read()}
      sb[#sb+1] = cat2:read()
      assert.equal('OneTwoThreeFourFive', table.concat(sb))
    end))

  end)

end)
