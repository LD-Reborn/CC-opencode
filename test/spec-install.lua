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
  --
  -- CC-GUI's `GUI.lua` is not among them: it comes from its own repository, so it is
  -- fetched by a separate step rather than being an entry in this list.
  local paths = {}
  for path in (env.read(installerPath) or ""):gmatch('{ "([^"]+)", %d+,') do
    paths[#paths + 1] = path
  end

  --- The modular tree alone, which is every entry but the last.
  --
  -- The bundle is the last entry and is fetched only in `--bundle` mode, so a queue
  -- built for the tree has to leave it out: a response queued for a file the installer
  -- never asks for is a response the next request reads instead, and the misalignment
  -- shows up several files later as a size that is wrong for the file it names.
  local tree = {}
  for index = 1, #paths - 1 do
    tree[index] = paths[index]
  end

  --- CC-GUI's root, which is where `GUI.lua` is read from when a test wants to queue
  -- a response carrying the real file.
  local guiRoot = t.root .. "/../CC-GUI"

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

  --- A queue with CC-GUI's answers in it, for the fetch that comes after the tree.
  --
  -- Two of them, because the fetch is a search and then a download: the installer
  -- probes the first shape a host might use, and if that answers with the right
  -- bytes it downloads from there. A single answer would be spent on the probe and
  -- the download would read whatever came next in the queue.
  --
  -- The bodies are the real file for the same reason the tree's are: the installer
  -- compares sizes, and a fabricated body of the right size would let a test pass
  -- without proving the right file arrived.
  local function withGui(responses)
    local body = env.read(guiRoot .. "/GUI.lua") or ""
    local out = {}
    for _, response in ipairs(responses or {}) do
      out[#out + 1] = response
    end
    out[#out + 1] = { status = 200, body = body }
    out[#out + 1] = { status = 200, body = body }
    return out
  end

  --- A queue where every CC-GUI answer is the wrong length, so the search fails.
  --
  -- One per shape a host might use, and then one more: the search has to exhaust all
  -- of them before it concludes that none serves the file, and a short queue would
  -- end in the mock's default answer rather than in the failure being arranged.
  local function withoutGui(responses)
    local out = {}
    for _, response in ipairs(responses or {}) do
      out[#out + 1] = response
    end
    for _ = 1, 6 do
      out[#out + 1] = { status = 200, body = "<html>sign in</html>" }
    end
    return out
  end

  --- Run the generated installer with the arguments a shell would pass.
  --
  -- `repo` and `branch` replace the ones baked in by `install.lua`, so the
  -- candidate urls can be tried for hosts this checkout is not on. `guiRepo` and
  -- `guiBranch` do the same for CC-GUI, which is fetched from its own repository.
  -- The queue has to be built after `mock.setup()`, which wipes the mock filesystem,
  -- so both the responses and the rewritten file come in as arguments.
  --
  -- The installer returns a status instead of calling `os.exit`, which
  -- ComputerCraft does not have, so the return value is the status.
  --- The url of the nth request, or a note that it never happened.
  --
  -- Reaching into `mock.requests[n].url` directly aborts the entire run on a nil,
  -- which buries the assertion that was about to say what went wrong. That is not
  -- hypothetical: it is what a broken installer did here, twice, while the real
  -- complaint was still queued up to be printed.
  local function requested(n)
    local entry = mock.requests[n]
    return entry and entry.url or ("(request " .. n .. " was never made)")
  end

  local function installer(args, responses, repo, branch, failure, guiRepo, guiBranch)
    mock.setup()
    local path = installerPath
    if repo or guiRepo then
      local source = env.read(installerPath)
      if repo then
        source = source:gsub('local REPO = "[^"]*"', "local REPO = " .. string.format("%q", repo), 1)
        source = source:gsub(
          'local BRANCH = "[^"]*"',
          "local BRANCH = " .. string.format("%q", branch or "main"),
          1
        )
      end
      if guiRepo then
        source = source:gsub('local GUI_REPO = "[^"]*"', "local GUI_REPO = " .. string.format("%q", guiRepo), 1)
        source = source:gsub(
          'local GUI_BRANCH = "[^"]*"',
          "local GUI_BRANCH = " .. string.format("%q", guiBranch or "main"),
          1
        )
      end
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
    -- What it printed is part of what it does: the last two lines are the
    -- instruction the operator is left with, and there is nothing else to tell
    -- whether they can follow it. Capturing `print` also stops the usage text from
    -- a failing case appearing in the middle of the suite's own output.
    local printed = {}
    local previous, realPrint = _G.arg, _G.print
    _G.print = function(...)
      local parts = {}
      for index = 1, select("#", ...) do
        parts[#parts + 1] = tostring((select(index, ...)))
      end
      printed[#printed + 1] = table.concat(parts, " ")
    end
    _G.arg = args
    local ok, code = pcall(chunk)
    _G.arg, _G.print = previous, realPrint
    if not ok then
      t.ok(false, "the installer raised: " .. tostring(code))
      return nil, table.concat(printed, "\n")
    end
    return code, table.concat(printed, "\n")
  end

  t.eq(#paths, 26, "the installer lists the entry point, the library, and the bundle")
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

  -- The installer has to wrap what it prints.
  --
  -- ComputerCraft's `print` does not wrap either, and what the installer has to
  -- say is exactly what overruns a 51-column terminal: a base url, a file size, a
  -- size mismatch. An unwrapped line is not merely ugly, the part past the right
  -- edge is discarded and never arrives, so the half carrying the actual error is
  -- the half that is lost.
  --
  -- The generated program is not run through a screen in this suite, so this is
  -- checked structurally: it asks the terminal how wide it is, and no long literal
  -- reaches `print` directly.

  do
    local source = env.read(installerPath)
    t.contains(source, "term.getSize", "the installer asks the terminal how wide it is")
    t.contains(source, "local function say(text)", "and prints through a wrapper rather than print")
    -- One assertion, not one per line: a long literal reaching print is a bug
    -- worth naming, and three hundred identical passes are not.
    local offender
    for line in source:gmatch("[^\n]+") do
      if #line >= 51 and line:match('print%("[^"]*"') then
        offender = line
        break
      end
    end
    t.eq(offender, nil, "no long literal goes straight to print: " .. tostring(offender))
  end

  -- The installer asks for http the documented way.
  --
  -- Two things go wrong here, and both of them happen on the very first file,
  -- before anything is written, with an error that names neither the url nor the
  -- request:
  --
  --   `http.request` is asynchronous. It starts the request, returns immediately,
  --   and delivers the response later as an `http_success` event; its own source
  --   calls the return value "for legacy reasons" and undocumented. Reading a
  --   response out of a boolean raises "attempt to index local 'handle' (a boolean
  --   value)". `http.get` is the synchronous wrapper around the same call.
  --
  --   All three forms dispatch on the type of the first argument. A string puts
  --   them in the legacy positional signature, where argument 2 is the body and
  --   must be a string, so `http.request(url, { method = "GET" })` is refused with
  --   "bad argument #2 (string expected, got table)".
  --
  -- The mock reproduces both now, so the shape is checked by behaviour as well as
  -- by reading the source.

  do
    local source = env.read(installerPath)
    t.contains(source, "pcall(http.get, { url = url", "it uses the synchronous entry point")
    -- Matched as calls, not as text: the comment above explains at some length
    -- why `http.request` is the wrong one, and it should keep doing so.
    t.notContains(source, "http.request(", "and never calls the asynchronous one")
    t.notContains(source, "pcall(http.request", "which would return a boolean")
    t.notContains(source, "http.request, url, {", "nor the legacy positional form")
  end

  do
    local code = installer({ "https://raw.example/main/" }, queue({}, t.root, paths))
    t.eq(code, 0, "and a real install still works through the mock, which enforces the shape")
    t.eq(requested(1), "https://raw.example/main/init.lua", "reaching the first file")
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
    t.eq(requested(1), repo .. "/raw/branch/main/init.lua", "a 404 is skipped")
    t.eq(requested(2), repo .. "/-/raw/main/init.lua", "so is a page, however convincing")
    t.eq(requested(3), repo .. "/raw/main/init.lua", "and so is a page that admits it is one")
    t.eq(requested(4), repo .. "/branch/main/init.lua", "the last candidate is tried too")
    t.eq(requested(5), repo .. "/branch/main/init.lua", "and the install carries on from the one that worked")
    t.eq(requested(29), repo .. "/branch/main/src/util.lua", "through the whole tree")
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
      requested(1),
      "https://raw.githubusercontent.com/owner/name/main/init.lua",
      "and is asked on its raw host first"
    )
  end

  do
    local code, said = installer({ "--bundle" }, found({ paths[#paths] }), "https://git.example/owner/name", "main")
    t.eq(code, 0, "--bundle probes with the bundle, not with the tree")
    t.eq(requested(1), "https://git.example/owner/name/raw/branch/main/dist/opencode.lua",
      "so a host that serves the tree but not the bundle is still found")
    t.eq(requested(2), "https://git.example/owner/name/raw/branch/main/dist/opencode.lua",
      "and the winning candidate is then used for the real download")
    -- Two for the bundle -- the probe and the real download -- and then five for the
    -- CC-GUI search, which has to try every shape a host might use.
    t.eq(#mock.requests, 7, "which costs one extra request, and the CC-GUI search its own")
    t.contains(said, "run it with:  ./opencode.lua", "the bundle is named for what it was written as")
    t.ok(not said:find("./init.lua", 1, true), "and not for a file this mode did not install")
  end

  do
    -- `repo` is the empty string here rather than nil, and an empty string is truthy
    -- in Lua, so this takes the rewrite path and bakes an empty repository in. That is
    -- worth a test of its own: the installer has to say it has nowhere to look rather
    -- than crash inside the message about it.
    local code, said = installer({}, nil, "", "")
    t.eq(code, 2, "an installer with neither a url nor a repository says so")
    -- Wrapped at the terminal's own width, like everything else it prints.
    t.contains(said, "Could not work out where to download", "and says why")
    t.eq(#mock.requests, 0, "without contacting anybody")
  end

  -- The modular tree.

  do
    local code, said = installer({ "https://raw.example/main/" }, queue(nil, t.root, paths))
    t.eq(code, 0, "installing from a url succeeds")
    -- One per library file, plus the CC-GUI lookup after them: the interface is
    -- optional, so that one is a search and not a download.
    t.eq(#mock.requests, 30, "one request per library file, then the CC-GUI search")
    t.eq(requested(1), "https://raw.example/main/init.lua", "the first file is the entry point")
    -- Twenty-five files in the tree: the entry point and the twenty-four modules under
    -- src/. The bundle is not among them, being a separate entry with its own name.
    t.eq(requested(25), "https://raw.example/main/src/util.lua", "the last is the last library file")
    t.ok(env.exists(mock.root .. "/init.lua"), "init.lua was written")
    t.ok(env.exists(mock.root .. "/src/agent.lua"), "a nested module went into a directory that did not exist")
    t.ok(env.exists(mock.root .. "/src/tool/registry.lua"), "and so did the second level")
    t.eq(
      env.read(mock.root .. "/src/agent.lua"),
      env.read(t.root .. "/src/agent.lua"),
      "the file that landed is the one from the repository"
    )
    t.ok(not env.exists(mock.root .. "/opencode.lua"), "bundle mode is not implied")

    -- The closing advice. It used to say `opencode init.lua`, which is wrong twice
    -- over on a computer: the modular path installs no program of that name, and
    -- the argument would be read as a question to send the model.
    --
    -- A shell finds a program by name on the program path, which on a computer is
    -- `/rom/programs` -- read-only, so nothing can be installed there and a bare
    -- name never resolves to a file put somewhere else. A name containing a `/` is
    -- resolved against the current directory instead, which is where these were just
    -- written. So the `./` is the entire fix, and `shell.run` needs it for the same
    -- reason: it goes through the same lookup.
    t.contains(said, "run it with:  ./init.lua", "the tree is run from where it was written")
    t.contains(said, 'shell.run("./init.lua")', "and from the Lua prompt, with the same ./")
    t.ok(not said:find("opencode init.lua", 1, true), "and not as a command no computer has")
  end

  -- The same run, with a url that has no trailing slash.

  do
    local code = installer({ "https://raw.example/main" }, queue(nil, t.root, paths))
    t.eq(code, 0, "a base url without a trailing slash is accepted")
    t.eq(requested(1), "https://raw.example/main/init.lua", "and does not produce a doubled slash")
  end

  -- The bundle on its own.

  do
    local code = installer(
      { "--bundle", "https://raw.example/main/" },
      queue(nil, t.root, { paths[#paths] })
    )
    t.eq(code, 0, "--bundle installs one file")
    -- The bundle, then the CC-GUI search: five shapes a host might use, none of which
    -- serves a file to an empty queue.
    t.eq(#mock.requests, 6, "and asks for it once, then searches for CC-GUI")
    t.eq(requested(1), "https://raw.example/main/dist/opencode.lua", "at its path in the repository")
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
    t.eq(requested(1), "https://raw.githubusercontent.com/owner/name/main/init.lua", "the refused one first")
    t.eq(requested(2), "https://github.com/owner/name/raw/branch/main/init.lua", "and then the rest")
  end

  do
    local code = installer({ "--bundle", "src/util.lua" })
    t.eq(code, 1, "an argument that is neither a url nor a flag is refused")
    t.eq(#mock.requests, 0, "before anything is fetched")
  end

  -- CC-GUI, which the interface is built on.
  --
  -- It is fetched from its own repository rather than from this one, because it is not
  -- in this one: a checkout of this project has no GUI.lua in it, and an installer
  -- that looked for one would be looking for a file that is not there. It is also
  -- optional in a way nothing else in this install is not -- the program asks for it
  -- with a `pcall` and carries on without it -- so a failure here is reported and the
  -- run goes on rather than stopping a working install over a plainer screen.

  do
    -- The tree's responses, then CC-GUI's: the installer asks for the tree first and
    -- for CC-GUI second, so the queue has to be in that order.
    local code, said = installer({ "https://raw.example/main/" }, withGui(queue(nil, t.root, tree)))
    t.eq(code, 0, "an install with CC-GUI reachable succeeds")
    t.ok(env.exists(mock.root .. "/GUI.lua"), "and writes GUI.lua beside the program")
    t.eq(
      env.read(mock.root .. "/GUI.lua"),
      env.read(guiRoot .. "/GUI.lua"),
      "and it is the file from the CC-GUI repository, byte for byte"
    )
    t.contains(said, "  ok    GUI.lua", "and reports it like any other file")
    t.contains(said, "installed 26 file(s)", "counting it among them")
  end

  do
    -- A body of the wrong length is a failure, not a file, and the size check is what
    -- says so: a web page answers 200 as readily as a file does.
    local code, said = installer({ "https://raw.example/main/" }, withoutGui(queue(nil, t.root, tree)))
    t.eq(code, 0, "a CC-GUI that cannot be fetched does not fail the install")
    t.ok(not env.exists(mock.root .. "/GUI.lua"), "and writes no GUI.lua")
    t.contains(said, "the interface is unavailable without it", "but says what the cost is")
    t.contains(said, "the plain", "and what the program does instead")
    t.ok(env.exists(mock.root .. "/init.lua"), "the program itself is still installed")
  end

  do
    -- The repository and branch are baked in, and a fork of CC-GUI is as worth
    -- supporting as a fork of this: both are pointed at by a flag.
    local code = installer({ "https://raw.example/main/" }, withGui(queue(nil, t.root, tree)), nil, nil, nil,
      "https://git.example/owner/ccgui", "release")
    t.eq(code, 0, "a fork of CC-GUI is installed from")
    -- The tree's twenty-five requests, then the CC-GUI search: the first shape a host
    -- might use answers with the right bytes, so the download is the request after it.
    t.eq(
      requested(26),
      "https://git.example/owner/ccgui/raw/branch/release/GUI.lua",
      "at its own repository and branch"
    )
  end

  do
    -- The default is the upstream project, which is where a person who has not thought
    -- about it would expect to get it from.
    local source = env.read(installerPath)
    t.contains(source, "https://github.com/LD-Reborn/CC-GUI", "the upstream CC-GUI is the default")
    t.contains(source, "GUI_BRANCH = \"main\"", "on its main branch")
  end
end
