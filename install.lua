-- Installer generator.
--
-- ComputerCraft has no package manager and no way to clone a repository, so a
-- ComputerCraft program is fetched one file at a time over http. That is all
-- this does: it writes `dist/install.lua`, a self-contained program that
-- downloads the file list below from a base url and writes the tree next to
-- itself.
--
-- Two install paths, and which one you want depends on the disk:
--
--   install              the modular tree: init.lua plus src/. Readable, and the
--                        way to go if you want to read or change the code on the
--                        computer. About 250 KB across 23 files.
--   install --bundle     dist/opencode.lua alone, written as opencode.lua. One
--                        file, nothing to keep in sync.
--
-- The file list and the expected sizes are baked in, so the file a computer
-- fetches is known at generation time: a download that comes back short is
-- reported rather than written. Re-run this after adding or renaming a module.
--
-- The remote and the checked-out branch are baked in too, but not a url for the
-- raw files, because where those live is a property of the host: GitHub uses
-- raw.githubusercontent.com, GitLab puts `-/raw` in the path, and Gitea and its
-- forks use `raw/branch`. The installer tries the known shapes and keeps the one
-- that returns a file of the right length, so this works on a self-hosted forge
-- without being told which one it is. `--url` skips the guessing.
--
-- The committed `dist/install.lua` is generated with `--repo`, so that it points
-- at the public repository rather than at whichever remote it was built from.
--
-- Run this *after* build.lua, never before. The bundle is one of the files whose
-- size gets baked in here, so building afterwards leaves the installer expecting
-- a size that no longer exists and every install failing its own staleness check.
-- The two are otherwise independent, and this is the only ordering there is.
--
--   lua build.lua && lua install.lua --repo https://github.com/you/repo
--   lua install.lua --branch release
--   lua install.lua --url https://raw.githubusercontent.com/you/repo/main/
--   lua install.lua --out /tmp/install.lua

local root = (arg[0] or ""):match("^(.*)/[^/]*$") or "."

local BUNDLE = "dist/opencode.lua"

