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
- **Lock Screen**, one click (the lock icon next to Quit): NapCat locks your session, confirms the screen
  really is locked, and only then turns the display off — your Mac keeps
  running the whole time, which is the point when Stay Awake is on (walk away
  or close the lid without stopping the work in progress). The order matters:
  lock → verify → dark, so a failure can never leave you with a dark screen on
  an *unlocked* Mac; if the lock cannot be confirmed within two seconds the
  display stays on and NapCat tells you. It needs no privileges of any kind
  (no `sudo`, no setup) but it does use one private macOS entry point
  (`SACLockScreenImmediate` in `login.framework`), resolved at runtime — the
  lock is verified through the public `CGSessionCopyCurrentDictionary()`. If a
  future macOS drops that entry point, the button simply shows as disabled
  with an explanation instead of misbehaving.
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
  turn is running, and NapCat can push a notification to your phone (via ntfy)
  if the Mac starts sleeping while one still is — see
  [Claude busy detection](#claude-busy-detection-track-b--optional-read-only).
- **Session alerts (ntfy)** — a push when a Claude Code session finishes (main
  turn plus any background subagents) or stops to wait for your input; same
  topic as the lid alert — see
  [Session alerts](#session-alerts--finish-and-waiting-pushes).
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
git clone https://github.com/MuratAlkan06/NapCat.git NapCat
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

Before you run it:

- **You need an administrator account.** On a stock macOS install only admin
  users may use `sudo`; from a standard account setup.sh cannot run at all.
- **Run it with `sudo` from your own account**, not from a root shell.
  setup.sh scopes every entry to the user who invoked `sudo` (`$SUDO_USER`)
  and refuses to run if that is unset or `root`.
- **Your short user name must match `^[a-z_][a-z0-9_-]*$`**: lowercase
  letters, digits, `_` and `-`, starting with a letter or `_`. The name is
  written into a sudoers rule, so setup.sh refuses anything else (a short
  name with a dot or an uppercase letter, for example) and also refuses a
  user that does not exist. Check yours with `id -un`.
- **Symlinked home folders are refused.** setup.sh will not write through a
  symlinked `~/Library` or `~/Library/LaunchAgents` (a defense against
  privilege-escalation traps), and it stops with a `chown` hint if your
  `LaunchAgents` folder exists but is not owned by you — common with some
  dotfiles setups. Fix the ownership or the symlink, then re-run.

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

### Verify what was installed

Don't just trust the script's output. Check the result yourself:

```sh
sudo cat /etc/sudoers.d/napcat                          # root-only file, hence sudo
ls -l /usr/local/napcat/smc                             # Apple Silicon only: root wheel, -rwxr-xr-x
ls -l ~/Library/LaunchAgents/com.napcat.failsafe.plist  # owned by you
```

The sudoers file should contain a short comment header and then exactly the
entries listed above, with your user name in place of `<you>` (two entries on
Intel). Anything more means something other than setup.sh edited it.

> **Never widen these entries by hand.** Do not "simplify" them to something
> like `/usr/bin/pmset *` or `/usr/local/napcat/smc *`, and never add
> wildcards or drop arguments. A wildcard turns a few fixed, harmless commands
> into arbitrary `pmset` settings and arbitrary SMC writes as root, with no
> password, for anything running as you. If an entry looks wrong, re-run
> `sudo ./scripts/setup.sh` (it rewrites the file whenever it differs) or
> remove everything with `sudo ./scripts/uninstall.sh`.

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
removes the sudoers file, `/usr/local/napcat`, the failsafe LaunchAgent, and
NapCat's saved settings (including the ntfy topic), and prints a summary of
everything it reverted. Then delete the repo /
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
defaults delete com.muratalkan.napcat             # as yourself, not with sudo
```

Don't skip the last line: NapCat's settings include the ntfy topic, which is a
bearer credential (anyone who has it can read and post to your feed).

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
holding your Mac awake, and how recently the companion hook last fired — the
menu's bottom row reads **Claude: running**, **idle** or **paused**, and clicking
it opens **Details** with the rest. It can also **push a notification to your phone**
if the Mac starts sleeping while a Claude task is still running (see "Notify me
if the Mac sleeps mid-task" below). Everything here is unprivileged: no `sudo`,
no new privileged commands, no elevated helper.

It works by way of a tiny **companion Claude Code hook** that drops a per-session
marker file under `~/Library/Application Support/NapCat/claude-busy/` while a turn
is running and removes it when the turn ends. When the main turn ends but a
**background subagent** is still running, the hook keeps the marker until the last
subagent finishes (it reconciles on the `background_tasks` the `Stop`/`SubagentStop`
events carry), so NapCat still shows **running** during orchestrator-plus-subagent
work. NapCat only reads those markers (cross-checked against the live process list,
fail-open so it never falsely reports "idle").

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
"Notification":    [ { "hooks": [ {"type":"command","command":"/usr/bin/env","args":["-i","HOME=<HOME>","/bin/bash","<HOME>/.claude/hooks/napcat-busy-hook.sh"],"timeout":5} ] } ]
```

The `SubagentStop` entry is what keeps NapCat showing **running** while a
background subagent is still working after the main turn ends (the
orchestrator-plus-subagents workflow). The `Notification` entry has **no
matcher**: the hook tells waiting-on-you notifications (a permission prompt, an
MCP input request) apart from idle ones, keeping the session busy while Claude
waits for you, so it needs to receive every notification type. **If you
registered an earlier version of this hook**, add the `SubagentStop` entry,
remove `"matcher":"idle_prompt",` from your `Notification` entry, re-run
`./scripts/install-claude-busy-hook.sh` to refresh the installed script, and
start a new Claude Code session so it loads.

**The exec form (`/usr/bin/env -i HOME=… /bin/bash …`) is a security requirement,
not cosmetic.** `env -i` strips `$BASH_ENV` and every exported `BASH_FUNC_*`
before bash starts; registering the bare script path (shell form) would let those
run attacker code before the hook's own safeguards ever execute. Paste it exactly.
Hooks load at session start, so **open a new Claude Code session** afterward.

The hook is written so a bug in it can never break your Claude Code session: it
always exits 0, never prints to stdout, does its marker write in the background,
and does nothing at all if a kill-switch flag is present.

### Kill switch

Pause detection at any time from the menu (**Details → Pause detection** — kept
behind the Details disclosure so it cannot be flipped by accident), or by hand.
While it is paused the menu's bottom row reads **Claude: paused** with a warning sign, and an armed
lid alert reads "armed — but Claude detection is paused; alerts cannot fire":
with no busy markers, the alert can never fire. Pausing detection silences
**Session alerts** too — no finish or waiting push goes out until you resume.

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

### Notify me if the Mac sleeps mid-task

The classic mistake this guards: you turn **Stay Awake** off, close the lid a
minute later, and only discover hours afterwards that the long Claude run died
with the machine. When it is armed, NapCat notices the sleep starting, checks
that a Claude turn is actually in flight, and pushes one notification to your
phone via [ntfy](https://ntfy.sh) before the Mac goes down.

It is **notify-only**: it never controls Claude, never changes sleep or charging
state, never arms itself, and never sends anything but its own fixed sentence.

> **Why ntfy and not iMessage?** NapCat originally texted you an iMessage. Two
> things killed that: iOS suppresses notification *banners* for messages you send
> to yourself (the text arrived, but silently — exactly the one thing this
> feature exists to do), and the AppleScript path only worked while Messages.app
> was open, which is not something you can assume as a Mac goes to sleep. ntfy
> has neither problem, needs no Automation permission, and survives rebuilds.

**Set it up:**

1. Install the **ntfy** app on your iPhone or Android phone (App Store / Play
   Store / F-Droid), or just open <https://ntfy.sh> in a browser.
2. Invent a **topic name** and subscribe the app to it. ⚠️ **The topic name is
   the password.** ntfy has no accounts, so anyone who guesses your topic can
   read *and* post to it. Use something long and random — the shape is
   `napcat-<paste-your-own-random-suffix>`, not `napcat`. Generate the suffix
   rather than typing one you thought of (`openssl rand -hex 8` is enough), and
   **do not copy any example from this README or from the app**: an example
   everybody can read is a feed everybody can read. Allowed: letters, digits,
   `_` and `-`, up to 64 characters.
3. In the NapCat menu open **Details** and click **ntfy settings…**, paste the topic,
   and leave the server as `https://ntfy.sh` unless you run your own instance.
   A custom server must be an `https://` origin and nothing more — no path,
   query, fragment, or `user@` part, and a plain ASCII host name or IP address
   (`https://ntfy.example.com:8443`). Anything else is refused with an
   explanation in the dialog rather than half-saved.
4. Turn the **Lid alert** toggle on.
5. **Send test message** (under **Details**; switching the toggle on with an
   untested topic sends one automatically) — your phone should show a banner
   within a couple of seconds. **The feature does not arm until a test message
   is accepted**, so the lid-close alert is never the first thing your topic is
   trusted with.

The menu then shows a status line under the toggle (whether it is armed) and,
under **Details**, the outcome and time of the last message — which moves up next
to the toggle whenever it is a failure. It deliberately never displays the topic
itself.

You can check a topic from the terminal without NapCat:

```sh
curl -d "hello from the terminal" https://ntfy.sh/<your-topic>
```

**What it actually promises — read this.**

- **Best effort, not guaranteed.** NapCat holds the sleep for about 1.5 seconds,
  which gives the POST a chance to leave the Mac — *not* a guarantee that ntfy
  answered before the machine went down. If it did not, the menu says
  "unconfirmed", never "sent". Once ntfy *has* the message it holds it for 12
  hours, so a phone that is briefly offline still gets it.
- **A deliberate sleep notifies you too.** NapCat cannot tell a closed lid from
  Apple menu → Sleep. If a Claude task is running and Stay Awake is off, both
  send the message.
- **Not while Stay Awake is on** (the Mac is not really sleeping on you), not
  when no Claude turn is in flight, and at most once every 15 minutes.
- **Changing the topic or server disarms it** until you run the test message
  again — a feed nobody has proven should never be trusted with the real alert.
- **Your topic is a shared secret with a public server.** Treat it like a
  password: do not paste it into screenshots, issues, or logs. NapCat never
  writes it to the unified log, and the menu never renders it. It is stored in
  NapCat's own preferences (`com.muratalkan.napcat`) in cleartext, like any
  other setting — anyone with access to your logged-in account can read it, and
  `sudo ./scripts/uninstall.sh` deletes it along with the rest of NapCat's
  settings. The operator of whichever ntfy server you use also sees the topic
  and the message text, and holds it for 12 hours.

**How it works, briefly.** NapCat registers for system power notifications
(`IORegisterForSystemPower`) *only while armed* — switched off, it has no
presence on the sleep path at all. The message is a plain-text HTTP POST to
`<server>/<topic>` with fixed `Title`/`Priority`/`Tags` headers, and the body is
built by NapCat from a fixed template plus the time and the number of busy
sessions. **Nothing from your Claude conversation, prompts, or file paths can
reach a message** — the sending API has no free-text parameter at all, not even
a String. The URL is assembled only from a topic that already matched
`^[A-Za-z0-9_-]{1,64}$` and an `https` origin with no path, and the finished URL
must match those two pieces byte-for-byte or the send is refused. The origin is
checked in its *un*-decoded form and its host must be a plain
`[A-Za-z0-9._-]` name, so a percent-encoded address cannot smuggle a path,
query, fragment, or `user@` back in; and before publishing, the built request is
re-checked to be exactly “that origin plus one path segment”. HTTP redirects are
refused outright — following one would hand your topic to whatever host the
server named — so a redirected publish is reported as a failure.

### Session alerts — finish and waiting pushes

Two more pushes ride the same ntfy feed, behind one **Session alerts** toggle
(right under **Lid alert** in the menu). **Finished:** the busy hook keeps a
session's marker until the main turn *and* every background subagent it started
have ended, so the marker going away *is* the finish — NapCat pushes then.
**Waiting:** when Claude stops mid-turn to wait for you (a permission prompt, an
MCP input request, a usage-limit wait), the hook marks the session as waiting
and NapCat pushes once for that wait.

While armed, NapCat watches the marker folder with a file-system notification on
that one folder — nothing polls, and with the toggle off the watcher does not
exist. Detection being paused (**Details → Pause detection**) silences both
pushes, and the row says so.

- **Same topic, server and test message as the lid alert** (set under
  **Details → ntfy settings…**). Switching Session alerts on with a topic that
  has never been tested sends the test message first, and nothing arms until it
  is accepted — a session alert is never the first thing your topic is trusted
  with. The two toggles are otherwise independent.
- **At least 30 seconds of work** (since the prompt that started the turn)
  before either push fires: a quick answer, or a permission prompt seconds after
  you hit Enter, stays quiet — you are still looking.
- **Finishes close together fold into one message** ("3 Claude sessions finished
  — none still working"), which also keeps the feed clear of ntfy's rate limit.
- **One waiting push per turn**, unless the session stops or resumes in between.
- **The message vocabulary is closed** — counts and minutes only; nothing from
  your session ever leaves the Mac. For example: "A Claude session finished
  after 42 min — 1 still working", "Claude is waiting for your approval — 12 min
  in". Both publish at ntfy priority `high`, tagged `white_check_mark`
  (finished) or `raised_hand` (waiting).
- **The menu shows the outcome of the last session alert** under **Details**; a
  refused or failed one moves up next to the toggle. A failed send is retried
  once only when it provably never left the Mac (no connection, DNS, TLS);
  anything that may have reached ntfy — one the server refused (for example,
  rate-limited), or one whose answer never came back — is never retried, so you
  may occasionally miss one rather than get a duplicate.
- **The marker folder has to exist.** Until the busy hook is installed — or
  after its folder is deleted — the row says it is waiting for the Claude hook.
  After the folder is created or recreated, the feature re-arms on the next
  menu open.

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
  task *is* running, it errs toward sending the push.
- **A phone on silent may stay silent.** Lid alerts publish at ntfy's `urgent`
  priority (5, alias `max`); session alerts publish at `high` (4), so silent
  mode still applies to them. The ntfy iOS app v1.8.0+ can deliver `urgent`
  messages as Critical Alerts that bypass silent mode, once you grant it that
  permission.
  That version was still unreleased as of October 2026 (check the
  [ntfy release notes](https://docs.ntfy.sh/releases/)). Until you have it,
  iOS shows a normal notification and silent mode applies.
- **Session alerts have a horizon.** Detectable run length is capped at 12 h
  since the session's last hook event.
- **Session alerts reveal when you work.** Every alert adds a little
  work-pattern metadata (when you start and stop) to your topic feed — the topic
  is the password, keep it private.
- **A finish alert can come early.** Rarely, a subagent finishing mid-turn can
  clear the busy marker early and trigger a premature finish alert.
- **Lid and finish can overlap.** If the finish send is in flight when the lid
  closes, the lid alert still goes out (separate lanes) — best-effort, like
  every push.
- **One rate-limit budget for both.** ntfy.sh rate-limits per IP, so session
  alerts and the lid alert draw on one daily budget; if a session alert is
  refused with HTTP 429, turn Session alerts off for the rest of the day so the
  lid alert keeps its headroom.

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
  awake, `v0.3.0` charge limit, `v0.4.0` animation, `v1.0.0` polish, and
  later `v1.0.1` watchdog charging re-enable + MIT license, `v1.1.0`
  menu-stays-open UX fix + hand-drawn sleep icon, `v1.2.0` lid-close ntfy
  alert + hardware-validated sleep pipeline, and `v1.3.0` Lock Screen +
  frozen menu redesign). Each annotated tag carries its release notes
  (`git tag -n99`); the detailed build plan and verification matrix are
  maintained privately.

## Security

Please report vulnerabilities privately through GitHub's private
vulnerability reporting, not in a public issue. [SECURITY.md](SECURITY.md)
covers how to report and which versions get fixes. The design rationale is
in [Security model](#security-model) above.

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
