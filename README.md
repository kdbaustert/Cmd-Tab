# Cmd-Tab

A ⌘-Tab replacement for macOS, in the spirit of Command-Tab Plus 2. Switches between
**applications** or between **individual windows**, toggleable from the menu bar.

## Build

```sh
./build.sh            # produces build/Cmd-Tab.app
./build.sh --install  # also copies to /Applications and launches it
```

Requires Xcode. Built and tested against macOS 26.5 with Swift 6.3.

## First run

Grant **System Settings → Privacy & Security → Accessibility → Cmd-Tab**. Nothing happens
until you do — the app polls for the permission and stays inert meanwhile. It needs it twice
over: the event tap cannot receive keystrokes without it, and window mode cannot enumerate or
raise windows without it.

There is no Screen Recording prompt, because tiles are app icons rather than live window
thumbnails. Window *titles* come from the Accessibility API, not from `CGWindowListCopyWindowInfo`,
specifically so that second permission is never needed.

## Keys

| Key | Action |
| --- | --- |
| ⌘-Tab | Open the switcher / advance |
| ⌘-⇧-Tab | Go backwards |
| ⌘-← / ⌘-→ | Move the selection |
| ⌘-1 … ⌘-9 | Switch straight to that tile |
| ⌘-Q | Quit the selected app |
| Esc | Dismiss without switching |
| Release ⌘ | Switch to the selection |

The first nine tiles carry their number in the bottom-right corner. The number switches
immediately rather than moving the highlight — waiting for ⌘ to come up would make it slower than
the arrow keys. A digit past the end of the list does nothing, but is still swallowed: letting it
through would fire ⌘-7 in whatever app is sitting behind the panel.

Both the number row and the keypad work. The mapping is by physical key position, so it follows
the keys *labelled* 1–9 on ANSI-style layouts.

## Settings

**Menu bar → Settings…**, in two tabs.

### Appearance

Four sliders, which together are the entire `Metrics` the panel lays itself out from:

| Slider | Range | Default | What it moves |
| --- | --- | --- | --- |
| Icon size | 32–128 | 64 | Icon edge length. Window mode uses 75% of it, having given up room to the title, and scales in step. |
| Icon spacing | 0–48 | 18 | Slack around each icon, inside its highlight. Sets how far apart icons sit, and stacks with panel padding at the edges. |
| Panel padding | 0–36 | 10 | The frosted border above, below and beside the tiles — this is padding *inside* the glass. |
| Title spacing | 0–28 | 2 | Gap between an icon and its name: the caption in app mode, the in-tile title in window mode. |

Distance from an icon to the glass is `iconSpacing / 2 + panelPadding` — the two stack, which is
why tightening only one of them disappoints. The gap between neighbouring highlights is
`iconSpacing + tileGap`, and `tileGap` is deliberately not adjustable down to zero: touching
highlights read as one smeared blob rather than two tiles.

The preview is a real panel — same glass, same metrics, real icons — because the switcher itself
cannot be seen while the settings window is frontmost. Dragging a slider also resizes an
already-open switcher live.

Each value persists in `UserDefaults` (`iconSize`, `iconSpacing`, `panelPadding`, `titleSpacing`)
and is clamped on read, so a hand-edited plist cannot produce an unusable panel.

### Excluded apps

The Excluded Apps tab lists every running app with a switch to exclude it. Excluded apps never
appear in the switcher in either mode — excluding an app also removes all of its windows from
window mode.

Exclusions are keyed by bundle identifier, not pid, so they survive the app quitting, relaunching
under a new pid, and Cmd-Tab restarting. They persist in `UserDefaults` under `excludedBundleIDs`.

Excluded apps stay in the settings list even once they quit, so an exclusion can always be undone.
**Add App…** picks an app that isn't running, since by definition it can't be in the list. An app
with no bundle identifier can never be excluded — there is nothing stable to key it on.

## Switching to an app whose windows are all minimized

Activating an app whose windows are *all* minimized leaves you looking at its menu bar and an
empty desktop, so app mode restores one window on the way in. If anything of the app's is already
on screen, its arrangement is left alone. Window mode does not need this — there the specific
window is unminimized by name.

The restore runs off the main thread. `focus()` is called from inside the event tap callback, and
every Accessibility call is IPC that can block on a wedged app; the system kills a tap that
stalls. It also gets its own queue rather than `TargetProvider`'s, which can be busy enumerating
every window on the system — a restore stuck behind a full refresh would land visibly late.

### The AXDialog trap

**macOS reports a window's subrole as `AXDialog` while it is minimized.** The same window flips
`AXStandardWindow` → `AXDialog` on minimize and back on restore (verified on macOS 26.5 with
TextEdit):

| State | `AXRole` | `AXSubrole` | `AXMinimized` |
| --- | --- | --- | --- |
| Up | `AXWindow` | `AXStandardWindow` | `false` |
| Minimized | `AXWindow` | `AXDialog` | `true` |

So filtering windows on `AXSubrole == AXStandardWindow` silently drops every minimized window —
silently because an empty list is indistinguishable from an app that has no windows. That filter
is why minimized windows never used to appear in window mode at all, which in turn made the
minimized badge in `SwitcherView` unreachable.

`AX.isSwitchableWindow` therefore accepts a window that is either standard *or* minimized.
`AX.isWindow` is the broader role-only check, used when deciding whether anything of an app's is
on screen: an app showing only a dialog still has something up, and restoring a minimized window
over it would be wrong. The role check is also what keeps Finder's desktop — an `AXScrollArea`
that turns up in `AXWindows` — out of the list.

Note that Finder's own browser windows report `AXDialog` even while up, so they are still missed
in window mode. Unchanged from before, and not yet fixed.

