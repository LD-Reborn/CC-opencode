-- The generated installer, run against the mock.
--
-- `install.lua` is a host program, so what is under test is the artifact it
-- writes: `dist/install.lua`. Running it here means the fetch loop, the size
-- check, the directory creation, and the argument handling are all exercised the
-- way a computer would exercise them.

return function(t, mock)
  t.suite("install")

  local env = require("environment")

  local installerPath = t.root .. "/dist/install.lua"

  --- The installer's own file list, as the paths it will fetch.
  local paths = {}
  for path in (env.read(installerPath) or ""):gmatch('{ "([^"]+)", %d+,') do
    paths[#paths + 1] = path
  end

  --- A queue of `probe` answers, then a 200 carrying the real file for each of
  -- `wanted`.
  --
  -- Built by hand because a call in the middle of a table constructor expands to
  -- one value rather than to everything it returns, which reads exactly like the
  -- list and is not.
  --
  -- The bodies are the repository's own files rather than placeholders of the
  -- right length: the installer compares sizes, and a fabricated body of the
  -- right size would let a test pass without proving the right file arrived.
  local function queue(probe, repo, wanted)
    local out = {}
    for _, response in ipairs(probe or {}) do
      out[#out + 1] = response
    end
    for _, path in ipairs(wanted or {}) do
      out[#out + 1] = { status = 200, body = env.read(repo .. "/" .. path) or "" }
    end
    return out
  end

  --- The answers a probe costs when it succeeds on the first candidate.
  local function found(wanted)
    return queue({ { status = 200, body = env.read(t.root .. "/" .. wanted[1]) or "" } }, t.root, wanted)
  end

  --- Run the generated installer with the arguments a shell would pass.
  --
  -- `repo` and `branch` replace the ones baked in by `install.lua`, so the
  -- candidate urls can be tried for hosts this checkout is not on. The queue has
  -- to be built after `mock.setup()`, which wipes the mock filesystem, so both
  -- the responses and the rewritten file come in as arguments.
  --
  -- The installer returns a status instead of calling `os.exit`, which
  -- ComputerCraft does not have, so the return value is the status.
  local function installer(args, responses, repo, branch, failure)
    mock.setup()
    local path = installerPath
    if repo then
      local source = env.read(installerPath):gsub('local REPO = "[^"]*"', "local REPO = " .. string.format("%q", repo), 1)
      source = source:gsub(
        'local BRANCH = "[^"]*"',
        "local BRANCH = " .. string.format("%q", branch or "main"),
        1
      )
      path = mock.root .. "/variant.lua"
      local out = fs.open(path, "w")
      if not out then
        t.ok(false, "could not write the installer variant")
        return nil
      end
      out.write(source)
      out.close()
    end
    -- After setup, like the responses: both queues live on the mock, and setup
    -- clears them. Queuing a failure from the call site instead would be wiped
    -- before the installer ran, and the test would pass on the empty queue
    -- rather than on the failure it meant to arrange.
    if failure then
      mock.failWith(failure)
    end
    for _, response in ipairs(responses or {}) do
      mock.respond(response)
    end
    local chunk, err = loadfile(path)
    if not chunk then
      t.ok(false, "could not load dist/install.lua: " .. tostring(err))
      return nil
    end
    local previous = _G.arg
    _G.arg = args
    local ok, code = pcall(chunk)
    _G.arg = previous
    if not ok then
      t.ok(false, "the installer raised: " .. tostring(code))
      return nil
    end
    return code
  end

  t.eq(#paths, 24, "the installer lists the entry point, the library, and the bundle")
  t.eq(paths[1], "init.lua", "starting with the entry point")
  t.eq(paths[#paths], "dist/opencode.lua", "and ending with the bundle")

  -- The installer runs on a computer, where the host's Lua library is absent.
  -- The mock does not catch that: it sits on a real `os` and a real `io`, so a
  -- program that reached for `os.exit` would pass here and fail on the first
  -- machine that actually ran it.

  do
    local source = env.read(installerPath)
    for _, api in ipairs({ "os%.exit", "os%.getenv", "os%.execute", "io%.", "loadstring", "dofile" }) do
      t.notContains(source, api, "the installer does not use " .. api:gsub("%%", ""))
    end
  end

  -- The repository and branch baked in by `install.lua`.

  do
    local source = env.read(installerPath)
    local repo = source:match('local REPO = "([^"]*)"')
    local branch = source:match('local BRANCH = "([^"]*)"')
    t.ok(repo and repo:find("^https?://"), "the installer was built with a repository url: " .. tostring(repo))
    t.ok(branch and branch ~= "", "and with a branch: " .. tostring(branch))
  end

  -- Finding the raw url. The candidates are guesses about the host, so what
  -- matters is not which one is right for a given forge but that a wrong one is
  -- recognised as wrong and skipped.

  do
    local repo = "https://git.example/owner/name"
    local code = installer({}, queue({
      { status = 404, body = "404: Not Found" },
      { status = 200, body = "<html>sign in</html>" },
      { status = 200, body = "<html>404 not found</html>" },
      { status = 200, body = env.read(t.root .. "/init.lua") },
    }, t.root, paths), repo, "main")

    t.eq(code, 0, "a candidate that answers 200 with the right bytes is taken")
    t.eq(mock.requests[1].url, repo .. "/raw/branch/main/init.lua", "a 404 is skipped")
    t.eq(mock.requests[2].url, repo .. "/-/raw/main/init.lua", "so is a page, however convincing")
    t.eq(mock.requests[3].url, repo .. "/raw/main/init.lua", "and so is a page that admits it is one")
    t.eq(mock.requests[4].url, repo .. "/branch/main/init.lua", "the last candidate is tried too")
    t.eq(mock.requests[5].url, repo .. "/branch/main/init.lua", "and the install carries on from the one that worked")
    t.eq(mock.requests[27].url, repo .. "/branch/main/src/util.lua", "through the whole tree")
    t.ok(env.exists(mock.root .. "/init.lua"), "writing the files it found")
  end

  do
    local code = installer({}, queue({
      { status = 404, body = "" },
      { status = 404, body = "" },
      { status = 404, body = "" },
      { status = 404, body = "" },
    }), "https://git.example/owner/name", "main")

    t.eq(code, 2, "when no candidate serves the file, the installer gives up rather than guessing")
    t.eq(#mock.requests, 4, "after trying all four of the shapes a host might use")
    t.ok(not env.exists(mock.root .. "/init.lua"), "and having written nothing")
  end

  do
    -- GitHub is the one host that does not serve raw files from the repository's
    -- own url, so it needs rewriting to a host of its own.
    local code = installer({}, { { status = 404, body = "" } }, "https://github.com/owner/name", "main")
    t.eq(code, 2, "a GitHub repository that cannot be reached still gives up")
    t.eq(
      mock.requests[1].url,
      "https://raw.githubusercontent.com/owner/name/main/init.lua",
      "and is asked on its raw host first"
    )
  end

  do
    local code = installer({ "--bundle" }, found({ paths[#paths] }), "https://git.example/owner/name", "main")
    t.eq(code, 0, "--bundle probes with the bundle, not with the tree")
    t.eq(mock.requests[1].url, "https://git.example/owner/name/raw/branch/main/dist/opencode.lua",
      "so a host that serves the tree but not the bundle is still found")
    t.eq(mock.requests[2].url, "https://git.example/owner/name/raw/branch/main/dist/opencode.lua",
      "and the winning candidate is then used for the real download")
    t.eq(#mock.requests, 2, "which costs one extra request")
  end

  do
    local code = installer({}, nil, "", "")
    t.eq(code, 2, "an installer with neither a url nor a repository says so")
    t.eq(#mock.requests, 0, "without contacting anybody")
  end

  -- The modular tree.

  do
    local code = installer({ "https://raw.example/main/" }, queue(nil, t.root, paths))
    t.eq(code, 0, "installing from a url succeeds")
    t.eq(#mock.requests, 23, "one request per library file, and not for the bundle")
    t.eq(mock.requests[1].url, "https://raw.example/main/init.lua", "the first file is the entry point")
    t.eq(mock.requests[23].url, "https://raw.example/main/src/util.lua", "the last is the last library file")
    t.ok(env.exists(mock.root .. "/init.lua"), "init.lua was written")
    t.ok(env.exists(mock.root .. "/src/agent.lua"), "a nested module went into a directory that did not exist")
    t.ok(env.exists(mock.root .. "/src/tool/registry.lua"), "and so did the second level")
    t.eq(
      env.read(mock.root .. "/src/agent.lua"),
      env.read(t.root .. "/src/agent.lua"),
      "the file that landed is the one from the repository"
    )
    t.ok(not env.exists(mock.root .. "/opencode.lua"), "bundle mode is not implied")
  end

  -- The same run, with a url that has no trailing slash.

  do
    local code = installer({ "https://raw.example/main" }, queue(nil, t.root, paths))
    t.eq(code, 0, "a base url without a trailing slash is accepted")
    t.eq(mock.requests[1].url, "https://raw.example/main/init.lua", "and does not produce a doubled slash")
  end

  -- The bundle on its own.

  do
    local code = installer(
      { "--bundle", "https://raw.example/main/" },
      queue(nil, t.root, { paths[#paths] })
    )
    t.eq(code, 0, "--bundle installs one file")
    t.eq(#mock.requests, 1, "and asks for it once")
    t.eq(mock.requests[1].url, "https://raw.example/main/dist/opencode.lua", "at its path in the repository")
    t.ok(env.exists(mock.root .. "/opencode.lua"), "written under the name the program is run by")
    t.eq(
      env.read(mock.root .. "/opencode.lua"),
      env.read(t.root .. "/dist/opencode.lua"),
      "and it is the bundle, byte for byte"
    )
    t.ok(not env.exists(mock.root .. "/src"), "no library tree is written in bundle mode")
  end

  -- Failures are reported, not written, and the run stops at the first one.

  do
    local code = installer({ "https://raw.example/main/" }, {
      { status = 404, body = "404: Not Found" },
      { status = 200, body = "truncated" },
    })
    t.eq(code, 1, "a run that fails reports failure")
    t.eq(#mock.requests, 1, "and stops at the first, rather than repeating the same failure 22 more times")
    t.ok(not env.exists(mock.root .. "/init.lua"), "a 404 writes no file, even though it had a body")
    t.ok(not env.exists(mock.root .. "/src/agent.lua"), "and nothing after it is written either")
  end

  do
    local code = installer({ "https://raw.example/main/" }, queue({
      { status = 200, body = env.read(t.root .. "/init.lua") },
      { status = 200, body = "truncated" },
    }))
    t.eq(code, 1, "a short download is a failure, not a file")
    t.ok(env.exists(mock.root .. "/init.lua"), "the files before it are still written, so the run is resumable")
    t.ok(not env.exists(mock.root .. "/src/agent.lua"), "and the one that was short is not")
  end

  do
    t.eq(installer({ "https://raw.example/main/" }, nil, nil, nil, "connection refused"), 1,
      "a transport failure reports failure")
    t.eq(#mock.requests, 1, "having made exactly one attempt, since nothing was queued behind it")
    t.ok(not env.exists(mock.root .. "/init.lua"), "and writes nothing")
  end

  -- A host the server will not let the computer reach. This is the likeliest
  -- way an install fails, and it arrives as a thrown error rather than a
  -- response, so it has to be caught by name or it comes out as a stack trace
  -- through the middle of the download loop.

  do
    local code = installer({}, nil, "https://git.example/owner/name", "main", "Domain not permitted")
    t.eq(code, 2, "a refused host is reported, not raised")
    t.eq(#mock.requests, 1, "and the search gives up rather than asking for a host it already knows is refused")
    t.ok(not env.exists(mock.root .. "/init.lua"), "and nothing is written")
  end

  do
    local code = installer({ "https://raw.example/main/" }, nil, nil, nil, "Domain not permitted")
    t.eq(code, 1, "an explicit url that is refused fails the same way")
    t.eq(#mock.requests, 1, "on the first request")
  end

  do
    -- GitHub's raw files are on a different host, so one refusal there is not
    -- a refusal of the repository's own host and the search should continue.
    local code = installer({}, nil, "https://github.com/owner/name", "main", "Domain not permitted")
    t.eq(code, 2, "a GitHub repository whose raw host is refused still gives up")
    t.eq(#mock.requests, 5, "having asked the repository's own host under all four of its shapes")
    t.eq(mock.requests[1].url, "https://raw.githubusercontent.com/owner/name/main/init.lua", "the refused one first")
    t.eq(mock.requests[2].url, "https://github.com/owner/name/raw/branch/main/init.lua", "and then the rest")
  end

  do
    local code = installer({ "--bundle", "src/util.lua" })
    t.eq(code, 1, "an argument that is neither a url nor a flag is refused")
    t.eq(#mock.requests, 0, "before anything is fetched")
  end
end
