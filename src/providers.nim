import std/[os, strutils]
import luigi, resultspane, commands, menubar, config

type
  PathList = object
    list: seq[string]

var
  theRecentsState: PathList
  theProjectsState: PathList
  theProvidersPane: ptr ResultsPane

proc tildify(p: string): string =
  let h = getHomeDir()
  if h.len > 0 and p.startsWith(h):
    "~/" & p[h.len .. ^1]
  else:
    p

# ---------- recents (file-recents) ----------

proc refreshRecents() =
  theRecentsState.list = config.readRecents("recents.files")

proc refreshProjects() =
  theProjectsState.list = config.readRecents("recents.projects")

proc pathRowCount(s: pointer): int {.nimcall.} =
  cast[ptr PathList](s).list.len

proc pathRowText(s: pointer, i: int): string {.nimcall.} =
  let st = cast[ptr PathList](s)
  if i < 0 or i >= st.list.len: ""
  else: tildify(st.list[i])

proc recentsOnSelect(s: pointer, i: int) {.nimcall.} =
  let st = cast[ptr PathList](s)
  if i < 0 or i >= st.list.len: return
  discard runCommand("editor.open", @[st.list[i]])

proc recentsProvider*(): Provider =
  Provider(
    state: cast[pointer](addr theRecentsState),
    name: "recents",
    rowCount: pathRowCount,
    rowText: pathRowText,
    onPaintRow: nil,
    onSelect: recentsOnSelect,
    onContext: nil,
    onKey: nil,
    onBack: nil)

# ---------- projects (project-recents) ----------

proc projectsOnSelect(s: pointer, i: int) {.nimcall.} =
  let st = cast[ptr PathList](s)
  if i < 0 or i >= st.list.len: return
  discard runCommand("project.load", @[st.list[i]])

proc projectsProvider*(): Provider =
  Provider(
    state: cast[pointer](addr theProjectsState),
    name: "projects",
    rowCount: pathRowCount,
    rowText: pathRowText,
    onPaintRow: nil,
    onSelect: projectsOnSelect,
    onContext: nil,
    onKey: nil,
    onBack: nil)

# ---------- help (registered command listing) ----------

proc helpRowCount(s: pointer): int {.nimcall.} =
  commands.registry.len

proc helpRowText(s: pointer, i: int): string {.nimcall.} =
  if i < 0 or i >= commands.registry.len: ""
  else: commands.registry[i].name

proc helpOnSelect(s: pointer, i: int) {.nimcall.} =
  if i < 0 or i >= commands.registry.len: return
  openPaletteWith(":" & commands.registry[i].name & " ")

proc helpProvider*(): Provider =
  Provider(
    state: nil,
    name: "help",
    rowCount: helpRowCount,
    rowText: helpRowText,
    onPaintRow: nil,
    onSelect: helpOnSelect,
    onContext: nil,
    onKey: nil,
    onBack: nil)

# ---------- install ----------

proc swapTo(prov: Provider) =
  if theProvidersPane == nil: return
  if theProvidersPane.current.name == prov.name:
    paneResetSelection(theProvidersPane)
  else:
    panePushProvider(theProvidersPane, prov)
  if theProvidersPane.e.window != nil:
    elementFocus(addr theProvidersPane.e)

proc providersInstall*(pane: ptr ResultsPane) =
  theProvidersPane = pane
  registerCommand("recents", proc(args: seq[string]) =
    refreshRecents()
    swapTo(recentsProvider()))
  registerCommand("projects", proc(args: seq[string]) =
    refreshProjects()
    swapTo(projectsProvider()))
  registerCommand("help", proc(args: seq[string]) =
    swapTo(helpProvider()))
