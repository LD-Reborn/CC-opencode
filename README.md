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

### The single file

The bundle is the easy way in. Copy `dist/opencode.lua` to your computer as
`/opencode` (no `.lua`) and run it:

```
pastebin <url> opencode
opencode
```

`/opencode` can live anywhere; it finds its own directory to look for
`opencode.json`, and the config search is relative to it. Keeping it at the
filesystem root means `opencode.json` next to it and the shell's working
directory are the same place.

### The modular checkout

For reading, hacking on, or updating the source, copy the directory instead:

```
opencode/            the program: init.lua
src/                 the library: one module per concern
build.lua            the bundler (not needed on the computer)
test/                the test suite (not needed on the computer)
```

`init.lua` adds its own directory to `package.path` at startup, so
`/opencode/init.lua` plus `/opencode/src/` works with no arguments and no
`package.path` editing. `dist/opencode.lua` and this checkout are the same
program; the bundle just inlines the library.

### What it needs

ComputerCraft:Tweaked with `http` enabled (`/setmod http true` in a Turtle or
Computer, or the server config). Nothing else: no `cc-tweaked` modules, no
`os.getenv`, no `io`. Lua 5.1 only — the source uses no 5.2+ syntax.

## Configure

Configuration is a single `opencode.json`, read from the working directory first
and then from `/`. It is JSON, not Lua, so it is safe to keep next to a world
save or a paste.

The minimum, if you are happy with a public model:

```json
{ "model": "opencode/gpt-5" }
```

A more typical file:

```json
{
  "$schema": "https://opencode.ai/config.json",

  "model": "openrouter/anthropic/claude-sonnet-4",
  "small_model": "opencode/gpt-5-mini",

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
| `small_model` | Model for session titles and compaction summaries | `opencode/gpt-5-mini` |
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

`opencode` (`OPENCODE_API_KEY`, ships with a public key), `openai`
(`OPENAI_API_KEY`), `openrouter`, `groq`, `cerebras`, `deepinfra`, `deepseek`,
`fireworks`, `togetherai`, `xai`, `ollama`, and `lmstudio` — the last two with a
placeholder key, since a local server ignores the header.

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
- **Streaming is a lie, mostly.** `http.request` reads the whole body before
  returning. `--stream` sends `stream: true` and reassembles the SSE frames
  afterwards, so the text appears all at once. It is off by default.
- **No process environment.** `os.getenv` does not exist. Keys come from
  `opencode.json`.
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
                           # truncate tools agent cli
```

```
lua build.lua               # writes dist/opencode.lua
lua build.lua --out /tmp/o.lua
lua build.lua --test        # build, then run the bundle against the mock
```

`build.lua` derives the module order from the require graph, refuses to emit a
bundle with an unresolved `require`, checks that the output parses, and with
`--test` runs the generated bundle in a fresh process where the only source of
modules is the bundle itself. `CCOPENCODE_DEBUG_BUNDLE=<path>` writes the
generated source there instead of running it.

Layout:

```
init.lua                  argument parsing, the REPL, rendering
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