## How the ⌘-Tab takeover works

The Dock owns ⌘-Tab at a level no public API can intercept, so taking it over is two moves:

1. **Disable the system switcher** via `CGSSetSymbolicHotKeyEnabled(1, false)` and `(2, false)`
   — symbolic hot key IDs for "move focus to next/previous application". This is a private
   SkyLight entry point, the same one AltTab and Command-Tab Plus rely on.
2. **Claim the keystroke** with a session-level `CGEventTap`, which swallows ⌘-Tab before the
   focused app sees it.

The private symbol is resolved with `dlsym`, not linked. If a future macOS drops it, we lose the
takeover and log it rather than failing to launch. Verified present on macOS 26.5; note that its
sibling `CGSGetSymbolicHotKeyEnabled` is *already gone* on this OS, which is why the disabled
state is tracked in-process rather than queried back.

### Getting your ⌘-Tab back

The state lives in the window server's memory and is never written to
`com.apple.symbolichotkeys`, so **logging out always restores it**, even after a crash. Short of
that: quit Cmd-Tab, or use **Restore System ⌘-Tab** in the menu bar. Quit, SIGTERM, SIGINT and
SIGHUP all restore it on the way out. SIGKILL and hard crashes cannot — log out.

## Signing

`build.sh` signs with a self-signed certificate called **Overtab Local** — the name is left over
from before the app was renamed, and is only a keychain label. Replacing it would change the
designated requirement and cost an Accessibility re-grant for no gain.

The certificate is what keeps the Accessibility grant alive across rebuilds. macOS keys the
permission to the app's *designated requirement*; signed with a certificate, that requirement is

```
identifier "com.cmdtab.CmdTab" and certificate leaf = H"<cert hash>"
```

— no code hash, so recompiling does not invalidate it. Ad-hoc signing has no certificate, so the
requirement falls back to the code hash and every build looks like a brand new app. `build.sh`
falls back to ad-hoc if the identity is missing, and says so.

To recreate the identity on another machine (or after deleting it):

```sh
openssl req -x509 -newkey rsa:2048 -sha256 -days 7300 -nodes \
  -keyout key.pem -out cert.pem \
  -subj "/CN=Overtab Local" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"

# -legacy and a non-empty password are both required; the security tool cannot read
# OpenSSL 3's default PKCS#12 encryption, and rejects an empty-password MAC.
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem \
  -out cmdtab.p12 -name "Overtab Local" -passout pass:cmdtab

security import cmdtab.p12 -k ~/Library/Keychains/login.keychain-db \
  -P cmdtab -T /usr/bin/codesign
# Trust is scoped to code signing only; without it codesign reports CSSMERR_TP_NOT_TRUSTED.
security add-trusted-cert -r trustRoot -p codeSign \
  -k ~/Library/Keychains/login.keychain-db cert.pem
```

Changing the certificate changes the requirement, so Accessibility has to be granted once more
after that. Remove the identity in Keychain Access to undo it.

## Known limitations
- Window ordering within an app follows Accessibility's z-order, not a true per-window MRU.
  Cross-app ordering *is* real MRU, tracked from activation notifications.
- Windows on other Spaces are listed, and switching to one follows macOS's normal Space-switch
  behavior.
- No live thumbnails, and no search-by-typing in the switcher itself.
- The settings window is the one place Cmd-Tab activates, so while it is frontmost *we* are the
  frontmost app and a ⌘-Tab lands one target further along than usual. Close it and ordering is
  normal again.

## Layout

| File | Role |
| --- | --- |
| `SystemSwitcher.swift` | The private SkyLight shim that disables the Dock's switcher |
| `EventTap.swift` | Session event tap; swallows keys, self-heals if the system disables it |
| `SwitcherController.swift` | State machine — decides what to swallow and when to commit |
| `TargetProvider.swift` | Enumerates apps/windows, maintains MRU, caches off-thread |
| `SwitcherPanel.swift` | Non-activating overlay window |
| `SwitcherView.swift` | SwiftUI tile grid |
| `SwitchTarget.swift` | An app or window, and how to raise it |
| `AX.swift` | Shared Accessibility helpers, with the messaging timeout baked in |
| `ExclusionStore.swift` | The set of excluded apps, persisted by bundle identifier |
| `AppearanceStore.swift` | The four appearance values, persisted |
| `SettingsWindow.swift` | Settings window — the appearance sliders and the exclusion list |
| `Migration.swift` | Carries settings over from the old Overtab bundle id; deletable in time |

## Design notes

The event tap callback runs on the main run loop, and the system kills a tap that stalls. Every
Accessibility call is IPC to another process and can block on a wedged app, so enumeration never
happens inside the callback: `TargetProvider` keeps a cache refreshed off-thread from workspace
notifications, the panel opens instantly from that cache, and a fresh list folds in a moment
later without moving the highlight. Per-app Accessibility messaging is capped at 250ms so one
hung app cannot hang the switcher.

The panel is a `.nonactivatingPanel` that never becomes key. If it activated, *we* would be the
frontmost app and the switch target would be wrong. It has no key handling at all — the event tap
is the only input path.

`flagsChanged` events are never swallowed. Other apps need to track modifier state, and it
guarantees releasing ⌘ always dismisses the panel even if the state machine gets confused.

## Renamed from Overtab

The app was called Overtab until the bundle identifier changed to `com.cmdtab.CmdTab`. That
identifier is also the `UserDefaults` domain, so `Migration.swift` copies the old settings across
on first launch — otherwise every tuned value would silently vanish. It never overwrites a value
the new build already has, and runs before any store is read.

The project directory is still `Developer/Overtab`, and the Swift target is `CmdTab` because a
module name cannot contain a hyphen. Only the bundle carries the hyphenated name.
