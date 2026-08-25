# NapCat

A tiny macOS menu bar cat that tells you — at a glance — what your Mac's
power state is, and gives you two switches that macOS hides:

- **The cat runs** when Stay Awake is on: your Mac will keep working with the
  lid closed (`pmset disablesleep`).
- **The cat curls up and sleeps** when Stay Awake is off: normal sleep
  behavior, nothing held open.
- **The cat sits** when charging is paused at your charge limit: plugged in,
  battery parked at (for example) 90%.

Original 18×18 pixel-art frames, rendered as template images so they follow
light/dark menu bars.

## Features

- **Stay awake with the lid closed**, on demand, from the menu bar. Verified
  by reading the system state back (`pmset -g`) — the menu never shows a
  cached guess.
- **Battery charge limit** (Apple Silicon only), slider 50–100% in steps
  of 5, default 90%. Charging pauses at the limit and resumes when the
  battery drifts 5 points below it.
- **Crash failsafe, three layers deep** — if NapCat dies, crashes, or the
  machine reboots mid-session, sleep is re-enabled automatically (details
  below).
- **Live battery panel**: percentage gauge, charging state, and all controls
  in one SwiftUI menu.
- **Launch at Login** via `SMAppService` — one toggle, one entry in
  System Settings › General › Login Items.