--- Run a command and return its output lines, or nil if it could not run.
local function capture(command)
  local pipe = io.popen(command .. " 2>/dev/null")
  if not pipe then
    return nil
  end
  local lines = {}
  for line in pipe:lines() do
    lines[#lines + 1] = line
  end
  pipe:close()
  return lines
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Escape a string for use as a Lua pattern.
local function patternEscape(s)
  return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1"))
end

--- The first line of a command, or nil if it produced nothing.
local function firstLine(command)
  local lines = capture(command)
  if not lines or #lines == 0 then
    return nil
  end
  return trim(lines[1])
end

--- The url of a named remote, preferring origin.
local function remoteUrlFor(name)
  local url = firstLine("git -C " .. root .. " remote get-url " .. name)
  if url and url ~= "" then
    return url
  end
  return nil
end

--- The checked-out branch, or nil if there is not one to name.
--
-- A detached head has no branch name to put in a url, and a detached head is
-- also the one case where guessing would be worst: the commit is real, but there
-- is no ref to point a download at.
local function checkedOutBranch()
  local branch = firstLine("git -C " .. root .. " rev-parse --abbrev-ref HEAD")
  if not branch or branch == "" or branch == "HEAD" then
    return nil
  end
  return branch
end

--- The remote and branch to bake into the installer, or nil plus the reason.
--
-- The remote is reduced to a browsable https url for the repository, and the
-- branch is whatever is checked out. Where raw files live under that url is not
-- decided here: git does not say, and it differs per host, so the installer
-- finds out for itself.
local function repository()
  local remotes = capture("git -C " .. root .. " remote")
  if not remotes or #remotes == 0 then
    return nil, "this checkout has no git remote"
  end
  local remote = remoteUrlFor("origin")
  if not remote then
    for _, name in ipairs(remotes) do
      remote = remoteUrlFor(name)
      if remote then
        break
      end
    end
  end
  if not remote then
    return nil, "no remote has a url"
  end

  local branch = checkedOutBranch()
  if not branch then
    return nil, "HEAD is detached, so there is no branch to install from"
  end

  -- git@host:owner/repo.git and https://host/owner/repo are the same place;
  -- only the second is something a computer can fetch over http.
  local repo = remote:match("^https?://.+$") or remote:match("^[^@]+@[^:]+:(.+)$")
  if not repo then
    return nil, "could not understand the remote '" .. remote .. "'"
  end
  repo = repo:gsub("%.git$", "")
  return { repo = repo, branch = branch }
end

--- Every Lua file of the modular tree, as repo-relative paths.
local function treeFiles()
  local files = { "init.lua" }
  local found = capture("find " .. root .. "/src -type f -name '*.lua' | sort")
  if not found or #found == 0 then
    return nil
  end
  local prefix = "^" .. patternEscape(root .. "/")
  for _, absolute in ipairs(found) do
    files[#files + 1] = (absolute:gsub(prefix, ""))
  end
  return files
end

local function sizeOf(path)
  local handle = io.open(root .. "/" .. path, "rb")
  if not handle then
    error("install: cannot read " .. path, 0)
  end
  local size = handle:seek("end")
  handle:close()
  return size
end

--- One table constructor: fetch path, expected size, path to write.
local function entry(from, to)
  return string.format("{ %q, %d, %q }", from, sizeOf(from), to)
end

--- A Lua list literal for the file table, `{ { "init.lua", 16184, "init.lua" }, ... }`.
local function entries(files)
  local out = {}
  for _, path in ipairs(files) do
    out[#out + 1] = "  " .. entry(path, path)
  end
  return table.concat(out, ",\n")
end

local function usage()
  print([[
Usage: lua install.lua [--repo <url>] [--branch <name>] [--url <base url>] [--out <path>]

  --repo <url>       the repository the computer installs from, as a browsable
                    https url. Defaults to this checkout's git remote, so use it
                    when generating the installer that gets committed: anyone
                    else who downloads it should be sent to the public
                    repository rather than to the one you happen to work from.
  --branch <name>    the branch to install from (default: the checked-out one)
  --url <base url>   a raw-file url, which skips the search for one entirely.
                    Overrides --repo and --branch.
  --out <path>       where to write the installer (default: dist/install.lua)
]])
end

local options = {
  url = false,
  repo = false,
  branch = false,
  out = root .. "/dist/install.lua",
}
local index = 1
while arg[index] do
  local item = arg[index]
  if item == "--url" then
    options.url = arg[index + 1] or ""
    index = index + 2
  elseif item == "--repo" then
    options.repo = arg[index + 1] or ""
    index = index + 2
  elseif item == "--branch" then
    options.branch = arg[index + 1] or ""
    index = index + 2
  elseif item == "--out" then
    options.out = arg[index + 1] or options.out
    index = index + 2
  elseif item == "--help" or item == "-h" then
    usage()
    os.exit(0)
  else
    io.stderr:write("install: unknown option '" .. item .. "'\n")
    usage()
    os.exit(2)
  end
end

local files = treeFiles()
if not files then
  error("install: no .lua files found under src/", 0)
end

-- Three ways to say where the files come from, in increasing order of
-- specificity: the repository, which the computer turns into a raw url itself;
-- an explicit branch; and a raw url, which needs no guessing.
local base, repo, branch = options.url, "", ""
if options.url == false then
  base = ""
  local wanted = options.branch ~= false and options.branch or nil
  local found, reason
  if options.repo ~= false then
    found = { repo = options.repo, branch = wanted }
  else
    found, reason = repository()
  end
  if found then
    -- A named branch wins; otherwise the checked-out one, which is the only
    -- sensible default but not always available.
    found.branch = wanted or checkedOutBranch()
  end
  if found and found.branch then
    repo, branch = found.repo, found.branch
  else
    if not reason then
      reason = "HEAD is detached, so there is no branch to install from"
    end
    io.stderr:write("install: " .. reason .. "\n")
    io.stderr:write("         re-run with --repo <url> --branch <name>, or pass a base url on the computer.\n")
  end
end

-- Substituted by name rather than by position: the generated program is full of
-- its own `string.format` directives, and a single `%` in the wrong place would
-- be read as a substitution here.
local function expand(template, tokens)
  local out = template
  for token, value in pairs(tokens) do
    out = out:gsub("@" .. token .. "@", function()
      return value
    end)
  end
  local leftover = out:match("@%a+@")
  if leftover then
    error("install: template token " .. leftover .. " was never filled in", 0)
  end
  return out
end

local program = expand([==[
-- opencode installer for ComputerCraft.
--
-- Generated by install.lua. Re-run that after adding a module, and copy this
-- file to the computer again.
--
--   install                  the modular tree, into the current directory
--   install --bundle         dist/opencode.lua alone, as opencode.lua
--   install <url>            fetch from somewhere else
--
-- The base url is baked in when the repository is known. When it is not, pass
-- one: `install <url>` installs from a fork, a mirror, or a paste.

local BASE = @URL@

-- Otherwise the installer looks for the raw files itself, under this repository.
local REPO = @REPO@
local BRANCH = @BRANCH@

-- fetch path, expected size, path to write
local FILES = {
@FILES@
}

local BUNDLE = @BUNDLE@

-- Where the files land. Decided once, here, rather than relying on the shell's
-- directory still being the same when the last file arrives.
local DIR = shell.dir()

--- The terminal's width, or 51, which is what a Computer or Turtle gives you.
local function columns()
  local ok, width = pcall(function()
    return term.getSize()
  end)
  if ok and type(width) == "number" and width > 0 then
    return width
  end
  return 51
end

--- Print, wrapped to the terminal.
--
-- ComputerCraft's `print` does not wrap: a line wider than the terminal is
-- discarded past the right edge rather than continued on the next row. This
-- program has to say things like a base url and a size mismatch, both wider
-- than 51 columns, and the half of a line that carries the actual error is the
-- half that never arrives. Breaking at a space where there is one keeps a long
-- line readable rather than cutting it mid-word.
local function say(text)
  local width = math.max(8, columns())
  for paragraph in (tostring(text) .. "\n"):gmatch("([^\n]*)\n") do
    if paragraph == "" then
      print()
    else
      local rest = paragraph
      while #rest > width do
        -- `.*` is greedy, so this is the last space at or before the margin
        -- rather than the first.
        local space = rest:sub(1, width + 1):match("^.*()%s")
        local take
        if space and space >= math.floor(width / 2) then
          take = space - 1 -- stop before the space
        else
          take = width -- nothing to break on, so fill the line
        end
        print(rest:sub(1, take))
        rest = rest:sub(take + 1):gsub("^%s+", "")
      end
      print(rest)
    end
  end
end

-- Why the last attempt to find the raw files did not work, for the message the
-- failure path prints.
local DISCOVERY = ""

local function fail(message)
  say("install: " .. message)
  return 1
end

--- Create every missing directory along a path, which may be absolute.
local function mkdirs(path)
  -- An absolute path starts with "/" and must not lose it, and the leading
  -- segment is never missing, so the walk begins from an empty prefix.
  local prefix = path:sub(1, 1) == "/" and "" or nil
  for part in path:gmatch("[^/]+") do
    prefix = prefix == nil and part or (prefix .. "/" .. part)
    if not fs.exists(prefix) then
      fs.makeDir(prefix)
    end
  end
end

local function write(path, content)
  local directory = fs.getDir(path)
  if directory and directory ~= "" and directory ~= "." then
    mkdirs(directory)
  end
  local handle = fs.open(path, "w")
  if not handle then
    return false, "could not open " .. path .. " for writing"
  end
  handle.write(content)
  handle.close()
  return true
end

--- Fetch one url. A non-2xx status is an error rather than a body: a proxy or a
--- rate limit answers with a page, and writing that as a Lua file would break
--- the install in a way that is much harder to read than a refused download.
--
-- `http.request` throws rather than returning, and a host the server's allowlist
-- does not permit throws too. That one is worth catching by name: it is the
-- likeliest way for an install to fail, it is fixed in a config file rather than
-- anything reachable from here, and left alone it arrives as a Lua stack trace
-- through the middle of a download loop.
local function fetch(url)
  -- One table, not a url followed by an options table: CC dispatches on the type
  -- of the first argument, so a table in second place is read as the legacy
  -- positional form's POST body and rejected with "bad argument #2 (string
  -- expected, got table)". The url belongs inside the table.
  local ok, handle = pcall(http.request, { url = url, method = "GET", timeout = 60 })
  if not ok then
    local reason = tostring(handle)
    local lower = reason:lower()
    if lower:find("domain", 1, true) and lower:find("not permitted", 1, true) then
      local host = url:match("^https?://([^/]+)") or url
      return nil, "the server's http allowlist does not permit " .. host
    end
    return nil, reason
  end
  if not handle then
    return nil, "could not connect"
  end
  local status = handle.getResponseCode()
  local body = handle.readAll()
  handle.close()
  if status < 200 or status >= 300 then
    return nil, "HTTP " .. status
  end
  return body
end

--- Where a host might serve the raw files of a repository, most likely first.
--
-- Git does not say, and the answer is a property of the host rather than of the
-- repository, so the list is a guess that `discover` checks rather than a fact
-- baked in here.
local function candidates(repo, branch)
  local out, seen = {}, {}
  local function add(url)
    if url and not seen[url] then
      seen[url] = true
      out[#out + 1] = url
    end
  end
  -- GitHub does not serve raw files from the repository's own host, and it
  -- wants the owner and the name separately.
  local owner, name = repo:match("^https?://[^/]+/([^/]+)/([^/]+)$")
  if owner and name and repo:find("github%.com") then
    add(string.format("https://raw.githubusercontent.com/%s/%s/%s/", owner, name, branch))
  end
  add(repo .. "/raw/branch/" .. branch .. "/") -- Gitea, Forgejo, Gogs, Codeberg
  add(repo .. "/-/raw/" .. branch .. "/") -- GitLab
  add(repo .. "/raw/" .. branch .. "/") -- Bitbucket, older Gitea
  add(repo .. "/branch/" .. branch .. "/") -- a plain git http server
  return out
end

--- Whether any candidate after `from` is on a different host.
--
-- The allowlist refuses a host, not a path, so once a host is refused there is
-- nothing to learn from asking it again under a different shape. GitHub is the
-- exception worth keeping: its raw files live on a host of its own, so a
-- repository on github.com that is refused is still worth one try elsewhere.
local function reachesAnotherHost(list, from)
  local host = list[from]:match("^https?://([^/]+)")
  for index = from + 1, #list do
    if list[index]:match("^https?://([^/]+)") ~= host then
      return true
    end
  end
  return false
end

--- Find a base url that serves `path` at exactly `size` bytes.
--
-- Comparing sizes is what makes guessing safe. A web page answers 200 just as
-- readily as a file, and a login page answers 200 too; neither is 16 KB of Lua,
-- so both are rejected without ever being written anywhere. The file is
-- downloaded once more afterwards, which costs one request and keeps this free
-- of any state to carry around.
local function discover(path, size)
  if REPO == "" then
    return nil
  end
  local list = candidates(REPO, BRANCH)
  local last
  for index, base in ipairs(list) do
    say("trying " .. base)
    local body, err = fetch(base .. path)
    if body and #body == size then
      say("found it")
      return base
    end
    last = err or ("got " .. #body .. " bytes, expected " .. size)
    if tostring(err):lower():find("allowlist", 1, true) and not reachesAnotherHost(list, index) then
      break
    end
  end
  -- Kept for the caller, which needs to tell a blocked host apart from a host
  -- that simply does not serve files this way.
  DISCOVERY = tostring(last)
  say("no candidate worked; the last said: " .. DISCOVERY)
  return nil
end

local function one(base, entry)
  local path, size, target = entry[1], entry[2], entry[3]
  local body, err = fetch(base .. path)
  if not body then
    return false, err
  end
  if #body ~= size then
    return false, string.format("got %d bytes, expected %d", #body, size)
  end
  return write(DIR .. "/" .. target, body)
end

local function run(argv)
  local base, bundle = BASE, false
  for index = 1, #argv do
    local item = argv[index]
    if item == "--bundle" then
      bundle = true
    elseif item:find("^https?://") then
      base = item
    else
      return fail("unexpected argument '" .. item .. "'. Usage: install [--bundle] [url]")
    end
  end

  local list = bundle and { BUNDLE } or FILES
  if base == "" then
    -- Probe with the first file either way: it is the one every candidate has
    -- to serve, and its size is the only thing that can tell a file from a page.
    local probe = list[1]
    base = discover(probe[1], probe[2])
    if not base then
      if DISCOVERY:find("allowlist", 1, true) then
        say("That is a server setting, not a network problem, and it is the")
        say("usual reason an install cannot get started. Add to")
        say("serverconfig/computercraft-server.toml, in the world folder:")
        print()
        say("  [[http.rules]]")
        say("  host = \"<the host>\"")
        say("  action = \"allow\"")
        say("  max_upload = 4194304")
        say("  max_download = 16777216")
        say("  timeout = 30000")
        print()
        say("then restart the server. If that host is on your own network, the")
        say("default $private deny rule refuses it by address first: remove the")
        say("[[http.rules]] entry with action = \"deny\" as well.")
        say("Alternatively, hand over a base url with:  install <base url>")
        return 2
      end
      say("Could not work out where to download this repository from.")
      if REPO == "" then
        say("This installer was built without a repository url, so it has")
        say("nowhere to look. Pass one, for example:")
        say("  install https://raw.githubusercontent.com/you/repo/main/")
      else
        say("The repository is " .. REPO .. ", branch " .. BRANCH .. ".")
        say("If it is private, or the host is not one of those above, pass the")
        say("url by hand:")
        say("  install <base url>")
      end
      return 2
    end
  end
  base = base:gsub("/+$", "") .. "/"

  say("installing " .. #list .. " file(s) from " .. base .. " into " .. DIR)
  local bytes, done = 0, 0
  for _, entry in ipairs(list) do
    local ok, err = one(base, entry)
    if not ok then
      -- Stop at the first failure. A wrong base url, a rate limit, or a dropped
      -- connection fails every remaining file the same way, so carrying on
      -- would spend twenty more requests to learn nothing, and would leave a
      -- half-written tree behind. Running `install` again is the fix, and it is
      -- safe: every file is simply written again.
      say(string.format("  FAIL  %-26s %s", entry[1], err))
      say(string.format("stopped at %d of %d file(s); %d were written to %s", done, #list, done, DIR))
      return 1
    end
    done = done + 1
    bytes = bytes + entry[2]
    say(string.format("  ok    %-26s %7d bytes", entry[1], entry[2]))
  end

  say(string.format("installed %d file(s), %d bytes, into %s", #list, bytes, DIR))
  say("run it with:  opencode " .. (bundle and "opencode.lua" or "init.lua"))
  return 0
end

-- Returning, not `os.exit`: ComputerCraft has no `os.exit`, and a program ends
-- when it returns to the prompt. The return value is only read by the test
-- suite, which loads this file rather than running it on a computer.
return run(arg or {})
]==], {
  URL = string.format("%q", base),
  REPO = string.format("%q", repo),
  BRANCH = string.format("%q", branch),
  FILES = entries(files),
  BUNDLE = entry(BUNDLE, "opencode.lua"),
})

local chunk, syntaxError = loadstring(program, "install.lua")
if not chunk then
  error("install: the generated installer does not parse: " .. tostring(syntaxError), 0)
end

local directory = options.out:match("^(.*)/[^/]*$")
if directory and directory ~= "" then
  os.execute("mkdir -p '" .. directory .. "'")
end
local handle, writeError = io.open(options.out, "wb")
if not handle then
  error("install: cannot write " .. options.out .. ": " .. tostring(writeError), 0)
end
handle:write(program)
handle:close()

print(string.format("wrote %s (%d files, %d bytes)", options.out, #files + 1, #program))
if base ~= "" then
  print("url: " .. base)
elseif repo ~= "" then
  print("repo: " .. repo .. " branch " .. branch .. " (the computer finds the raw url)")
else
  print("note: no url baked in, so the computer has to be given one.")
end
