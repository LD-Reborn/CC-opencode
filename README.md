# CC-opencode

An opencode-style coding agent that runs inside a ComputerCraft:Tweaked computer in
Minecraft. It talks to any OpenAI-compatible endpoint, and the model it talks to
can read and write files, run programs, search the filesystem, and fetch URLs —
through ComputerCraft's `fs`, `shell`, and `http` APIs, inside the sandbox.

It is a port, not a rewrite. The agent loop, the tool set, the permission model,
and the OpenAI wire format follow the [opencode](https://github.com/sst/opencode)
source; the shell, the filesystem, and the memory limits are ComputerCraft's.

```
opencode> add a program that says hello
  * read /startup.lua
  * write /hello.lua
    Created /hello.lua
  (1462 in, 89 out)
Written. Run it with `shell.run("hello")`.
```

## Install

ComputerCraft has no package manager and no way to clone a repository, so getting
the code onto a computer means fetching it over http. Two things make that a
one-liner rather than a chore.

Before either route works, the host has to be on the server's http allowlist —
see [What it needs](#what-it-needs). Every fetch below fails with
`Domain not permitted` until you have done that.

### From your own remote

`dist/install.lua` is a ComputerCraft program that downloads the repository into
the computer, file by file. It knows the file list, the expected size of each
file, and the remote and branch it was built from.

Get it onto the computer the same way you would any other file, then run it:

```
wget https://raw.githubusercontent.com/LD-Reborn/CC-opencode/main/dist/install.lua install
install
```

```
install                       the modular tree, into the current directory
install --bundle              dist/opencode.lua alone, as opencode.lua
install <url>                 from somewhere else
```

Where the raw files live is a property of the host, not of git: GitHub uses
`raw.githubusercontent.com`, GitLab puts `-/raw` in the path, and Gitea and its
forks use `raw/branch`. Rather than guess, the installer tries the known shapes
and keeps the first that returns a file of the expected length — which is what
tells a file apart from a login page, since both answer 200. It costs one wasted
request on the shapes that do not apply, and it means a fork on a self-hosted
forge works without being told which forge it is.

That length check doubles as a staleness check. If a file on the remote is not
the one the installer was generated from — a commit behind, say — the sizes
differ, and it says so rather than writing the older file over the newer one.

If the repository is private, or the host is one this list does not cover, pass
the base url yourself and skip the guessing:

```
install https://raw.githubusercontent.com/LD-Reborn/CC-opencode/main/
```

`dist/install.lua` is generated, not written by hand. Re-run it after adding a
module so the file list stays right, and copy the new file over. The committed
one is generated with `--repo`, so it sends everyone who downloads it to this
repository rather than to whichever remote it was built from:

```
lua install.lua --repo https://github.com/LD-Reborn/CC-opencode
```

### The single file

`dist/opencode.lua` is the whole program in one 160 KB file, with the library
inlined. Nothing to keep in sync, and it is the better choice on a small disk:

```
wget https://raw.githubusercontent.com/LD-Reborn/CC-opencode/main/dist/opencode.lua opencode
opencode
```

`wget` takes the url and then the name to save under. `pastebin <url> opencode`
does the same thing and is the older habit, but it is not restricted to
pastebin.com — it fetches whatever url you give it, so it is subject to the same
allowlist as everything else here.

`opencode` can live anywhere; it finds its own directory to look for
`opencode.json`, and the config search is relative to it. Keeping it at the
filesystem root means `opencode.json` next to it and the shell's working
directory are the same place.

### The modular checkout

For reading, hacking on, or updating the source, install the tree instead. It is
the same program in 23 files:

```
init.lua              the entry point
src/                  the library: one module per concern
```

`init.lua` adds its own directory to `package.path` at startup, so
`/init.lua` plus `/src/` works with no arguments and no `package.path` editing,
and you can read the source on the computer. `install` prints the command to run
when it finishes.

Re-running `install` is how you update: every file is written again, so a pull
on your side and an `install` on the computer is the whole cycle.

### What it needs

Three gates, and they are separate.

**On the computer**, the http mod has to be on: `/setmod http true`, or the
peripheral in the server config.

**The version matters more than it looks.** Every request goes through the options
form of `http.get`/`http.post`, which arrived in CC:Tweaked 1.80pr1.6, and carries
a `timeout`, which needs 1.105.0. Below 1.105 the request still goes out — the
key is simply ignored by the older socket layer — so nothing breaks outright, but
a request has no time limit of its own. Anything from 1.105.0 on is what this is
written against.

**On the server**, the host has to be on the http allowlist, or every request is
refused with `Domain not permitted`. There is no implicit allow, so this is the
step people miss. In `serverconfig/computercraft-server.toml` inside the world
folder, on CC:Tweaked 1.87.0 and later:

```toml
[[http.rules]]
    host = "raw.githubusercontent.com"
    action = "allow"
    max_upload = 4194304
    max_download = 16777216
    timeout = 30000
```

Rules match the host in the url, not the repository, so this is
`raw.githubusercontent.com` for the downloads above — not `github.com`. And the
model's host is a separate entry, because a computer that can install and then
cannot talk to anything is a confusing half-working state:

```toml
[[http.rules]]
    host = "opencode.ai"
    action = "allow"
    max_upload = 4194304
    max_download = 16777216
    timeout = 30000
```

Whichever provider you configure needs its own entry the same way. A missing one
is reported with the file to edit rather than retried, since a missing config
line is not something a second attempt would fix.

Two traps in that file. Rules are matched in order, and the default config also
carries a deny for `$private`, so a host that resolves to a LAN address is
refused by address whatever its name is — delete the `action = "deny"` block if
you install from a forge on your own network. And on 1.86.2 and earlier this is
a `blacklist = []` array in `computercraft-common.toml` instead, where an empty
array means everything on the whitelist is reachable.

Nothing else: no `cc-tweaked` modules, no `os.getenv`, no `io`. Lua 5.1 only —
the source uses no 5.2+ syntax.

## Configure

Configuration is a single `opencode.json`, read from the working directory first
and then from `/`. It is JSON, not Lua, so it is safe to keep next to a world
save or a paste.

The minimum, if you are happy with the default model. The key is not optional —
the zen gateway is an ordinary provider that happens to be the default:

```json
{
  "model": "opencode/gpt-5",
  "env": { "OPENCODE_API_KEY": "..." }
}
```

A more typical file:

```json
{
  "$schema": "https://opencode.ai/config.json",

  "model": "openrouter/anthropic/claude-sonnet-4",
  "small_model": "opencode/gpt-5-nano",

  "env": {
    "OPENROUTER_API_KEY": "sk-or-v1-..."
  },

  "provider": {
    "openrouter": {
      "models": {
        "anthropic/claude-sonnet-4": {
          "name": "Claude Sonnet 4",
          "limit": { "context": 200000, "output": 64000 }
        }
      }
    }
  },

  "permission": [
    "read",
    { "permission": "edit", "pattern": "*.lua", "action": "ask" },
    { "permission": "bash", "pattern": "*", "action": "ask" },
    { "permission": "webfetch", "pattern": "*", "action": "deny" }
  ],

  "tools": {
    "todowrite": true,
    "webfetch": false
  },

  "compaction": {
    "auto": true,
    "reserved": 20480
  },

  "title": true
}
```

Every key is optional.

| Key | Meaning | Default |
| --- | --- | --- |
| `model` | `provider/model` to use | `opencode/gpt-5` |
| `small_model` | Model for session titles and compaction summaries | `opencode/gpt-5-nano` |
| `env` | API keys, keyed by the provider's variable name | none |
| `provider` | Per-provider base url, headers, model list, per-model limits | see below |
| `agent` | Step budget and prompt override, per agent | 25 / 15 / 25 steps |
| `tools` | `true`/`false` per tool id; a missing key means enabled | all enabled |
| `permission` | Approval rules | allow most, ask for edits and `*.env` |
| `compaction` | `auto` summarises a long conversation; `reserved` is headroom kept free | `auto: true`, 20 KB |
| `tool_output` | `max_lines` and `max_bytes` for any tool's output | 2000 lines, 50 KB |
| `title` | Name a session from its first question when it is saved | `true` |

### Models and providers

A model id is `provider/model`, split on the **first** slash only, so
`openrouter/anthropic/claude-sonnet-4` is provider `openrouter` with model
`anthropic/claude-sonnet-4`.

These providers are built in, with their base urls and the environment variable
each one reads:

`opencode` (`OPENCODE_API_KEY`), `openai` (`OPENAI_API_KEY`), `openrouter`,
`groq`, `cerebras`, `deepinfra`, `deepseek`, `fireworks`, `togetherai`, `xai`,
`ollama`, and `lmstudio` — the last two with a placeholder key, since a local
server ignores the header. Every other one needs a real key; a provider with
none is refused at startup, naming the variable to set, rather than failing later
at the gateway.

The zen gateway is on `opencode.ai`, and the key is issued there. It is worth
being precise about that, because `models.opencode.ai` looks like the same
service and is not: it is the models.dev website, and it answers every path under
it with a redirect to its front page, so a base url pointing there connects and
then hands back HTML where a JSON reply should be.

Any other OpenAI-compatible endpoint is a config entry away, and nothing else is
needed:

```json
{
  "model": "local/llama-3.3-70b",
  "provider": {
    "local": {
      "api": "http://192.168.1.10:8080/v1",
      "options": { "apiKey": "not-secret" },
      "models": {
        "llama-3.3-70b": { "name": "Llama 3.3 70B" }
      }
    }
  }
}
```

Per provider: `api` (the base url; the client appends `/chat/completions`),
`name`, `options` (request defaults: `apiKey`, `apiKeyFile`, `apiKey` placeholders,
`maxTokens`, `temperature`, `topP`, `reasoningEffort`, `timeout`, `headers`), and
`models`. Per model: `name`, `limit.context`, `limit.output`, `options`, `headers`.

`limit.context` is not cosmetic: it is the point at which the conversation is
summarised. If you leave it out, 128 KB is assumed.

### API keys

Resolved in this order, and the first hit wins:

1. `provider.<id>.options.apiKey`
2. the file named by `provider.<id>.options.apiKeyFile` (read and trimmed)
3. `env.<VARIABLE>` in `opencode.json`, for any of the provider's names
4. the profile's built-in key, for providers that do not need a real one

There is no process environment in ComputerCraft, which is what `env` in the
config stands in for. `apiKeyFile` exists so the key can live outside the config
if you would rather it did:

```json
{ "provider": { "openai": { "options": { "apiKeyFile": "/secrets/openai" } } } }
```

`/providers` prints every provider with its base url and whether a key was found;
`/models` prints what the config can actually reach. A provider with no `models`
block cannot be listed, because nothing in the config says which ids it serves.

## Use

```
opencode                    interactive, on a monitor if one is attached
opencode "list the programs" one turn, print the answer, exit
opencode run "..."           the same, spelled out
```

| Flag | Effect |
| --- | --- |
| `--model <id>` | `provider/model` to use, overriding the config |
| `--agent <name>` | `build`, `general`, `plan`, or `explore` |
| `--dir <path>` | Working directory, relative to the shell's |
| `--save` | Save the session when the run ends |
| `--stream` | Ask the provider for an event stream |
| `--help` | The option list |

In the REPL, anything that is not a command is a question:

| Command | Effect |
| --- | --- |
| `/help` | The command list |
| `/model`, `/model <id>` | Show or switch the model |
| `/models` | Models the config can reach |
| `/providers` | Known providers, base urls, and whether each has a key |
| `/agent`, `/agent <name>` | Show or switch the agent |
| `/tools` | The tools available this session |
| `/new` | Start a new session |
| `/save` | Name the session if it has no name, then write it to disk |
| `/exit`, `/quit` | Quit, saving first if `--save` |

Sessions are written to `opencode/session/<id>.json` under the working
directory. They are plain JSON with the full message and part list, so a session
is readable and comparable without this program.

A monitor is used when one is attached, and the terminal otherwise. One-shot mode
exits nonzero if the turn ended in a provider or transport error, so a shell
script or a wrapper can tell.

## The tools

| Tool | What it does |
| --- | --- |
| `bash` | Runs a command through the ComputerCraft shell. `command`, plus `timeout` (ms, default 120000) and `workdir`. Output is captured, not streamed. |
| `read` | Reads a file or lists a directory, with `offset` and `limit` (default 2000 lines). Lines are numbered. |
| `write` | Creates or overwrites a file. |
| `edit` | Replaces an exact string in a file. `filePath`, `oldString`, `newString`, optional `replaceAll`. Refuses a match that is much larger than `oldString`. |
| `glob` | Finds files by path pattern, with `path` and `limit` (default 100). |
| `grep` | Searches file contents, with `pattern`, `path`, `include`, `limit` (default 100). |
| `webfetch` | Fetches a URL, as text or `html`, up to 5 MB. |
| `todowrite` | Replaces the session's todo list, which is stored with the session. |

`grep` takes a real regular expression, which CC has no engine for, so
`src/pattern.lua` translates one to a Lua pattern. It is exact for the
common cases and documented where it is not — Lua patterns cannot repeat a
multi-character group, so `(ab)+` is approximated as `X+`.

Output is capped at 2000 lines or 50 KB for every tool, and the model is told
the real numbers so it plans around them. `tool_output` in the config changes
both.

## Permissions

Every tool action is checked against a ruleset before it runs. The **last**
matching rule wins, and no match at all means *ask*. A rule is a string (allow
everything for that permission) or an object:

```json
{ "permission": "edit", "pattern": "*.lua", "action": "ask" }
```

`permission` values are `read`, `edit`, `bash`, `webfetch`, `todowrite`,
`external_directory`, and `doom_loop`. `action` is `allow`, `ask`, or `deny`.
`pattern` is a glob; a pattern ending in ` *` also matches the bare name, so
`"ls *"` allows `ls` and `ls -la`.

The defaults allow everything, then carve out the cases that are worth a
question: anything outside the working directory, reads of a `*.env` file, and a
model repeating the same failing call three times in a row. The example above is
stricter than that on purpose — it asks before every edit and every command, and
refuses network access outright.

At a prompt:

- `y` — this time
- `a` — this and every later call in this session
- `n` — no
- anything else — no, and the text is handed back to the model as feedback, so it
  can change what it is doing rather than retry blindly

## What ComputerCraft changes

This is a port, and the port is not cosmetic. The things that differ:

- **The shell is CC's shell.** It has pipes, `>`, `&`, and `;`. It does not have
  `&&`, `||`, `$VAR`, `~`, or glob expansion. `bash` is named after opencode's
  tool; the prompt says so explicitly, so the model does not keep trying `&&`.
- **Streaming is a lie, mostly.** The response handle only exists once the whole
  body has arrived, so there is nothing to hand on as it comes in. `--stream`
  sends `stream: true` and reassembles the SSE frames afterwards, so the text
  appears all at once. It is off by default.
- **`http.request` is asynchronous, and `http.get`/`http.post` are not.** This
  is the one that reads as a typo and is not. `http.request` starts the request,
  returns immediately, and delivers the response later as an `http_success` event;
  its own source calls the return value "for legacy reasons" and undocumented. It
  is a **boolean**, so reading a response out of it raises `attempt to index
  local 'handle' (a boolean value)` and nothing is ever fetched. The synchronous
  pair wraps that identical call in an `os.pullEvent` loop, and that loop is the
  whole difference. All three also dispatch on the type of their first argument: a
  table is the options form with the url inside it, a string is the legacy
  positional signature where argument 2 is the body — so `http.request(url, {
  method = "GET" })` is refused with `bad argument #2 (string expected, got
  table)`. Both failures happen on the first request, name neither the url nor
  the request, and appear only on real hardware. The mock reproduces both, so the
  suite catches them.
- **A failed request is a return value, not an exception.** `http.get` answers
  `nil, message`, and behind them the failing response whenever the server said
  anything at all. The message is a bare reason phrase, so the status has to come
  off the response — that third value is the only place a provider's own error
  text and a `Retry-After` header live. `pcall` is for CC validating the request
  table, which is our bug rather than the network's, and is neither retried nor
  reported as an unreachable host.
- **No process environment.** `os.getenv` does not exist. Keys come from
  `opencode.json`.
- **Every request is vetted by the server first.** The host has to be on the
  http allowlist, and there is no implicit allow. A refused host is reported with
  the config file to edit rather than retried, since a missing config line is not
  something a second attempt would fix.
- **The whole conversation is resent every turn.** Long sessions would grow
  without bound, so `compaction` replaces the older messages with a summary once
  the conversation approaches the model's context limit, keeping the turn in
  progress. If the summary fails, nothing is dropped.
- **`os.time` has one-second resolution.** Tool timings and session timestamps
  are coarse, so a run that looks instant in wall-clock terms is not.
- **Memory is small.** A context window of 128 KB is already a large session by
  ComputerCraft standards. `compaction.reserved` exists to leave room for the
  reply.
- **No regex, no `loadstring`, no `io`.** Hence `pattern.lua` and the bundled
  loader, which wraps each module as a function body and installs it through
  `package.preload`.
- **Ctrl-C does not exist.** A running program cannot be interrupted, so a very
  long turn cannot be stopped from the keyboard. `agent.<name>.steps` bounds it.

## Development

The test suite runs on plain Lua 5.1 against a mock of the ComputerCraft API, so
no Minecraft client is involved.

```
lua test/run.lua            # everything
lua test/run.lua agent      # one suite: json util pattern provider http llm
                           # truncate tools agent cli install
```

```
lua build.lua               # writes dist/opencode.lua
lua build.lua --out /tmp/o.lua
lua build.lua --test        # build, then run the bundle against the mock
```

```
lua install.lua             # writes dist/install.lua
lua install.lua --url <base url>
```

`build.lua` derives the module order from the require graph, refuses to emit a
bundle with an unresolved `require`, checks that the output parses, and with
`--test` runs the generated bundle in a fresh process where the only source of
modules is the bundle itself. `CCOPENCODE_DEBUG_BUNDLE=<path>` writes the
generated source there instead of running it.

`install.lua` writes the ComputerCraft-side installer: the file list, each file's
size, and the remote and branch from git. It checks that the result parses. The
generated program is covered by `lua test/run.lua install`, which runs it
against the mock and rewrites the baked-in repository to check each host shape.

Layout:

```
init.lua                  argument parsing, the REPL, rendering
install.lua               the generator for dist/install.lua
src/
  environment.lua         the only module that touches fs/shell/http/term
  json.lua                encode and decode, with a distinct null
  pattern.lua             regex to Lua pattern
  http.lua                requests, retries, backoff, SSE framing
  llm.lua                 the OpenAI chat completions client
  provider.lua            providers, models, credentials
  config.lua              opencode.json, defaults, the built-in profiles
  session.lua             messages, parts, persistence
  agent.lua               the loop: steps, tools, compaction, titles
  permission.lua          rules and the approval prompt
  prompt.lua              system prompts
  truncate.lua            output limits
  util.lua                small shared helpers
  tool/                   bash read write edit glob grep webfetch todowrite
```

Every ComputerCraft API call goes through `environment.lua`, which is why the
rest of the code has no `fs` or `shell` in it and why the mock is a single file.
