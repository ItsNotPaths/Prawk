<p align="center">
  <img src="assets/prawk-logo.svg" alt="prawk" width="220">
</p>

A tiny X11 dev environment using nakst/luigi.c: file tree, tabbed editor with syntax highlighting, N
embedded terminals, a git pane, and a master command-line. Linux x86_64. ~250 KB
stripped binary, single file. Runtime deps: `libX11`, `libfreetype.so.6`, `git`,
`xclip`, `fc-match`.

![alt text](https://files.paths.place/prawk-ss-1.png)
![alt text](https://files.paths.place/prawk-ss-2.png)
![alt text](https://files.paths.place/prawk-ss-3.png)


## Run

```
./prawk              # open at $PWD
./prawk path/to/dir  # open with that as the project root
./prawk path/to/file # open with the file's parent as the project root
```

Config (optional): `~/.config/prawk/config` — see [Config](#config) below.

## Keybinds

### Pane navigation
| Key | Action |
|---|---|
| `Alt+H` / `Alt+L` | Move column left / right |
| `Alt+J` / `Alt+K` | Move within sidebar (tree ↔ git) and terminal stack |
| `Alt+Up` / `Alt+Down` | Editor ↔ tab strip |
| `Alt+T` / `Alt+Shift+T` | Cycle terminals forward / back |
| `Alt+N` | New terminal |
| `Alt+Q` | Close active editor tab (if editor focused) / kill terminal (if terminal focused) |
| `Alt+Shift+P` | Lock / unlock the focused terminal (skipped on project change) |
| `Alt+M` | Toggle minimap |
| `Alt+Z` | Toggle soft-wrap in the editor |

### Master command line (Alt+C)
| Key | Action |
|---|---|
| `Alt+C` | Focus the menubar CL |
| `Alt+F` / `Alt+E` / `Alt+V` | Open File / Edit / View menu |
| `Alt+W` | Inject `:jump ` into the CL |
| `Esc` | Close CL, restore prior focus |
| `Enter` | Dispatch (registered command → `tN` / `t` prefix → shell) |

The CL is a real shell with its own headless PTY. `cd` is plain shell behavior
— it changes the CL shell's cwd and nothing else. To broadcast that location to
the rest of the IDE (tree, git pane, unlocked terminals), run `:terminal.update`
(alias `:tu`); with no arg it reads the CL's actual cwd via `/proc/<pid>/cwd`,
with a path arg it targets that path. Output flowing through the CL is parsed
for `path:line[:col]:text` hits and shown in a `grep` results pane.

**When something is injected into the CL** (e.g. tree right-click, projects
recents, dirty-tab close prompt, `Alt+W` jump), the palette gets a red outline
(theme key `cl_inject`) — visual cue that the buffer wasn't typed by you. The
outline clears on the first keystroke or when you Esc/Enter.

**Prefixes**:
- `t <cmd>` — skip every hijack (registered commands, `ls`→files, etc.) and
  pipe the rest straight to the CL shell. E.g. `t ls` lists the cwd literally
  instead of swapping to the file provider.
- `tN <cmd>` — route `<cmd>` to terminal N (1-based) in the right-stack
  instead of the CL shell. E.g. `t1 ls` runs `ls` inside terminal 1; `t2 vim
  foo.nim` opens vim inside terminal 2. Focuses that terminal afterwards.

### Editor
| Key | Action |
|---|---|
| `Ctrl+S` | Save |
| `Ctrl+C` / `Ctrl+V` | Copy / paste (xclip) |
| `Ctrl+Shift+A` | Select all |
| `Ctrl+F`/`B`/`N`/`P`/`A`/`E` | Emacs-style char/line/start/end motion |
| `Shift+Alt+H`/`L`/`Left`/`Right` | Word / page motion |
| `Alt+J` / `Alt+K` | Jump N lines (default 10, `cursor_jump_lines`) |
| `Insert` | Toggle insert (block) / normal (thin line) cursor |
| Mouse drag | Select; copies to PRIMARY on release |

### Terminal
| Key | Action |
|---|---|
| `Ctrl+C` | Copy if a selection is held; else SIGINT (in `ide` mode) |
| `Ctrl+Shift+C` | SIGINT escape hatch (`ide` mode) / copy (`legacy` mode) |
| `Ctrl+V` | Paste |
| Mouse drag / `Shift+Arrow` | Extend selection over the visible grid |

### Tree / results pane
| Key | Action |
|---|---|
| `j` / `k` / `Up` / `Down` | Move selection |
| `Enter` | Activate (open file, expand/collapse dir, swap provider) |
| `Right` / `Left` | Expand / collapse dir |
| `Shift+Enter` / right-click on dir | Inject `:tu <path>` into the CL |
| `Esc` | Pop back to previous provider (e.g. shell results → tree) |

### Git pane
| Key | Action |
|---|---|
| `j` / `k` / `Up` / `Down` | Move within the focused subsection |
| `Tab` | Toggle status ↔ log focus |
| `Enter` | Status row → working-tree diff; commit row → expand; file row → commit-file diff |
| `Left` / `Right` | Cycle branch tabs |

## Commands

| Command | What it does |
|---|---|
| `:files` / `:tree` | Show the file tree in the results pane |
| `:recents` | Recently opened files |
| `:projects` | Recent project roots |
| `:help` | Browseable command list |
| `:cl` | Scrollback of the CL shell |
| `:grep <pattern>` | `grep -rn` across the project; obeys `grep_ignore` |
| `:jump <N>` / `:j <N>` / `:j +N` / `:j -N` | Jump to absolute / relative line |
| `:theme <name>` | Switch theme (`default`, `zenburn`) |
| `:minimap` | Toggle minimap |
| `:reader [on\|off]` | Toggle reader mode (hide terminal column) |
| `:terminal.update [path]` / `:tu [path]` | Broadcast a target dir to tree, git pane, and unlocked terminals. Bare form uses the CL's current cwd. |
| `:editor.open <path>` / `:editor.save` | Open / save |
| `:tab.next` / `:tab.prev` / `:tab.close` | Tab management |
| `:term.new [name]` / `:term.kill <n>` / `:term.name <n> <name>` | Terminal stack ops |
| `:lock <n>` (`:termlock`) | Toggle per-terminal lock |
| `:gst` / `:glog [branch]` / `:gbr` / `:gco <name>` / `:gshow <hash>` / `:gdiff [path]` | Git ops |
| `:quit` | Exit |

## Config

`~/.config/prawk/config` — one `key: value` per line. Defaults shown.

```
tab_mode: spaces4              # spaces2 | spaces4 | tab
initial_focus: tree            # tree | editor | terminal
initial_terminals: 2
initial_term: 0
theme: default                 # default | zenburn
line_numbers: global           # off | global | relative
cursor_jump_lines: 10
cursor_mode: insert            # insert | normal
clear_on_project_cd: false     # also `clear` after cd on project change
terminal_copy_paste: ide       # ide (Ctrl+C copies if selection) | legacy
minimap: on
grep_ignore: vendor,build,.git,node_modules
```

Other state:

- `~/.config/prawk/recents.files` — last 10 opened files
- `~/.config/prawk/recents.projects` — last 10 project roots
- `~/.config/prawk/session` — terminal count + names (one per line)

## Themes & syntax

**Themes** are loaded at runtime from the `themes/` folder next to the binary —
drop a `.theme` file in there and it shows up in `:theme <name>` and the View
menu. Ships with `default` and `zenburn`.

**Syntax** grammars are embedded at compile time. Built-in: `nim`, `c`, `python`,
`js`, `diff`. To add a language, drop a `.conf` in `syntax/`, register it in
`highlight.nim`, and open a PR on GitHub.

## Build

```
./download-deps.sh
./release.sh --local
```

Produces `../prawk-release/prawk`.

## License

GPLv3 — see `gpl-3.0.txt`.