- **Claude Code awareness** (optional, opt-in): the menu shows whether a Claude
  turn is running, and NapCat can text you (iMessage to yourself) if the Mac
  starts sleeping while one still is — see
  [Claude busy detection](#claude-busy-detection-track-b--optional-read-only).
- **Debug battery simulator** so the whole charge-limit state machine can be
  driven without hardware (and provably without privileged calls).
- No Dock icon, no windows. Quit from the menu (⌘Q while it is open works).

## Requirements

- macOS 14 (Sonoma) or later. Developed and tested on a MacBook Pro 16"
  (M4 Pro, macOS Sequoia 15.6.1).
- Apple Silicon for the charge limit. Stay Awake also works on Intel.
- Xcode Command Line Tools to build (`xcode-select --install`).

## Install

```sh
git clone <this-repo> NapCat
cd NapCat
make            # swift build + assemble dist/NapCat.app (ad-hoc signed)
open dist/NapCat.app
```

The app runs immediately, but both power features need a **one-time
privileged setup** that you run yourself (the app never asks for or uses
your password):

```sh
make            # ensures dist/smc is built
sudo ./scripts/setup.sh
```

Until then, NapCat runs in a degraded mode: battery percentage and charging
state still display (plain IOKit reads), and the toggles explain that setup
is required.

### What setup.sh installs — exactly

Read [`scripts/setup.sh`](scripts/setup.sh) before running it; it is short
on purpose. It installs three things:

**1. `/etc/sudoers.d/napcat`** (0440, root:wheel, `visudo`-validated before
install) — eight NOPASSWD entries scoped to *your user only*, each one an
exact, immutable command string:

```
<you> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1
<you> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0
<you> ALL=(root) NOPASSWD: /usr/local/napcat/smc -k CH0B -w 02
<you> ALL=(root) NOPASSWD: /usr/local/napcat/smc -k CH0C -w 02
<you> ALL=(root) NOPASSWD: /usr/local/napcat/smc -k CHTE -w 01000000
<you> ALL=(root) NOPASSWD: /usr/local/napcat/smc -k CH0B -w 00
<you> ALL=(root) NOPASSWD: /usr/local/napcat/smc -k CH0C -w 00
<you> ALL=(root) NOPASSWD: /usr/local/napcat/smc -k CHTE -w 00000000
```

On Intel Macs only the two `pmset` lines are installed (charge limiting is
Apple Silicon-only, see below).

**2. `/usr/local/napcat/smc`** (755, root:wheel) — the SMC command-line
helper, copied from the `dist/smc` you just built. Apple Silicon only.

**3. `~/Library/LaunchAgents/com.napcat.failsafe.plist`** (0644, owned by
you) — a one-shot `RunAtLoad` agent that runs
`sudo -n /usr/bin/pmset -a disablesleep 0` at login. This is crash-failsafe
layer three (see below). It is installed but not loaded into the current
session, so it cannot interrupt anything you have running; it takes effect
from your next login.

The script is idempotent — run it again after updating and it only replaces
what changed.

## Security model

NapCat needs root for exactly two things: flipping `pmset disablesleep` and
writing two SMC keys. Instead of a privileged helper daemon or an
`AuthorizationExecuteWithPrivileges`-style prompt, it uses the smallest
mechanism macOS offers: **sudoers entries with exact argument matching.**

- **Fixed argv strings, nothing variable.** sudo's NOPASSWD matching is
  byte-exact over the full command line. The eight strings above are the
  *complete* set of privileged commands NapCat can ever run — there is no
  entry with arguments left open, so there is nothing to inject into. The
  charge limit slider does not change the privileged commands: percent
  thresholds are decided *inside the app*, which then issues one of the two
  fixed disable/enable writes. Try it after setup:
  `sudo -n pmset -a hibernatemode 25` is denied.
- **Root-owned target binary.** The smc helper is installed to
  `/usr/local/napcat/smc` owned by `root:wheel` — never inside the app
  bundle, which is user-writable and re-signed on every rebuild. A NOPASSWD
  target that the user can overwrite would be a self-service root shell;
  this one cannot be replaced without already being root.
- **`/usr/local` ownership requirement.** The path *to* the target matters
  as much as the target: if `/usr/local` were user-writable (some Intel-era
  Homebrew setups chown it), anyone could swap the whole `napcat` directory
  and plant their own `smc`. setup.sh refuses to install if `/usr/local` is
  not root-owned, is group/other-writable, or is a symlink.
- **Trust assumption: you build `smc` yourself.** setup.sh copies whatever
  `dist/smc` you built. The source is vendored in
  [`third_party/smc/`](third_party/smc/) with a pinned upstream commit and
  SHA-256 hashes ([PROVENANCE.md](third_party/smc/PROVENANCE.md)), so you
  can audit exactly what you are compiling — but the model is "the user
  builds and installs the helper", not "a signed binary from a trusted
  distributor". If you don't want to extend that trust, read the ~1200
  lines of `smc.c` first, or skip setup entirely.
- **Honest tradeoffs.** Anything running *as your user* can invoke the same
  eight commands once setup is installed — that is inherent to NOPASSWD
  sudoers and is the price of no password prompts. The blast radius is
  deliberately small: the worst any of the eight commands can do is keep
  the Mac awake, or pause/resume battery charging. None of them read data,
  write files, or accept variable arguments. If that tradeoff is not
  acceptable to you, don't run setup.sh — NapCat degrades gracefully.

## Crash-failsafe design

`disablesleep` is system state, not app state — it survives NapCat exiting.
So NapCat assumes it *will* die at the worst moment and layers three
independent reverts:

1. **Clean path** — quitting the app (menu, ⌘Q, SIGTERM, SIGINT, logout)
   reverts `disablesleep` and re-enables charging before exit.
2. **Watchdog** — while Stay Awake is on, a tiny shell script polls the
   app's PID every 5 seconds. `kill -9` the app and sleep is re-enabled
   within ~5 seconds — and charging is un-paused too, if the privileged
   helper is installed. The watchdog is handed the PID explicitly (not
   PPID — orphaned processes get reparented) and stale watchdogs are reaped
   at launch.
3. **Login failsafe LaunchAgent** — covers crash-then-reboot: if the machine
   went down with sleep disabled and nothing above got to run,
   `com.napcat.failsafe` clears `disablesleep` once at the next login. The
   app *never* auto-enables Stay Awake at launch, so this cannot race a
   real session.

On top of the three layers, NapCat reconciles at every launch and every menu
open: the UI shows the *observed* `pmset -g` state, never a stored intent.
If you flip `disablesleep` outside the app, the menu reflects it on the next
open.

## Stay Awake — what is actually claimed

Tested on an M4 Pro MacBook Pro, macOS Sequoia 15.6.1: with Stay Awake on,
the machine keeps running **with the lid closed, on battery, with no
external display attached** (verified via SSH and `pmset -g log` across the
closed-lid window). That is the strong case — closed-lid *without* being
docked — and it works on Apple Silicon.

A one-time warning is shown before the first enable, because it is real: a
closed, running MacBook in a bag or on a duvet can get hot. Give it
ventilation, and turn Stay Awake off before packing it away. If you forget,
the failsafes above mean a crash or reboot won't leave sleep disabled
forever — but a running NapCat with Stay Awake on will happily keep the
machine awake, as designed.

## Charge limit — behavior and caveats

- **Apple Silicon only.** Intel charge control uses the `BCLM` SMC key,
  which is blocked on macOS 15+, and its variable values are incompatible
  with the exact-argument sudoers model above. Rather than ship something
  half-broken, Intel gets a disabled control with an explanation. Stay
  Awake is unaffected on Intel.
- **How it pauses.** NapCat probes at runtime which SMC key family your
  machine uses (`CHTE` on recent macOS, `CH0B`/`CH0C` on older systems) and
  writes the corresponding disable/enable values. Every write is verified
  by reading the key back, and a pause is additionally confirmed by
  watching the charging flag actually drop within 60 seconds — a failed
  write shows an error in the menu, never a false "paused".
- **Hysteresis.** Charging pauses at ≥ limit and resumes at ≤ limit − 5, so
  it does not flap around the threshold. A limit of 100 means "no limit".
  Unplugging, disabling the feature, or an unreadable battery all release
  the pause explicitly — NapCat fails open, never holding charging off
  blindly.
- **Not enforced when the app is not running.** The limit is a userspace
  loop, not firmware. If NapCat is quit while paused, it re-enables
  charging on the way out; if it crashes while Stay Awake is on, the
  watchdog re-enables charging within ~5 seconds; otherwise the next
  launch reconciles. But
  while it simply isn't running, nothing pauses charging — enable **Launch
  at Login** so it is always on duty. There is also a 60-second re-assert
  while paused, because macOS has been observed re-enabling charging on its
  own.
- **Optimized Battery Charging.** macOS's own OBC may hold the battery at
  80% with its own logic. The two don't conflict destructively — NapCat
  holds its pause regardless of what percentage OBC parks the battery at —
  but for predictable behavior you may want to disable OBC while using a
  custom limit (System Settings › Battery).
- **macOS 26.4+ has this built in.** macOS Tahoe 26.4 added a native charge
  limit (80/85/90/95/100%) in System Settings › Battery. On those systems,
  prefer the native control — NapCat's limiter exists because Sonoma and
  Sequoia have no user-facing equivalent.

## Uninstall

```sh
sudo ./scripts/uninstall.sh
```

Idempotent and thorough even after partial failures: clears `disablesleep`,
re-enables charging (before deleting the helper it needs to do so), then
removes the sudoers file, `/usr/local/napcat`, and the failsafe LaunchAgent,
and prints a summary of everything it reverted. Then delete the repo /
`dist/NapCat.app` and, if you enabled Launch at Login, remove the NapCat
entry in System Settings › General › Login Items (or toggle it off in the
menu before uninstalling).

Manual equivalent:

```sh
sudo pmset -a disablesleep 0
sudo /usr/local/napcat/smc -k CHTE -w 00000000   # or CH0B/CH0C -w 00 on older systems
sudo rm /etc/sudoers.d/napcat
sudo rm -rf /usr/local/napcat
launchctl bootout gui/$UID/com.napcat.failsafe 2>/dev/null
rm -f ~/Library/LaunchAgents/com.napcat.failsafe.plist
```

## Debug battery simulator

The entire power interface (reads *and* writes) can be swapped for an
in-memory simulator — useful for exercising the charge-limit state machine
on a desktop or without touching real hardware:

```sh
defaults write com.muratalkan.napcat debugBattery -bool YES
# restart NapCat — the key is read once at startup
```

A "Debug — Simulated Battery" section appears in the menu with a percent
slider and an AC toggle. In this mode NapCat performs zero IOKit reads and
zero privileged calls — the simulator source file has no imports at all,
and a test fails if any subprocess-capable API ever appears in it.

```sh
defaults delete com.muratalkan.napcat debugBattery   # and restart again
```

## Claude busy detection (Track B — optional, read-only)

NapCat can show whether a Claude Code turn is in flight, whether Claude is
holding your Mac awake, and how recently the companion hook last fired — a new
**Claude** section in the menu. It can also **text you** if the Mac starts
sleeping while a Claude task is still running (see "Text me if the Mac sleeps
mid-task" below). Everything here is unprivileged: no `sudo`, no new privileged
commands, no elevated helper.

It works by way of a tiny **companion Claude Code hook** that drops a per-session
marker file under `~/Library/Application Support/NapCat/claude-busy/` while a turn
is running and removes it when the turn ends. When the main turn ends but a
**background subagent** is still running, the hook keeps the marker until the last
subagent finishes (it reconciles on the `background_tasks` the `Stop`/`SubagentStop`
events carry), so NapCat still shows **running** during orchestrator-plus-subagent
work. NapCat only reads those markers (cross-checked against the live process list,
fail-open so it never falsely reports "idle"). This is separate from the standalone
*[redacted-tool]* tool.

### Install and register — BY HAND

```sh
./scripts/install-claude-busy-hook.sh
```

That copies the hook to the stable path `~/.claude/hooks/napcat-busy-hook.sh`
(so `make clean` never removes it), creates the marker directory, and **prints**
the exact registration to paste into `~/.claude/settings.json`. The installer
never edits `settings.json` itself. Merge these six entries into your existing
`"hooks"` object (replace `<HOME>` with your home directory — the installer
prints the absolute paths for you):

```json
"UserPromptSubmit": [ { "hooks": [ {"type":"command","command":"/usr/bin/env","args":["-i","HOME=<HOME>","/bin/bash","<HOME>/.claude/hooks/napcat-busy-hook.sh"],"timeout":5} ] } ],
"Stop":            [ { "hooks": [ {"type":"command","command":"/usr/bin/env","args":["-i","HOME=<HOME>","/bin/bash","<HOME>/.claude/hooks/napcat-busy-hook.sh"],"timeout":5} ] } ],
"StopFailure":     [ { "hooks": [ {"type":"command","command":"/usr/bin/env","args":["-i","HOME=<HOME>","/bin/bash","<HOME>/.claude/hooks/napcat-busy-hook.sh"],"timeout":5} ] } ],
"SubagentStop":    [ { "hooks": [ {"type":"command","command":"/usr/bin/env","args":["-i","HOME=<HOME>","/bin/bash","<HOME>/.claude/hooks/napcat-busy-hook.sh"],"timeout":5} ] } ],
"SessionEnd":      [ { "hooks": [ {"type":"command","command":"/usr/bin/env","args":["-i","HOME=<HOME>","/bin/bash","<HOME>/.claude/hooks/napcat-busy-hook.sh"],"timeout":5} ] } ],
"Notification":    [ { "matcher":"idle_prompt", "hooks": [ {"type":"command","command":"/usr/bin/env","args":["-i","HOME=<HOME>","/bin/bash","<HOME>/.claude/hooks/napcat-busy-hook.sh"],"timeout":5} ] } ]
```

The `SubagentStop` entry is what keeps NapCat showing **running** while a
background subagent is still working after the main turn ends (the
orchestrator-plus-subagents workflow). **If you registered an earlier version of
this hook, add the `SubagentStop` entry** — the others are unchanged — and start a
new Claude Code session so it loads.

**The exec form (`/usr/bin/env -i HOME=… /bin/bash …`) is a security requirement,
not cosmetic.** `env -i` strips `$BASH_ENV` and every exported `BASH_FUNC_*`
before bash starts; registering the bare script path (shell form) would let those
run attacker code before the hook's own safeguards ever execute. Paste it exactly.
Hooks load at session start, so **open a new Claude Code session** afterward.

The hook is written so a bug in it can never break your Claude Code session: it
always exits 0, never prints to stdout, does its marker write in the background,
and does nothing at all if a kill-switch flag is present.

### Kill switch

Pause detection at any time from the menu (**Claude → Pause detection**), or by
hand:

```sh
touch "$HOME/Library/Application Support/NapCat/claude-busy/DISABLED"   # pause
rm    "$HOME/Library/Application Support/NapCat/claude-busy/DISABLED"   # resume
```

While the flag exists the hook no-ops immediately.

### Uninstall — BY HAND

```sh
./scripts/uninstall-claude-busy-hook.sh
```

Removes the installed hook and the marker directory and prints which
`settings.json` entries to delete. Like the installer, it never edits
`settings.json`; delete the six NapCat entries yourself and restart Claude Code.

### Text me if the Mac sleeps mid-task

The classic mistake this guards: you turn **Stay Awake** off, close the lid a
minute later, and only discover hours afterwards that the long Claude run died
with the machine. When it is armed, NapCat notices the sleep starting, checks
that a Claude turn is actually in flight, and hands one **iMessage to yourself**
to Messages before the Mac goes down.

It is **notify-only**: it never controls Claude, never changes sleep or charging
state, never arms itself, and never sends anything but its own fixed sentence.

**Set it up (all in the menu, Claude section):**

1. **Set recipient…** — enter *your own* iMessage address: the phone number or
   Apple ID you use on your iPhone. NapCat only ever messages that address.
2. Turn **Text me if the Mac sleeps mid-task** on.
3. **Send test message** — macOS asks *"NapCat wants to control Messages"*.
   Allow it. This is deliberate and required: it answers the permission prompt
   while you are sitting there, and it creates the conversation with yourself.
   **The feature does not arm until a test message succeeds** — otherwise the
   very first send would be the lid-close one, blocking on a prompt nobody is
   there to answer.

The menu then shows a persistent status row: whether Messages access is allowed,
and the outcome and time of the last message.

**What it actually promises — read this.**

- **Best effort, not guaranteed.** NapCat holds the sleep for about 1.5 seconds,
  which is enough to hand the message to Messages — *not* enough to guarantee
  Apple's servers received it. If the Mac sleeps first, the send usually
  completes when it wakes. The menu says "handed to Messages", never "sent",
  on purpose.
- **A deliberate sleep texts you too.** NapCat cannot tell a closed lid from
  Apple menu → Sleep. If a Claude task is running and Stay Awake is off, both
  send the message.
- **Not while Stay Awake is on** (the Mac is not really sleeping on you), not
  when no Claude turn is in flight, and at most once every 15 minutes.
- **Re-run the test message after an update.** Every `make` re-signs the app
  with a fresh ad-hoc signature, and macOS usually revokes the Messages
  permission when that happens. The menu shows it; the fix is one click.
- **If the permission gets stuck**, reset it and run the test message again:

  ```sh
  tccutil reset AppleEvents com.muratalkan.napcat
  ```

**How it works, briefly.** NapCat registers for system power notifications
(`IORegisterForSystemPower`) *only while armed* — switched off, it has no
presence on the sleep path at all. The message itself is sent by a fixed
AppleScript shipped inside the app bundle, invoked as
`/usr/bin/osascript <script> <recipient> <body>`; both values are passed as
arguments, never pasted into the script, and the body is built by NapCat from a
fixed template plus the time and the number of busy sessions. **Nothing from
your Claude conversation, prompts, or file paths can reach a message** — the
sending API has no free-text parameter at all.

### Honest limitations

- **Best-effort markers.** If a Claude session ends uncleanly a marker may linger;
  markers older than 12 h are ignored and swept automatically, and the live
  process cross-check suppresses "running" when no Claude process is present.
- **Classification is heuristic.** A process whose executable basename is exactly
  `claude` is confirmed; `node` and other claude-adjacent images are treated as
  "uncertain" (which keeps a real marker standing rather than dropping it).
- **The lid alert can miss.** If NapCat cannot read the sleep state or sample
  Claude quickly enough as the machine goes down, it stays quiet rather than
  guessing — with one exception: if the sleep state is unreadable but a Claude
  task *is* running, it errs toward texting you.

## Development

```sh
make            # release build + assemble dist/NapCat.app + ad-hoc codesign
make run        # build, then (re)launch the app
make test       # unit tests (Swift Testing)
make frames     # re-render the pixel-art frames from in-code grids
make smc        # build the vendored smc CLI to dist/smc
make clean      # remove .build/ and dist/
```

Notes:

- **Use `make test`, not bare `swift test`.** On machines with Command Line
  Tools only (no Xcode.app), SwiftPM passes the Testing framework path
  incorrectly to its derived test runner and `swift test` exits 0 having
  executed *zero* tests. `make test` passes the framework flags explicitly
  so the tests really run. (With full Xcode installed both work.)
- Clean checkouts build offline with `make` alone — no package
  dependencies, no network.
- Frames are committed *and* regenerable: `scripts/render_frames.swift`
  emits byte-deterministic PNGs, so `make frames` leaves a clean
  `git status` unless the pixel grids actually changed.
- History is tagged at phase boundaries (`v0.1.0` scaffold, `v0.2.0` stay
  awake, `v0.3.0` charge limit, `v0.4.0` animation, `v1.0.0` polish); the
  full build plan, architecture decisions, and verification matrix live in
  [PLAN.md](PLAN.md).

## License and attribution

- **NapCat itself** is licensed under the **MIT License** — see
  [LICENSE](LICENSE).
- **`third_party/smc/`** (unchanged, not covered by NapCat's MIT license):
  the SMC command-line tool is vendored from
  [hholtmann/smcFanControl](https://github.com/hholtmann/smcFanControl)
  (`smc-command/`, pinned at commit
  `e1bd672bcd2d72eddff9b6da7b9cae38e35c4206`, unmodified) and is licensed
  under **GPL-2.0** — see [third_party/smc/LICENSE](third_party/smc/LICENSE)
  and [third_party/smc/PROVENANCE.md](third_party/smc/PROVENANCE.md). The
  `smc` binary is built and installed as a separate standalone program
  invoked via `sudo`; it is not linked into NapCat.
- The pixel-art cat frames are original artwork drawn for this project.
