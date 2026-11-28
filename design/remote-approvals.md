# F4: remote permission approvals (frozen design)

Status: design FROZEN 2026-11-22 with three ratified amendments (CL-1, CL-2,
CL-3). Spike S-4 passed the same day. This document is the in-repo record of
the design tracked on issue #98; slice S0 (issue #122) lands it together with
the pure core described at the end, slice S1 (issue #125) adds the server
side, slice S2 (issue #134) the Mac's control surface, slice S3 (issue
#146) the CloudKit record path and the phone's request screen, and the
S-PAIR slices (issue #161) pairing and signed decisions (CL-1); S-PAIR-C1
(issue #168) is the Mac's half of pairing, S-PAIR-C1.5 (issue #170) its
live transport, and S-PAIR-C2 (issue #181) the Mac's decision path.

## Problem

When Claude Code opens a permission prompt on the Mac, the session stalls
until the owner is back at the keyboard. NapCat already notices these waits
and buzzes the phone (F3: a CloudKit push in about a second), but that push is
read-only. The owner still has to walk to the Mac to answer a yes/no question.

## User and journey

The single owner of this Mac and iPhone (same iCloud account), running
interactive Claude Code sessions, away from the keyboard.

1. Claude Code opens a permission dialog in a session on the Mac.
2. The phone gets a push in fixed words, with no action on it; the app
   shows the tool name, input preview and originating project.
3. The owner opens the app and taps Allow or Deny. Both answers are in-app
   and ask for the biometric match (CL-3, widened to Deny by the
   uniform-signing ruling, below).
4. The Mac resolves the real, open dialog with that decision within seconds,
   and the session continues.
5. If the owner does nothing, or is at the Mac, the terminal dialog behaves
   exactly as it does today.

## Mechanism

- **Rail: the Claude Code channels permission relay**
  (<https://code.claude.com/docs/en/channels-reference>). A channel MCP server
  that opts into the permission capability receives a notification when a
  dialog opens (request id, tool name, description, input preview) and
  resolves it by returning a verdict (allow or deny) for that request id. The
  local dialog stays answerable the whole time; prompts do not time out, so
  remote silence simply leaves the local dialog open.
- **Rejected rails.** PreToolUse hook decisions fire before the dialog and
  cannot answer an open one, and waiting inside a hook would block every tool
  call. The permission-prompt-tool flag and the SDK `canUseTool` callback
  apply to non-interactive or SDK-embedded runs, not interactive terminal
  sessions. Terminal keystroke injection and other unsanctioned routes are
  out, permanently.
- **Known risk.** Channels are an experimental capability: version-pinned,
  with graceful local-only degradation if the capability changes.

## Scope (MVP)

- Prompt forwarding: an open permission dialog becomes a record in the
  existing CloudKit private container, a phone push in fixed words (no
  action on it), and an in-app list of pending prompts.
- Decision return: the phone writes a decision record and the Mac resolves the
  dialog. One-shot decisions only, each bound to one prompt.
- A Mac-side category gate deciding which prompts may leave the Mac at all.
- Several pending prompts, listed individually and labelled by project; a
  decision affects only its own prompt.
- Opt-in on the Mac (its toggle, default OFF) and by pairing an iPhone; the
  iPhone's own switch (default OFF) pauses that iPhone only; a kill switch.
- Audit logging on the Mac.
- A forwarded prompt replaces the plain waiting buzz for that episode: one
  prompt push, not two notifications.

## Non-goals

- Replies or message injection into sessions (parked as F4.1).
- Remote terminal control, screen viewing, or starting, stopping or killing
  sessions from the phone.
- Persistent permission changes: no "always allow", no rule edits.
- Any transport other than the existing CloudKit private container. The ntfy
  lane never carries approval semantics in either direction (its topic is a
  bearer credential).
- Multiple users or accounts, shared databases, family sharing.
- Changing sessions that are not wired for the relay: they behave exactly as
  today.
- Auto-approval policies of any kind.

## Owner rulings (2026-11-22)

1. Phone auth: Deny from the lock screen; Allow requires device
   authentication. Amended by CL-3.
2. Category gate: the forbidden families are never forwarded, everything else
   forwards, and a prompt the gate cannot classify fails closed to local-only.
   Amended by CL-2 and by the Read ruling (#231).
3. A forwarded prompt replaces the plain waiting buzz for that episode.
4. The channels permission relay is accepted as the MVP mechanism,
   version-pinned, with local-only degradation.
5. Replies are out of the MVP, parked as F4.1.

## Ratified amendments

- **CL-1: device pairing and Secure Enclave-signed decisions.** A decision
  counts only when it is signed by the paired phone's Secure Enclave key, so
  an Apple Account takeover or a forged record alone cannot approve anything.
- **CL-2: positive grammar for Bash; MCP tools local-only.** Bash prompts are
  forwarded only when the command matches a positive safe-subset grammar (an
  allowlist of shapes, not a denylist of bad ones). MCP tools are never
  forwarded in the MVP.
- **CL-3: Allow is in-app and biometric-only.** Deny stays a lock-screen
  notification action.
- **No Read is forwarded (owner ruling, #231).** A list of locations cannot
  name every credential file, so the gate keeps every Read prompt on the
  Mac, whatever its path, with its own code, `localOnly.read`. Claude Code
  does not ask, by default, before a Read inside a session's working
  directories; folders the owner trusts beyond those belong in Claude Code's
  own allow rules. What can leave the Mac is now only a Bash prompt whose
  whole command is a listed one.
- **Uniform signing (owner ruling, 2026-11-24, during S-PAIR).** Deny is
  signed like Allow, so it asks for the same biometric match, in-app: both
  verdicts need a match of the biometrics enrolled now, and both produce a
  signed decision. This withdraws CL-3's lock-screen Deny and every "Deny
  never asks" statement below. The Mac's verifier is unchanged (one key,
  blind to the verdict). Relaxing Deny later would be a design slice of its
  own, never a default.

## Technical rulings

- The seam between the channel server and the app is a Unix domain socket
  restricted to this user (peer credentials and audit token, on both ends).
  It does not yet check which program is on the other end.
- Prompt records are named by random 128-bit IDs.
- A forwarded prompt can be answered from the phone for a limited window
  (the TTL): 10 minutes in this build, the window the Mac gives every
  prompt it opens. The Mac's prompt state machine keeps any window it is
  given between 5 minutes and 1 hour (it raises a shorter one and lowers a
  longer one to that bound), but its record path still writes every record
  with the 10-minute TTL and builds none with a longer window; the phone
  honours the window a record states, up to 1 hour (a record stating a
  longer one is not shown). The owner's TTL ruling sets a 30-minute
  default, adjustable on the Mac; it is not built yet and is owed with the
  live record path.
- Records live in a dedicated custom zone of the private database, with their
  content fields encrypted.
- Preview posture: build on Claude Code's development flag for channels (set
  by the owner's own shell configuration, never by NapCat). The first server
  slice also probes whether a managed-settings channel allowlist can replace
  the per-session flag.

## Security requirements

- **Opt-in.** Dark by default. Forwarding needs the Mac's switch on, a
  paired iPhone (pairing is the iPhone's Mac-visible opt-in) and a live
  record path, which no build has yet. The iPhone's own switch only pauses
  that iPhone (it stops showing and answering, and its pushes end once its
  prompt subscription is deleted: see "Kill switch") and tells the Mac
  nothing: while it is off, the Mac would still forward.
- **Trust anchor.** The same iCloud account (private database), hardened by
  CL-1 pairing. Stated limit: whoever can unlock the paired phone and pass its
  biometric check holds Allow and Deny (since the uniform-signing ruling;
  before it, Deny needed only the phone in hand).
- **Decision validation.** A decision is checked for record type, prompt
  match, signature and freshness; stale or duplicate decisions are discarded.
- **Never-forwarded categories, enforced on the Mac** (the phone never sees
  them): privilege escalation (sudo and the privileged-helper paths), writes
  to Claude configuration or hook directories, and credential or secret access
  (the keychain, the alert topic, token files). Fail closed: a prompt the gate
  cannot classify with confidence is not forwarded. These prompts stay fully
  answerable locally. The gate recognizes them from fixed lists of commands
  and locations (the refusal catalogue), and a list cannot name every
  credential file, so no Read prompt is forwarded at all (#231): the only
  prompts that can leave the Mac are Bash prompts whose whole command is one
  of the listed commands. The gate judges the prompt, not what an approved
  command then does: a listed command runs the project's own build files,
  tests and git configuration. `Sources/NapCatWire` also holds the name
  tables and text scans of a never-sent floor (`ApprovalFloor`), which the
  gate does not call yet.
- **Classification and display rely on the tool name and the parsed input
  preview, never on the description.** The S-1 spike showed why: the
  description is often the tool's generic text, while the preview carries the
  real path and contents.
- **Timeouts.** An unanswered forwarded prompt does nothing: the local dialog
  stays open, never auto-approved and never auto-denied. A decision that
  arrives after the TTL is ignored and logged. NapCat cannot see an answer
  given at the Mac, so a valid remote decision that arrives inside the TTL
  after one is still accepted: its verdict frame is sent and logged
  `decided.remote.<verdict>`, a line that means sent, not applied. Claude
  Code drops a verdict for a dialog already answered, and in this build the
  channel server passes no verdict back at all (#221).
- **Race.** Claude Code applies whichever answer reaches it first and drops
  the other (in this build only the terminal's reaches it, #221). NapCat
  cannot see answers given at the Mac (the relay carries no such signal),
  so only remote decisions appear in its log. Local always keeps full
  capability.
- **Audit trail** (a new Mac log category): every forwarded prompt, every gate
  suppression, every remote decision with its verdict, the prompt ID and
  timestamps (the log's own). Never tool input, never the alert topic, never
  raw session IDs. While the feature is unarmed (every build so far), every
  prompt the gate classifies is logged `suppressed.notArmed`, not by the
  gate's code; a prompt the intake turns away before the gate (a frame its
  strict reader refuses, another server version or an unconfirmed client, a
  repeated request, a limit reached, no prompt ID to draw) is logged by its
  `seam.` code instead.
- **Kill switch.** Turning the Mac toggle off stops forwarding, retracts the
  pending records and makes in-flight remote decisions ignored. Turning the
  iPhone's switch off stops that iPhone showing and answering and empties
  its list; it tells the Mac nothing. It deletes the prompt subscription,
  which ends the pushes, only if the switch took effect earlier in the same
  launch: a failed deletion is retried on each later return to the
  foreground, pull to refresh, close of Settings or the launch's pairing
  sheet, or prompt push while the app stays open, and one still owed when
  the app quits is not retried by a later launch, so that subscription
  stays and its pushes still come. Quitting NapCat is also a hard stop.

## Constraints

- CloudKit container `iCloud.com.muratalkan.napcat`, private database,
  existing rails only.
- Zero idle cost: while no prompt is pending and no pairing is under way,
  no polling and no background traffic from this feature on either
  device. The Mac then makes no CloudKit request for it, apart from
  one deletion at a launch that still remembers a pairing record a past
  pairing could not delete; a pairing the owner starts looks the record up
  every few seconds until it ends. The phone reads only while its own
  switch is in effect: when its app is opened or brought forward, as its
  switch is turned on, on a pull to refresh, as Settings or the launch's
  pairing sheet closes, or when a prompt push reaches the open app or is
  tapped (owner ruling: such a read is not idle cost). Per-prompt cost is
  bounded to that prompt's pushes and record operations.
- Existing hard rules stay intact: the app never invokes sudo for this
  feature, the debug simulator is unaffected, and the six-event busy-hook
  contract is unchanged.
- Any channel registration installs through user-run rails like the existing
  hook installer, version-stamped and surfaced like the hook stamp. Status:
  the installer writes a version-stamped receipt (slice I1a, below), but
  NapCat does not read the receipt yet; showing the registration in
  Settings › Claude is a later slice.

## Acceptance criteria

1. Fresh install, defaults: nothing is ever forwarded; behaviour is identical
   to the release before F4.
2. Mac toggle on, a paired iPhone with its switch on, wired session: a
   permission dialog produces one phone push within a few seconds; the app
   shows the tool name, preview and project label.
3. Allow on the phone (after authentication) resolves the Mac dialog as allow;
   Deny resolves it as deny; the terminal dialog was answerable the whole
   time.
4. A forbidden-category prompt is never forwarded, stays answerable locally,
   and the suppression is logged.
5. Unanswered prompt: no automatic action, ever; the local dialog is
   unaffected; late, stale or duplicate decisions are ignored and logged; a
   decision for a dialog already answered at the Mac is sent, then dropped
   by Claude Code.
6. Two pending prompts (same or different sessions) are listed separately;
   answering one leaves the other open and unchanged.
7. Kill switch while a prompt is pending: the pending records are retracted
   within seconds, and a later phone decision has no effect and is logged as
   ignored.
8. Audit: entries exist for every forward, suppression and remote decision,
   with its verdict, and contain no tool input, topic or session IDs;
   answers given at the Mac are not visible to NapCat.
9. Idle: with the feature on and nothing pending, zero CloudKit operations
   attributable to F4 on both devices over an observation window in which
   the iPhone app is not opened, no pairing runs, and NapCat is not
   relaunched while a pairing record is still to be deleted.
10. Unwired session: prompts behave exactly as today, including the existing
    waiting buzz.

## Verification

- Live drills RA-1 to RA-7: remote allow, remote deny, forbidden suppression,
  local-versus-remote race, kill switch while pending, two pending prompts,
  unwired-session regression.
- Unit-testable seams: the category gate (fail-closed classification),
  decision validation (freshness, prompt match, dedupe) and the prompt state
  machine. No test registers a channel against the owner's live configuration
  or writes real CloudKit records.
- Energy and quota spot checks on both devices (idle window, per prompt).

## Spikes and evidence

Implementation is gated on spikes S-1 to S-5 (live, wired-session evidence),
S-4 first.

- **S-4 passed** (2026-11-22, owner-run, Claude Code v2.1.326): the reference
  example server registered with no allowlist or policy block, received a live
  permission request carrying the tool name, description, input preview and a
  reply code in the documented five-letter format, and the round trip
  completed.
- **S-1 (partial):** the preview encoding was observed. The description held
  the tool's generic text; the actual path and contents appeared only in the
  input preview.
- **S-3 (partial):** the client version was confirmed at 2.1.326.

## F4.1: replies (parked)

Channels can also push inbound messages into a running session, but that is
context, not an authenticated user turn, and free-text remote instruction is a
far larger security surface than a yes/no verdict bound to one prompt. Replies
wait for the approvals MVP's plumbing and mileage, and need their own security
review.

## Slice S0: the pure core

S0 adds the I/O-free foundation in `Sources/NapCatWire`, shared by both apps.
It has no imports, no networking, no processes and no clock; the tables in the
code are normative, and the unit tests pin them.

- **Wire constants** (`ApprovalWire`): the record types, field sets and
  encrypted fields, the custom zone, the phone's subscription ID, the verdict
  values, the 10-minute TTL and the 128-bit prompt ID size.
- **Category gate** (data-driven tables): the three forbidden families are
  never forwarded. The alert topic is checked for every tool, before any
  row; MCP tools and tools the table does not list have no row, so nothing
  else in their arguments is checked against the families; a listed tool's
  row is checked next, the families among its checks, and a local-only
  row's own code comes only after all of them (the catalogue's "Precedence"
  gives the whole order). A Bash command is forwarded only when it parses
  under the positive grammar and every command matches a row of the
  command table (since slice S-GATE: only when it is exactly one of a short
  list of commands, with the grammar kept as a refusal filter); MCP tools are
  local-only (since S-GATE, the file-edit tools too, and since #231 every
  Read, whatever its path, so only the listed Bash commands can forward); an
  unknown tool, an unknown or missing argument, a preview that is not a
  strict JSON object, or anything else the tables do not recognise fails
  closed. There is no default-forward branch.
- **Lifecycle state machine**: one prompt from gate to a terminal state. Only
  a valid, signed remote decision for the same prompt, inside the TTL, ever
  produces a verdict; expiry, retraction and the kill switch only withdraw the
  record. The first decision wins and every loser is reported for the audit
  log.

Networking, processes, UI, entitlements and CloudKit calls belong to later
slices.

## Slice S1: the channel server

S1 adds the server side: `napcat-channel`, the channel server Claude Code
spawns for a wired session; the same-user socket seam between it and
NapCat; NapCat's intake behind the seam, where the S0 gate and lifecycle run;
and a read-only probe of the managed-settings channel allowlist. Every
inbound line on every path is read by the S0 strict reader and by nothing
else. The server's version stamp, which must match
`ApprovalChannel.serverVersion` (parity-locked, like the busy hook's):

napcat-channel-version: 3

- **The server** (`Sources/NapCatChannel`, the wire in
  `NapCatWire/ApprovalChannel.swift`). MCP over stdio, one message per line,
  written unbuffered. It declares exactly the `claude/channel` and
  `claude/channel/permission` experimental capabilities: no tools and no
  instructions, so it puts nothing in front of Claude. It negotiates only the
  `initialize`-based revisions (newest 2025-11-25), never 2026-07-28, on which
  Claude Code does not register a channel; every other request, the
  2026-07-28 `server/discover` probe included, gets "method not found", so a
  client that speaks both falls back to `initialize`. It reads one
  notification, the permission request: exactly its four string fields, with
  a request ID of five letters from a to z without l. The description is
  checked for type and dropped right there; it never crosses the seam. A
  prompt is relayed only after the handshake (since slice S-GATE, only when
  the handshake named a confirmed Claude Code build; since #150 its frame
  names that build and the server's own version), once per request ID
  (Claude Code drops any verdict for a repeated ID), and at most 32 wait at
  once. Since #221 no verdict goes back to Claude Code: the seam checks the
  listener's user, not which program it is, so the server drops every
  verdict frame right after its strict read (`relay: verdictWithheld`) and
  each dialog is answered in the terminal; the request stays open until the
  link closes. The switch is `ApprovalChannel.passesAnswersBack`, false
  until the seam checks the listener's code identity (lint-locked). Once it
  is true, a verdict goes back only for a request the server relayed and
  still holds open, and only once. The server never sends a channel message
  into the session, reads no Claude Code configuration and no environment,
  and connects to NapCat only when a prompt opens; once connected it keeps
  the link until NapCat lets it go (slice S2: after a quiet minute with no
  prompt waiting on the phone). Every failure keeps the prompt local.
- **The seam** (`Sources/NapCatSeam`). A Unix socket,
  `~/Library/Application Support/NapCat/approvals/seam.sock`, in a 0700
  directory (the socket itself 0600). NapCat listens and each server
  connects. Both ends check the peer before reading a byte: it must run as
  this user by its socket credentials and by its audit token alike, and
  unreadable credentials are a refusal. Neither end checks yet which program
  the other is. The listener replaces only a stale socket of its own, never
  another kind of file, another user's socket or a live listener; the server
  connects only to a socket of its own user inside a directory nobody else
  can enter. A frame must be written within 2
  seconds (since slice S2 a deadline per frame, over non-blocking writes), so
  a stuck or slow-reading peer cannot hold either side. Frames are one JSON object per line, at
  most 256 KiB, frame version 2 (since #150; a version-1 frame is refused):
  `prompt` (frame, v, request, tool, preview, server, client,
  clientVersion) from the server, `verdict` (frame, v, request, verdict)
  from NapCat, each with exactly those members. Each side refuses the
  other's kind, and any refused frame closes the connection.
- **The intake** (`ApprovalIntake`, behind `ApprovalSeamHost`). For every
  prompt frame: the strict read, then (since #150) the frame's server
  version and client checked again against NapCat's own version and its
  confirmed builds, then the gate (with the alert topic as a secret), then
  the lifecycle opens with the gate's answer. A frame from a server of
  another version, or for a client that is not exactly a confirmed build, is
  refused before anything is held (`seam.serverVersionRefused`,
  `seam.clientRefused`) and closes the connection, as a refused frame does.
  The re-check reads what the frame says, not who wrote it: a binary that
  writes NapCat's version and a confirmed client passes it until the seam
  checks the server's code identity (a later slice). A record is saved
  only when the gate forwards the prompt and the feature is armed. The one
  verdict frame is the lifecycle's acceptance of a valid signed decision
  inside the TTL, sent to the server the prompt came from. A server going
  away (its session ended), the kill switch and the TTL only withdraw. The
  audit trail is the `approvals` log category: the random prompt ID and a
  closed code, never prompt text, a request ID, a session ID or the topic.
- **Dark by default.** In S1 nothing constructed the host or ran the probe
  (lint-locked). Slice S2 wires both behind the Mac toggle, never armed (see
  below); with the toggle off NapCat makes no socket, so a server finds
  nothing to connect to unless another program of this user listens at that
  path (or takes the path over while NapCat listens, which NapCat does not
  notice). Such a program would read the prompts of sessions started with
  the flag; a version-3 server passes none of its verdicts to Claude Code
  (#221), so every prompt is answered locally.
- **The allowlist probe** (`ChannelPolicyProbe`, the reading in
  `NapCatWire/ApprovalChannelPolicy.swift`). It reads the file tier of the
  managed settings (`managed-settings.json`, then the `managed-settings.d`
  drop-ins by name, in `/Library/Application Support/ClaudeCode`) and
  reports one finding. Only an organization allowlist naming NapCat's plugin,
  with channels enabled, removes the per-session development flag. It cannot
  see remote settings (claude.ai or server-managed (remote) settings) or an MDM profile,
  which rank above the file tier, and on a personal plan Claude Code skips
  these checks entirely, so the flag stays needed there. The plugin and
  marketplace names it looks for are provisional until the install slice
  packages the server.
- **Tests and locks.** The wire, the relay and the seam are tested line by
  line and over real sockets in a scratch directory, and end to end with only
  Claude Code's stdio, CloudKit and the phone faked; no test spawns a
  process, registers a channel or touches a real home, socket or system
  path. Structure locks keep the socket calls in one file, the peer check on
  every connection, one verdict site on each side, the gate ahead of every
  lifecycle (since #150, the server and client re-check ahead of the gate;
  since #198, the lifecycle's one open counted however it is spelled in the
  intake, and elsewhere, the state machine that declares it aside, by its
  call's shape (an `open` whose first label is `id`) and by the lifecycle's
  name before `.open`, also inside a longer name or across a postfix
  `#if`'s directives (#211); a reference written neither way is not read),
  the strict reader as the only parser, and the seam and probe
  unwired (slice S2 replaced that last lock with one that allows them only
  behind the toggle). The refusal catalogue the gate and the seam are tested against is
  in [remote-approvals-catalogue.md](remote-approvals-catalogue.md).

Later slices own the rest: bundling and signing the server, the user-run
registration rails and the per-session flag, a code-signing check on the
seam's peer (the audit token is already read for it; until it exists the
server passes no answer back, #221), the project label,
CloudKit, the phone, pairing and the toggles (the Mac's is slice S2). The relay carries no signal
that a dialog was answered at the Mac; a remote verdict that arrives after a
local answer is dropped by Claude Code, and the TTL withdraws the record.

## Slice S2: the Mac control surface

S2 adds the Mac's switch for the feature and wires the S1 pieces behind it.
It builds controls only: nothing can be forwarded yet.

- **The toggle.** One stored setting, off by default; only a stored `true`
  turns it on, so a missing or junk value never arms anything. Since #205 it
  is read from NapCat's own defaults domain: on only when that domain holds
  a `true` (a Bool `true`, or a number equal to 1, which reads as the Bool
  it bridges to) and the defaults search list reads one too. A value anywhere
  else (a launch argument, a per-host value, the global domain, a registered
  default) never turns it on; one that outranks NapCat's own (a launch
  argument, a managed setting, a per-host value written with
  `defaults -currentHost`) and disagrees turns it off, and a switch-on it
  vetoes is written back off, so what is stored matches what the switch
  shows. It shows as a
  Remote approvals row in the menu's Alerts card, under Session alerts, and as
  a group in Settings › Claude (the same action; the switch there is named for
  what it does today, "Mac-only preview", and promises no iPhone answering).
  Off is the kill switch, applied in process at once and never read back
  (#205): every open prompt is withdrawn, every channel server disconnected
  and the socket removed, and a later decision for a withdrawn prompt is
  ignored and logged. The off holds within that call and until the toggle
  is next read (when the menu or Settings next opens, or at the next
  launch); a store that never kept the write can read on again then.
  Quitting NapCat is the same stop, final.
- **The Advanced section (#252).** The group in Settings › Claude ends
  with a collapsed Advanced section: a switch for each riskier kind of
  prompt (admin commands; Claude settings and startup files; secrets), a
  checkbox for whether the iPhone may turn them on, and what is never
  sent. It is shown only: every control in it is disabled, drawn over a
  fixed value (the switches off, the checkbox ticked) with no setting
  stored behind it, so it changes nothing, and a line says these stay on
  this Mac in this version. Open, that line and the controls' labels are
  its only text: the section's intro, each control's caption and what is
  never sent sit behind info circles, each a tooltip that VoiceOver also
  reads. It starts collapsed whenever the pane is built, and opens and
  closes without motion.
- **Behind the toggle only.** Until the first switch-on nothing exists: no
  host, no socket or socket directory, no listener, no probe, no timer. Once
  off completes, no socket, listener, connection, probe or timer remains; the
  stopped host and the private (0700) socket directory stay, by design (the
  host still answers a late decision for a withdrawn prompt). The directory
  then holds no socket, but since slice I1a it can hold the channel
  installer's receipt. On, NapCat
  builds the seam host once and listens; the managed-settings probe runs
  while on (at enable, and when the menu or Settings opens) and Settings ›
  Claude shows its reading, there only: in this slice no reading changes what
  NapCat does, so none is a problem the panel must show. A lock replaces S1's
  dark-by-default lock: the host is built in one place, never armed, with a
  record sink that writes nothing; it stays private to the toggle, its
  listener and intake are built only inside it, and only the toggle's state
  machine starts it or runs the probe.
- **Fail-dark.** On, NapCat hears a wired session's prompts, classifies them,
  logs each one the gate reads as `suppressed.notArmed` (the host is never
  armed, so the log does not show the gate's code), and keeps every one on
  the Mac; the row says so ("Local only — the iPhone app cannot answer
  prompts yet"), and while no iPhone is paired
  it says to pair one first ("Not paired — pair your iPhone in Settings ›
  Claude", #205), as it does while a refused Unpair stands (#240: until a
  deletion or a new pairing goes through, or NapCat quits).
  No CloudKit record operation
  exists in this slice. Before any slice makes forwarding real, two gates
  apply: a pre-arming revision of the category gate (done: S-GATE, #145) and
  an owner-run live test.
- **The waiting buzz.** While the toggle is on and listening, the plain
  waiting push says how many permission prompts wired sessions just relayed,
  and of which kind, in fixed words ("— 1 Bash permission prompt"). Only
  prompts the gate would forward are counted, as counts per tool kind: never
  a command, path or preview, and never a prompt the gate keeps. Off, or for
  an unwired session, the push is unchanged.
  Since #216 that one read also gives the alert lane what it needs to tell
  whether the phone's own prompt push covers a wait. The lane asks for it
  once for each change it reads in the marker directory that holds a waiting
  write (a session newly waiting, whether or not that alerts, or a waiting
  marker rewritten with a new time or the other waiting token), and once as
  Session alerts arm; the read reaches the seam only while the toggle is on
  and listening. Besides the counts it returns how many prompts were relayed
  since the previous read and in the last 10 seconds, whatever the gate made
  of them, and how many of those, and of the counted ones, are known to
  carry evidence: CloudKit accepted the prompt's record, the prompt is still
  open on the phone (not answered, expired or withdrawn since), and the Mac
  found the phone's prompt subscription. What crosses from the seam is tool
  kinds, counts and an opaque mark the toggle keeps, never a prompt ID,
  preview or session; each read moves the mark on, so a prompt is new to one
  read at most. One relayed in a read's own second, after it, is new to the
  next read if that read comes within those 10 seconds, but never counted as
  carrying evidence: the mark keeps the read's second and how many of its
  prompts the read saw, not which. When a change holds exactly one waiting
  write and the read finds exactly one new prompt, with evidence, its plain
  waiting push, if it has one, is dropped; the finish pushes in it still go
  out. A wait under Session alerts' minimum run has no push to drop, and its
  prompt is used up all the same; with the Immediately choice there is no
  minimum, so a short wait has a push too, and that push is what is dropped.
  A waiting push that does go out leaves the prompts with evidence out
  of its count. Nothing in the app sets that evidence yet (the record path
  that will is not live, and the host is never armed), so no push is dropped
  and every push reads as before.
- **Hardening.** A topic that exists but could not be read keeps every prompt
  local. The host holds at most 64 servers and, per server, 64 of its 256
  prompts; part of a frame left unfinished for 5 seconds closes the link, and
  a server quiet for a minute with nothing waiting on the phone is let go (it
  reconnects with its next prompt; the same round lets the TTL withdraw an
  expired prompt). The probe opens a document non-blocking and checks it is a
  regular file within the size cap before reading any of it. Nothing the host
  hands out holds it, so a host or listener released without a stop leaves no
  socket, link or timer behind.
- **Tests.** Real sockets in scratch directories, injected clocks and short
  limits, the toggle over an in-memory setting: no test reads the real
  defaults, keychain or home, registers a channel or starts a process. The
  toggle's reader alone runs on an isolated defaults suite, adding only its
  own key to the test process's launch-argument and registered domains and
  removing it again (#205).

## Slice S3: the record path and the phone

S3 adds the CloudKit record path on both devices and the phone's request
screen, fail-dark: the Mac stays never armed, nothing in either app builds
the record path's CloudKit half, and no decision reaches the channel
server, because signed decisions (CL-1, pairing) come first. The path runs
in tests and fakes only. Mechanism and rules live in the code and its tests;
this section points at them.

- **The Mac** (`Sources/NapCat/CloudKitApprovalRecords.swift`). The writer
  saves one PromptRequest record per prompt the gate already forwarded
  (`GateApprovedPrompt`: it never classifies) and retracts it together with
  the decisions read for it. The reader parses PromptDecision records
  strictly and logs them in the `approvals` category. Every reading is a
  claim, never a verdict: in S3 none carried a signature, and since
  S-PAIR-C2 one counts only when the verifier finds the paired key's
  signature over exactly that decision (below). Each record's own
  result decides an operation's outcome (issue #139). The file may name
  CloudKit's record vocabulary only (a deliberate lint amendment); it holds
  no container or database, and only test fakes conform to its database
  seam. Since the revised gate (S-GATE), the intake's record store
  (`CloudKitApprovalRecords`) routes the intake to the writer: it is handed
  the gate's forward answer (the tool and the gate's own copy of the
  preview, never the relayed text) and writes exactly that, through the one
  conformer of `GateApprovedPrompt`; every withdrawal (the session's end,
  the kill switch, the TTL) retracts the record with the decision records
  read for it, and a read claim does nothing else. Only tests build the
  store: the app's host keeps the sink that writes nothing.
- **The phone** (`ios/NapCatPhone`). `RequestInbox` holds each request's
  window: until the Mac's expiry, and never longer than the record's own
  window after the phone first saw it (since #194; before it, the TTL). A
  record stating a window longer than the wire's one hour is not shown.
  Expired and withdrawn are terminal. The request screen
  shows the tool, the project and the input verbatim, every whitespace
  character drawn as a mark so a wrapped line never hides a space or passes
  for a line break (`VisibleWhitespace`), in a box that scrolls past a third
  of the screen so the answers stay in reach. Allow asks for a
  biometric match every time (CL-3: biometrics only, no passcode fallback);
  Deny never asks (S3; since S-PAIR-B Deny asks too); both re-check the
  window right before the one write. A saved answer reads "Sent", never
  "Allowed". The decision record is named after its prompt (one per prompt:
  a second save is refused as already answered) and carries no signature
  (S3; since S-PAIR-B it carries the paired key's). In S3 only a
  `-NapCatRequest` launch showed a request (a fixture, answered in memory);
  since #194 a live launch also lists, read only, the prompt records it
  reads in the approvals zone whose window was still open when the list was
  last drawn, while the phone's switch is in effect. No Mac build writes one
  yet, and the phone cannot check who wrote one (see "The phone's prompt
  path"). No app source builds the CloudKit decision writer.
- **The records.** Both types live in the approvals zone, with the readable
  fields encrypted as `ApprovalWire` lists them. The readers refuse a record
  whose type, zone, encryption or version differs, and the Mac's refuses a
  field it does not know. The Mac reads a decision without a signature as
  an unsigned claim, which the verifier refuses; the phone asks for the
  prompt's six fields only, so it never reads a seventh, and refuses a
  prompt missing any of them.
- **Locks.** `ApprovalRecordPathStructureTests` (Mac) and
  `RecordPathStructureTests` (phone), each with planted canaries: the record
  path names nothing of the verdict API (on the Mac, but the intake's
  record-sink protocol, once, as the store's conformance) and nothing
  reaches it; the store writes the gate's answer as it is handed; `armed: {
  false }` is the approval files' one armed literal; no source on either
  device builds the S0 decision type or names its signature flag; neither
  record path can reach iCloud on its own; the records are written only
  through the wire's keys and encryption table; Allow's order (check,
  match, send) and its one write site; the S3 tests touch nothing live.
  After security review 2: an operation run with no database set targets
  the private database, so on both devices nothing runs one but the seam
  (no start, queue or database `add`), and the phone reaches the decision's
  record and operation once each, in the writer. The Mac file's CloudKit
  identifiers are an exact allow-list. CloudKit is imported in no other file,
  in any form (scoped imports included). The S0 type's constructor is not
  reachable unnamed (an unapplied `init`, the metatype or an alias).
- **Owner-owed.** The Production schema deploy for PromptRequest and
  PromptDecision is DONE (2026-11-23, CloudKit Console, Production: both
  record types, encrypted fields exactly as `ApprovalWire` lists them, no
  indexes, no other schema object changed). No operation of this slice ran
  against either CloudKit environment.
- **Next.** Before any forward is real: a database for the store (the
  schema is deployed), the writer's outcome reaching the prompt's lifecycle (the
  prompt stays `saving` until then, so no decision can count), the
  evidence the alert lane needs before it drops a waiting push (that
  outcome, and the Mac finding the phone's prompt subscription as it saves
  the record; the alert lane's side is wired, see the waiting buzz bullet),
  the project label, and signed
  decisions (CL-1) before any decision counts. Also owed before arming:
  - Retraction is best-effort: a failed one is only audited. Fix it before
    arming: retry or sweep, delete the prompt record apart from its
    decisions, and have the Mac reader require the `<promptID>-decision`
    name, which also caps a retraction at two records.
  - A decision record the Mac never read is never deleted.
  - The project label passes the gate's filters before it is ever written.
  - A prompt refused before the intake holds one (its frame, server or
    client refused, a duplicate request ID, a prompt limit reached, no
    prompt ID, or its server closed unread by the seam) is new to no read,
    so it cannot stop a waiting push from being dropped. Before anything
    produces evidence, such a prompt must also block the drop for the
    10-second window.
  - A refused Unpair is remembered in memory only and only by the pane:
    the decision verifier reads the slot itself, so the key the owner
    asked to remove would still verify, during the run and after a
    relaunch. Before arming: the verifier's read refuses a key under an
    outstanding Unpair; the refusal survives a relaunch; an item that is
    there but unreadable has its own line and a way to remove it; Unpair
    runs the kill switch before the keychain call (#247).
  - The tracked pre-arming issues: #149 (Read's pages/offset/limit strictly
    validated), #150 (serverVersion bump and an intake-side client
    re-check; done, see slice S1's seam and intake), #221 (no answer
    passes back to Claude Code until the seam checks which program
    listens; done, see slice S1's server: the code identity check itself
    is still owed), #153 (the alert lane's CloudKit structure locks and the
    construction-count pins), #154 (the unconfirmed-Allow re-offer), #159
    (a forwarded path may hold quote and brace characters, so the phone's
    raw preview can look like more fields than it has: restrict them in
    the gate, or show the path as its own labelled field). For
    completeness, the test-hardening items #151 (widen the saved-copy
    lock), #155 (comment stripping inside string literals) and #160 (the
    structure locks' lexer cannot always tell a contextual keyword from a
    name spelled the same) ride the same window.

## Slice S-PAIR: pairing and signed decisions

S-PAIR makes a decision count only when the paired phone signed it (CL-1).
CloudKit authenticates the iCloud account, not a device or a person: anyone
who can write to the account can write a well-formed record. So a
decision's authenticity comes from a signature over its own canonical
bytes, and the pairing that installs the phone's key cannot trust a record
either. Tracked on issue #161 in four slices, each fail-dark: S-PAIR-A (the
canonical bytes and the verifier, pure), S-PAIR-B (the phone signs),
S-PAIR-C1 (the Mac pairs) and S-PAIR-C2 (the Mac counts). No S-PAIR slice
arms anything.

- **The key.** The phone holds the only private key: a P-256 key in its
  Secure Enclave, usable only after a match of the biometrics enrolled now,
  with no passcode fallback (CL-3), never exported. One match per answer,
  Allow or Deny alike (the uniform-signing ruling), covers both the in-app
  gate and the signature, and signs that answer only. The Mac keeps only the
  public key, in its local keychain, never synchronized through iCloud (a
  synced item could be written from any device on the account).
- **What is signed.** Six lines of UTF-8, each ending in a line feed, built
  by one shared function (`ApprovalSigning.decisionMessage`):

  ```
  napcat-decision-v1
  wire:1
  prompt:<32 lowercase hex digits>
  verdict:allow|deny
  decided:<unix seconds, base 10, no leading zeros>
  shown:<64 lowercase hex digits>
  ```

  No value's alphabet holds a line feed, so nothing is ever escaped, and
  the builder refuses a value outside its alphabet. The phone signs with
  ECDSA P-256 over SHA-256 of these bytes; the decision record's encrypted
  `signature` field carries the raw 64-byte form, and the deployed
  PromptDecision schema is unchanged. `prompt` binds a decision to one
  single-use prompt; `decided` is whole seconds, signed; the Mac checks
  only that it is a whole second in range, and does not log it (freshness
  is still judged on the Mac's clock against the TTL); `shown`
  is the digest of the prompt copy the phone displayed.
- **What the phone displayed.** `shown` is SHA-256 of the three fields the
  owner decides on, `napcat-shown-v1` and then each of `toolName`,
  `inputPreview` and `projectLabel` as `<name>:<byte count>`, a line feed,
  the field's bytes and a line feed (`ApprovalSigning.shownDigestInput`).
  The values are the fields exactly as decoded from the record, never a
  displayed form: the request screen draws whitespace as marks, and that
  drawing is a function of these bytes, not their source. The Mac rebuilds
  the digest from its own copy of the prompt it wrote, so a prompt record
  rewritten on its way to the phone cannot be approved: the phone signs
  what it showed, and the Mac checks that against what it sent.
- **The verifier** (`Sources/NapCat/DecisionVerifier.swift`) is the one
  place a decision reading becomes the S0 decision value. It checks, in
  this order, and the first failure wins: a phone is paired; the verdict
  is exactly `allow` or `deny`; the decision time is a whole second in
  range; the signature is exactly 64 bytes, before any cryptography; the
  wire version; the prompt ID's one spelling; the Mac holds its own copy of
  that prompt; the signature verifies over the message rebuilt from the
  claim and that copy. Duplicates and the TTL stay the lifecycle's. A
  decision that does not verify is dropped and logged in the `approvals`
  category by its code, and nothing else happens: no retry, no alert, and
  the local dialog stays open.

  | Code (`decision.unverified.…`) | The decision … |
  | :- | :- |
  | `noPairedKey` | arrived while no phone is paired |
  | `unknownVerdict` | carries a verdict other than exactly `allow` or `deny` |
  | `decidedAtOutOfRange` | carries a negative, non-finite or out-of-range time |
  | `fractionalDecidedAt` | carries a time that is not a whole second |
  | `signatureLength` | carries a signature that is not exactly 64 bytes |
  | `wrongWireVersion` | carries another wire version |
  | `malformedPromptID` | names its prompt in any spelling but 32 lowercase hex digits |
  | `noForwardedCopy` | is for a prompt the Mac holds no copy of |
  | `signatureInvalid` | does not verify: another key, a changed field, or a prompt the phone saw otherwise |
  | `shownDigestMismatch` | does verify, but only over the Mac's copy in another Unicode normalization form (NFC or NFD): the record's text changed form on its way to the phone. Refused all the same; the code only names the cause |

- **Pairing.** The Mac shows a QR code holding a fresh 256-bit nonce
  (`napcat-pair-v1:` and the nonce in unpadded base64url, read strictly),
  single use, for at most five minutes; the nonce never leaves the Mac's
  screen. The Mac shows and the phone scans because some Macs have no
  camera. The phone creates its key and writes one pairing-response record:
  the public key, an HMAC-SHA256 keyed by the nonce over the confirmation
  message, and the new key's signature over the proof message. The record
  is named from the nonce, so the Mac fetches it by name. The Mac checks
  both on the first record it fetches and stores the key only after the
  owner confirms that both devices show the same fingerprint (SHA-256 of
  the public key, at least 12 hex digits, computed on each side; no
  fingerprint travels on the wire). A mismatch, a second response, a
  decline or the end of the window burns the nonce, and at every ceremony
  end the Mac tries to delete the pairing record. A deletion that did not go
  through is tried again at each later launch, until it does or a new
  ceremony begins; a reply the phone saves after the Mac's ceremony ended
  can stay in the owner's iCloud (a retry at a later launch can remove
  it). The phone's new key is provisional until its own confirmation, so a
  stale or stray QR code cannot replace a working pairing. Pair in private:
  the QR code is a secret while it is on screen.
- **One slot; re-pairing is the recovery.** At most one key is paired, and
  a new pairing replaces it. Unpair on the Mac asks the keychain to delete
  the stored key and stops the feature through the kill switch either way;
  if the keychain refuses, the key stays, the `pairing` log says
  `pairing.unpairFailed`, and Settings › Claude says the key could not be
  removed and offers Try Again until a deletion or a new pairing goes
  through or NapCat quits (#240; after a relaunch it shows what the slot
  reads: the pairing, while the slot can be read). Re-enrolling Face ID
  invalidates the phone's key in hardware; the phone then unpairs itself
  and asks to pair again. A new or restored phone arrives unpaired (Secure
  Enclave keys never leave their device). Each case is recovered by the
  same ceremony. There is no rotation, no key ID and no second phone.
- **Not built, by design:** certificate chains, trust-on-first-use or
  rotation protocols, several devices, App Attest, password-authenticated
  key exchange, Mac-signed prompt records, and any encryption of decisions
  beyond CloudKit's own field encryption.
- **Domains.** Every message that is signed, MACed or hashed opens with its
  own domain string, so nothing made for one can be read as another, and a
  later format (F4.1 replies, say) gets a new domain. No domain begins
  another.

  | `ApprovalSigning` constant | Value | Opens |
  | :- | :- | :- |
  | `decisionDomain` | `napcat-decision-v1` | the decision message (signed by the paired key) |
  | `shownDomain` | `napcat-shown-v1` | the shown-digest input (hashed) |
  | `pairDomain` | `napcat-pair-v1` | the QR payload, before its `:` |
  | `pairConfirmDomain` | `napcat-pair-confirm-v1` | the confirmation message (HMAC keyed by the nonce): `wireVersion` and `publicKey`, length-prefixed like the shown-digest input |
  | `pairProofDomain` | `napcat-pair-proof-v1` | the proof message (signed by the new key): `nonce` and `publicKey`, length-prefixed the same way |
  | `pairNameLabel` | `napcat-pair-name-v1` | the pairing record's name: SHA-256 of the label followed by the nonce, as 64 lowercase hex digits |

- **S-PAIR-A.** The pure core, run on CI. The builders above
  live in `NapCatWire/ApprovalSigning.swift` (byte assembly only; the
  hashing, the MACs and the signatures stay in the apps, with CryptoKit),
  and the verifier runs over injected software keys. The vector suite
  (`ApprovalSigningVectorTests`) pins the bytes, digests and MACs row by
  row, including text Swift calls equal that must still digest
  differently (NFC against NFD, combining marks in two orders), an emoji
  ZWJ sequence, U+2028, CRLF, empty fields and the gate's size limits; the
  phone runs a byte-identical copy of the suite, and a Mac test keeps the
  two alike. Lock 3 of `ApprovalRecordPathStructureTests` is amended
  deliberately: the verifier is the one Mac source that builds the S0
  decision type, once, verified, after its signature check; it names
  nothing of the verdict API, the Secure Enclave, biometrics, the keychain
  or CloudKit; nothing names the verifier yet; and only the S0 type's own
  file is exempt from the scan. Nothing is wired: no reader, intake or
  lifecycle hands the verifier a claim, no key is stored, and the approval
  files' one armed literal is still `armed: { false }`.
- **S-PAIR-B**. The phone signs. Nothing on the Mac changes:
  no Mac holds a paired key, the verifier is still unwired, and the
  approval files' one armed literal is still `armed: { false }`.
  - *The key* (`PhoneKeyring`, `SecureEnclaveSigner`,
    `KeychainSigningKeyStore`). Made in the Secure Enclave under one access
    control: for signing, after a match of the biometrics enrolled now,
    while the phone is unlocked, on this device only, with no passcode or
    other fallback anywhere (lint-locked). Its encrypted block is a generic
    password in the data-protection keychain, never synchronized, kept with
    the enrollment's state hash. Two slots: the committed key, the only one
    that signs a decision, and a pairing's provisional key. The phone
    unpairs itself only when the committed key fails after a good match
    AND the enrollment changed since it was made; a cancel or a lockout
    never unpairs. A changed enrollment shows on the request screen with no
    prompt; the answers stay on offer (the enclave decides), and a key that
    still signs brings the stored hash up to date.
  - *One match, one signature.* The context a match was made in restores
    the key for exactly one signature and is invalidated right after it,
    before anything is written. Nothing keeps a match, a context or a key
    (lint-locked: three context sites, each a local, one evaluation, one
    restore). Deny carries the same biometric glyph and words as Allow
    ("Deny with Face ID"), and an unpaired phone offers no answer at all.
    While the biometric prompt is up, the request's line names the answer
    the match will sign ("Confirming — Deny, waiting for Face ID").
  - *The signer* (`DecisionSigner`). It builds the decision message with
    the shared builder, in whole seconds, with the `shown` digest over the
    three fields exactly as decoded from the prompt record, and signs it
    with the committed key. The decision record's encrypted `signature`
    field carries the 64 raw bytes. One signer, one write site, the window
    re-checked before the signature.
  - *Whole prompts only.* A prompt record missing any field is refused,
    field by field, and only the strict reader builds a request.
  - *Pairing, the phone's half* (`PairingCeremony`, the pairing screen).
    The phone scans the Mac's code once (VisionKit's scanner, QR codes
    only, the first code read), reads it strictly, makes a provisional key,
    asks for the ceremony's one match to sign the proof, and writes one
    pairing response through a seam: the record name, the key, the
    confirmation MAC and the proof. It then shows its own code (the first 48
    bits of SHA-256 over its key's x9.63 form, 12 hex digits in groups of
    four, read out character by character) under "Waiting — confirm the
    code on your Mac", and commits the key only on its own "Codes Match".
    A cancel, the five-minute window or any failure discards the
    provisional key and keeps the earlier pairing; a response already saved
    for the code fails the pairing, and nothing of it is shown. The camera
    asks once, in the app's own words; turned off, the screen says so and
    links to Settings. A phone whose biometric match can't happen (none
    enrolled, locked out) takes no scan: the screen names the cause and
    where to set it up, with no retry to loop on. The comparison's hint
    says what to do either way (codes that differ: cancel on both devices).
    A swipe down can't close the sheet while a ceremony is under way (Close
    cancels it), and VoiceOver hears the code appear and every end.
  - *Not live yet.* The PairingResponse record type is not in the schema.
    Its record names belong to NapCatWire with the deploy, and its CloudKit
    writer arrives with them; until then only fixtures conform to the seam,
    and the pairing screen opens for a `-NapCatPairing` fixture launch only.
    Fixture launches sign with software keys held in memory.
  - *Verification split.* The simulator and CI have no Secure Enclave. CI
    proves the protocol over software P-256 keys behind the enclave seam:
    the slots, the self-unpair rule, one match per signature, the canonical
    bytes and signatures the Mac's verifier accepts (rebuilt in the tests
    from the wire alone, Unicode-hostile fields included), the ceremony's
    states and refusals, and the lint locks over the enclave, keychain and
    biometric files. The enclave half is proven on the owner's device only,
    in drills that need the live ceremony: a key made with no prompt, one
    biometric prompt per answer with a signature the Mac verifies, a
    cancelled match that sends nothing and keeps the pairing, a
    re-enrollment that shows as changed with no prompt and then unpairs the
    phone on its next answer, no passcode fallback ever offered, and a
    restored or new phone that arrives unpaired.
- **S-PAIR-C1** (issue #168). The Mac pairs. Nothing arms:
  the approval files' one armed literal is still `armed: { false }`, and
  the verifier is still unwired (no reader, intake or lifecycle names it,
  and it names no stored key).
  - *The wire.* `ApprovalWire` gains the third record type,
    `PairingResponse`, with its four fields (`wireVersion`, `publicKey`,
    `confirmation`, `proof`), every one but the version encrypted.
    `PairingFingerprint` (NapCatWire) renders the code both devices show:
    the first six bytes of a key's SHA-256 digest as `XXXX XXXX XXXX`,
    and its spoken form, one character at a time with a pause between the
    groups. `PairingFingerprintVectorTests` pins it on both devices, row
    for row (a Mac test keeps the twins alike), and holds the phone's own
    code to the same rows.
  - *The slot* (`PairedKeyStore`). One keychain item holds the paired
    phone's public key, its code and when it was paired. It is the topic
    store's kind of item: the login keychain, this Mac only, never
    synchronized (the file-based login keychain does not sync through
    iCloud, and the item asks for no synchronization). The frozen proposal
    named the data-protection keychain; an ad-hoc `make` build has no
    keychain entitlement to use it, and the property the design needs
    holds here. A pairing replaces the item in place, in one write, so the
    Mac holds the old key or the new one, never a mix; Unpair asks the
    keychain to delete it (a refused deletion leaves it in place).
    A stored text in any other form reads as no pairing.
  - *The ceremony* (`PairingCeremonyState`, a pure state machine, and
    `PairingController`, its shell). Pair iPhone… in Settings › Claude
    makes a fresh nonce, remembers the record's name (never the nonce) for
    the next launch's cleanup, and shows the code on a sheet for five
    minutes. While the sheet is up the Mac fetches the record by that
    name every few seconds; nothing ticks or fetches while no ceremony
    runs. The first response read is checked at once: the confirmation
    MAC keyed by the nonce, then the proof signed by the delivered key.
    A response that fails either, or a record that fails the strict
    reading (`PairingResponseReader`: type, zone, the derived name, the
    exact field set with every field but the version encrypted, each
    value's size), ends the ceremony as refused. The first response that
    passes is frozen: the QR never returns, and any later poll that reads
    anything else (another response, or none) refuses too. The owner
    compares the codes; only Codes Match writes the key (lint-locked: no
    other road reaches the slot's one write), then the record's deletion is
    asked for. They Don't Match, Cancel, Esc, closing the window, the five
    minutes, a refusal or a failed write each burn the nonce and ask for
    the record's deletion (one try; if it did not go through, one more at
    each later launch until it does or a new ceremony begins: see
    "Pairing" above).
    A ceremony over a paired phone leaves the old key working until the
    new one is written.
  - *The sheet.* Five states: the code (with the countdown and the
    pair-in-private note; hidden while the sheet is not the key window or
    is covered, without ending anything), the comparison (the code large
    and monospaced, "confirm here first, then on your iPhone"), paired
    (no auto-close), and four closed ends: expired, refused, stopped (no
    Start Over) and save failed. A rotation that ends keeps its title,
    "Pair a New iPhone", and says the current pairing keeps working —
    never "Not Paired" while the old key works. (After a refused Unpair,
    below, a pairing begun is a first one: the owner asked for the old key
    to go, so the sheet never says it keeps working; if that ceremony ends
    without a save its title is "Not Paired" although the old key is still
    stored, and the pane behind it keeps saying the key couldn't be
    removed.) Esc ends the sheet in every state (in the comparison, whose
    two buttons each decide something, through a Cancel with no button of
    its own); no button is the default, so nothing answers Return and only
    a click on Codes Match writes the key. The QR payload is drawn and
    never spoken, copied, logged or shown as a tooltip; VoiceOver hears
    each state's line as it changes, the code character by character, and
    the countdown at one minute and ten seconds only. No motion beyond the
    Settings buttons' press. Unpair… asks first — its Unpair button is
    marked destructive and answers no key, and Esc cancels — then asks the
    keychain to delete the key and turns Remote approvals off through its
    kill switch, whatever the deletion came to. When the keychain refuses
    the deletion (#240) the pane's pairing line is a warning, "Unpair
    failed — the iPhone's key couldn't be removed from your keychain",
    whatever the slot reads after; its twin below the menu's cards says
    "Unpair failed — try again in Settings › Claude" (the panel has no Try
    Again), and the gear carries the badge. The pane's buttons are Try
    Again — the same Unpair, already confirmed, so no second alert, and
    nothing unless a refusal stands — and Pair iPhone…. Until a deletion or
    a new pairing goes through, or NapCat quits, the Remote approvals
    switch counts no pairing: switched back on, it says to pair first. The
    refusal is kept in memory only: after a relaunch the pane shows what
    the slot reads, and a slot that cannot be read shows as not paired, as
    before (a line of its own for an item that is there but unreadable is
    a follow-up). The decision verifier is unchanged: it reads the slot
    itself, and nothing hands it a decision in this build.
  - *Not live in C1.* The app's record seam was a stub that found and
    deleted nothing, so a ceremony showed its code and ended with its
    window; no release could ship with the pairing button over it. Tests
    play CloudKit's part with records built in memory and touch no
    keychain, defaults or iCloud. S-PAIR-C1.5 replaced the stub.
- **S-PAIR-C1.5** (issue #170). The live pairing transport:
  both devices learn to move the one pairing record for real. Nothing
  arms: the verifier is still unwired, and the approval files' one armed
  literal is still `armed: { false }`.
  - *The Mac's fetch and delete* (`CloudKitPairingRecords`, in the record
    path's file). The app's one pairing record source (lint-locked to its
    declaration's line; the C1 stub is gone, named nowhere). It reaches
    the record by its ID alone, the approvals zone and the name the nonce
    derives (no query, no listing, no save), and acts only on a name of
    exactly 64 lowercase hex digits. A fetch is a `CKFetchRecordsOperation`
    of that one ID, and its outcome is a closed mapping: the record read →
    found, read strictly with that same name (`PairingResponseReader`);
    no record by that ID (`unknownItem`) → nothing; anything else → still
    unreachable. The deletion is the record path's own operation, deleting
    that one record and saving nothing. Both go to a seam
    (`PairingRecordDatabase`) whose one app conformer is the live private
    database in the container's file, built on the first fetch behind the
    same entitlement probe as the alert lane's (the file's second container
    site, lint-locked alike). The record path's CloudKit allow-list widens
    by `CKFetchRecordsOperation` alone.
  - *Fail-dark where iCloud is not there.* No iCloud account, no network,
    no Production schema or approvals zone yet, or a build with no iCloud
    entitlement (every ad-hoc `make` build): the fetch reads unreachable,
    the sheet says "Waiting — iCloud is unreachable; still trying", and
    the ceremony ends with its window. No other surface appears.
  - *The leftover name.* The name remembered for the next launch's
    cleanup is read from the app's own persistent defaults domain only,
    never through the defaults search list (a launch argument, the global
    domain or a registered default could otherwise name a record for the
    launch to delete), and a name of any other shape than a pairing
    record's deletes nothing and is forgotten.
  - *The phone's writer* (`CloudKitPairingResponseWriter`). The pairing
    response's record, built through the wire's field table (every field
    but the version encrypted), saved CREATE-ONLY through the decisions'
    seam: a new record under `.ifServerRecordUnchanged`, so a response
    already saved for the code is refused as `alreadyAnswered` and is never
    read, adopted or shown (the record a conflict hands back is named
    nowhere in the file). It is the seam's one conformer outside the
    fixtures, admitted by its declaration's exact line, and no app source
    builds it yet: the pairing screen still opens for a `-NapCatPairing`
    fixture launch only, the phone's approvals seam has no live conformer,
    and nothing creates the approvals zone. The phone's live pairing entry
    point, its live database and the zone are a later slice: S-PAIR-C1.6
    built them.
  - *Locks that rode along.* No reflection anywhere in the Mac's four
    targets but the redactions' own childless mirrors; the values holding
    the nonce or the payload (the state machine, the event that hands the
    nonce in, the sheet's content, the QR view) describe, dump and reflect
    as their type's name alone, as types, so no spelling or file prints
    them; the QR view is named at its sites alone; the keychain store's
    calls and the one account it sets are pinned; and on the phone a
    fixture's `final` counts only as a modifier on its class's own line.
  - *The security review's fixes (R1–R5).* The live pairing database checks
    what it is handed (`PairingRecordGuard`): only a fetch of one record,
    and a deletion of one record that saves nothing, each by a pairing
    record's ID (the approvals zone, a 64-digit lowercase hex name); anything
    else is never added, and its own result block is told
    `invalidArguments`, so its caller reads its closed failure. The
    controller, the slot and the keychain store redact themselves as types
    too, so no print, description or `Mirror`-based walk through any
    wrapper reaches the slot's item or the real keychain calls. The
    redaction does not stop runtime reflection — the Swift runtime's field
    reader and the ObjC runtime's ivar reader both ignore
    `CustomReflectable` — so bans do: `descendant`, every `_forEachField…`
    reader, any read of `customMirror`, (the delta re-check's F-A) any
    `_silgen_name` or `_extern` declaration and any
    `swift_reflectionMirror…` name, (its round 2's F-D) the ObjC runtime's
    C API (`class_…`, `object_…`, `ivar_…` and their kin) and
    `NSClassFromString`, and (round 3's F-F) every other lookup by name —
    `NSSelectorFromString`, `Selector`, `classNamed`, `NSProtocolFromString`
    — are banned in the four targets. These bans stop the Swift runtime's
    field reader by name, any call of the ObjC runtime's C API (its ivar
    reader among it), and a class, a selector or a protocol reached by a
    string; raw-pointer reads remain the accepted R-1 residual. Rendering a
    view, a window or the screen off screen is banned too; the sheet view
    is pinned to its one presentation. The two live factories are pinned
    as words (an unapplied reference is a site, not only a call), and so is
    every line naming the sender's `database` or (F-B) its `container`. A
    line pin does not hold the line after it, so (F-C) the two live classes
    are pinned whole and an extension of either is banned. Pinning the
    bodies did not pin what the factories construct: a factory line finds
    its class by name, and a member of the sender of that name declared in
    another file wins over the file-private class and is handed the real
    container (round 3's F-E). So the factories' construction is pinned by
    name, four-target-wide: each live class's name sits on its head and its
    factory's one construction and nowhere else in the four targets (a
    shadow of any kind, an alias and an extension through an alias each
    name it). Key-value coding, its key-path evaluators and its observers
    are banned in the four targets, not the sender alone (round 3: the
    shadow read the container by name from another file); only the ntfy
    request's header lines and the notification observers name `setValue`
    or `addObserver`, each pinned to its line. In the keychain store each
    item call is named once, as a word, at its binding, and every `kSec…`
    line is pinned.
  - *Uninstall.* `scripts/uninstall.sh` deletes the paired-key item too,
    as the user and value-silent like the topic's (parity-locked to
    `KeychainItemName.pairedPhone`), and SECURITY.md describes the item.
  - *Verification split.* CI plays CloudKit's part on the real operations
    (their callbacks fired by hand) and touches no iCloud. Owed live, after
    the owner deploys the PairingResponse record type to Production
    (`wireVersion` a plain Int64; `publicKey`, `confirmation` and `proof`
    encrypted Bytes) and the approvals zone exists: a first live ceremony,
    a tampered record refused, a phone that cancels after the Mac, a
    rotation, Unpair's kill switch, and the sheet under Full Keyboard
    Access.
- **S-PAIR-C1.6** (issue #172). The phone goes live and the
  zone exists. Nothing arms: the verifier is still unwired, the approval
  files' one armed literal is still `armed: { false }`, and the phone's
  decision writer is still built by no app source.
  - *The phone's live database* (`LiveCloudKitApprovalDatabase`, in the
    receiver's CloudKit file). The record path's seam gets its one app
    conformer, lint-locked to its declaration's line and pinned whole: the
    owner's private database, built by `makeLiveApprovalDatabase()` behind
    the same `LiveCapability` guard as the alert lane's (the file's second
    container site), so a simulator build gets none. As C1.6 built it, it
    checked what it is handed (`isPairingResponseCreation`): one new
    PairingResponse record, in this account's approvals zone, named by 64
    lowercase hex digits, saved under `.ifServerRecordUnchanged`, deleting
    nothing. Anything else (a decision, a prompt, a deletion, an overwrite)
    was never added; its own result block is told `invalidArguments`, so
    the writer reads a closed failure. #194 widened what it runs: see "The
    phone's prompt path".
  - *The live wiring* (`LivePairing`). Made once per launch by the live
    inbox's factory, over the keyring the inbox signs with, so the key a
    pairing commits is the key every answer is signed by. It builds
    `CloudKitPairingResponseWriter` at its one site, over the live
    database; a build that cannot hold the iCloud entitlement gets
    `UnsentPairingWriter`, which writes nothing, and its pairing ends
    "Unsent — couldn't save to iCloud". The live types and the factory are
    named on their pinned lines alone, app-wide.
  - *The approvals zone.* Before the pairing's save, the live database
    looks the zone up by its ID and creates it only when the lookup finds
    it missing (`zoneNotFound` or `userDeletedZone`): one zone saved, none
    deleted, at one site, so an existing zone is never saved over. The
    zone's own result decides: CloudKit reports a missing zone on the zone
    and hands the lookup's result block a success, so a lookup that read
    that block alone would never find the zone missing (found on the
    simulator's CloudKit while this slice was built, and pinned by a test).
    Whatever the zone steps come to, the save runs next and its own result
    decides: a zone that could not be made fails it (`zoneNotFound`,
    unsent), dark, never a crash.
  - *The entry point.* Settings gains a Pairing section with one row, Pair
    with Mac, shown when the launch has a live pairing. Each tap makes a
    new ceremony (`makeCeremony`, its one site) and opens the pairing sheet
    over Settings; nothing else opens it (no launch, appearance or task).
    The `-NapCatPairing` fixture launch stays, over its fixture ceremony.
  - *The code from the camera only.* What a ceremony scans is a
    `ScannedCode`, built outside the fixtures at one site: the live
    scanner's hand-on of the first QR code it reads (VisionKit, QR codes
    only). It describes, prints and reflects as its type's name alone (the
    one childless mirror the phone admits). No app source takes anything in
    from a URL, a deep link, a user activity, a shortcut, the pasteboard, a
    drop, a file, a photo or the launch options, and the app declares no
    URL scheme, activity type or associated domain (lint-locked, and read
    back from the built app's Info.plist).
  - *The scanner's start.* A scanner VisionKit will not start ends the
    ceremony at its start on the closed `.noCamera` failure, with Scan
    Again and Close, instead of a dark viewfinder (the design review's fix).
  - *The signing line (N-25).* A failed biometric evaluation, key making,
    restore or signature is logged on one fixed public line in the
    `signing` category: a domain from a closed table (LocalAuthentication,
    OSStatus, CryptoKit's wrapped status, CryptoKit, other) and a number,
    never the error's own text. The device drills read it with `log
    stream`.
  - *Face ID stays at the scan.* The mirror copy as ratified put the phone's
    one Face ID at its Codes Match ("…then confirm here with Face ID"). It
    cannot move there without a protocol change: the response record
    carries the proof, which the new key signs; the key signs only after a
    biometric match (its one access control, no fallback); and the Mac
    checks the proof on the first record it fetches, before either device
    compares codes. So the ceremony's one match stays at the scan and signs
    the proof, and Codes Match commits the key with no prompt (cancel and a
    mismatch need none). The design review ratified this: Face ID stays at
    the scan, where the pairing proof is signed, and Codes Match commits
    without a prompt; the phone-mirror copy was amended to match in the
    design spec.
  - *Verification split.* CI plays CloudKit's part on the real operations:
    the zone's lookup and creation with their callbacks fired by hand, the
    live database's admission check over every refused shape, and the
    unentitled wiring end to end. Owed live, after the owner deploys the
    PairingResponse record type to Production: the first live ceremony
    (which creates the zone), a pairing with the zone already there, and
    the N-25 line read during the device drills.
- **S1c Variant A** (issue #176). The comparison step's
  presentation, on both devices, as the S1c variant ruling chose (prior
  art: every shipping compare screen shows its code plain, large and
  grouped by whitespace, never in tiles, which read as entry). Nothing in
  the ceremony changed: Codes Match is a click only, nothing answers
  Return, Esc cancels, and the Mac confirms first.
  - *The Mac's sheet.* The code is drawn at the large title, on one line
    at the sheet's width, its three groups set apart by gaps about one
    character wider (kerning on the two spaces, so the text stays the
    wire's `XXXX XXXX XXXX`: what a selection copies, and what VoiceOver
    spells out one character at a time). The body reads "Your iPhone is
    showing a code too. If all three groups match, confirm here first,
    then on your iPhone."; the deny button is "Codes Don't Match". The
    countdown's spoken form is coarse: whole minutes, then under a
    minute, under 30 seconds and under 10 seconds. The pane's code is
    unchanged.
  - *The phone's mirror.* The same plain string in the same face (the
    system's monospaced, regular) with the same gap ratio, at the phone's
    title size, on one line (at the largest text sizes it breaks between
    groups only); VoiceOver spells it out the same way. The hint gains
    the totality cue and the Mac's order: "Your Mac is showing a code
    too. If all three groups match, confirm on your Mac first — then tap
    Codes Match here. If they don't match, tap Codes Don't Match here and
    on your Mac; nothing is paired." The deny is labelled Codes Don't
    Match and still cancels: the phone can't tell a mismatch from a
    cancel, and both end alike, with Scan Again.
- **S-PAIR-C2** (issue #181). The Mac counts verified decisions. Nothing
  arms: the approval files' one armed literal is still `armed: { false }`,
  the app's host still saves no prompt record, and nothing in the app reads
  a decision record yet, so no decision reaches a real session.
  - *The one road.* The record store reads a decision record strictly
    (`CloudKitApprovalRecords.read`), notes it for its prompt's retraction,
    and hands on its evidence (the fields as read, the signature's bytes
    unchecked) with the store's own copy of that prompt: the three fields
    exactly as it wrote them, and none once the prompt is withdrawn or for a
    prompt it never wrote. The intake hands both, with the paired-key slot,
    to the verifier (`DecisionVerifier.verify`), and its `decide` takes the
    verifier's result alone (`DecisionVerification`): only a verified
    decision reaches the prompt's lifecycle, which keeps its own checks
    (the prompt, the version, the phase, the TTL, the first decision
    winning). The intake names the S0 decision type no more.
  - *Refusals.* A record that is not even a claim is logged
    `decision.malformed.<fault>` and goes nowhere. A claim the verifier
    refuses (unsigned, another key, a changed field, a prompt the Mac holds
    no copy of, no phone paired) is logged `decision.unverified.<reason>`,
    the table above, and counts for nothing: no answer, no lifecycle event,
    and the prompt stays open. A signed claim's reading is logged
    `decision.signed` (it was `decision.unverifiable` while no key existed).
  - *The key, read at each verification.* The verifier reads the paired key
    from the slot (`PairedKeyStore.read()`) at each verification, on one
    line, and keeps nothing: a verification after an Unpair whose deletion
    went through finds no key and refuses (`noPairedKey`), and after a new
    pairing only the new key's
    signatures verify. Lint-locked: the slot is read at that one site, the
    checks that take a key are reached from that entry alone, no approval
    file or the verifier names a pairing type anywhere else, and a P-256
    public key is named only at today's sites.
  - *The sinks, pinned (#163).* A decision value could be forged from raw
    bytes with no name the earlier locks pin: bytes copied into a generic
    slot through `memcpy` or `copyMemory`. So the places a forged value
    must reach are pinned instead: `decide`, named at its one wired call and
    its declaration; the remote-decision event, built in `decide` alone; the
    verifier's `.verified` result, built once after its signature check and
    read once in `decide`; the S0 type's file, to its one initializer and
    current conformances; the package manifest, to today's target list,
    and the repository root, to that one manifest (no version-specific
    one); and the doors around the sink: `withIntake` at its one use and
    its body whole (it binds the intake plainly, so no extension member
    stands in for a call there), the intake's type named at today's sites
    alone, no extension of `Optional` in the four targets (by its name,
    its `?` or an alias declared there), the host's and the intake's own
    `intake`/`apply`/`perform` lines, the intake's frame writer at its
    sites, the host's connection writes at today's site, the connection
    type named at today's sites alone, and the host's words for its
    connections and its peer reader, the seam file's send, write, read and
    descriptor (also by the descriptor's other names: the read sources, a
    source's `handle`, at no line today, and the listener's accepted
    `client`, #208), the relay's writer to Claude Code (`emit`) and its
    open requests (`open`, #210), and the channel server's one `read` of
    standard input (#212) at today's lines, so a new line of those
    files that names one of them fails (a line reaching the socket by none
    of them, through the connection handed on whole or the listener's peer
    reader, is not read itself, nor is one that changes the frames read
    from the socket without naming any of them: the handler the
    connection's `start` stores, the connection's line reader's
    declaration; a new type named like the wire's line reader is read,
    below); the channel server's stream writer and its
    type, named in the four targets at its one call and their declarations
    alone (#210, by #221's pin), so a second caller fails (one through the
    relay's own `emit` is the relay's word pin's to read); the
    seam connection's writer and reader, the intake's `receive` and its
    initializer, the channel server's stream type and stdin reader's type,
    and the relay's two receives are pinned whole (below); the four
    targets call a C write (`write`, `send` and their kin), and declare a
    function so named, at today's sites alone, and the channel server
    names `write` on its one standard-output line alone; and
    no other descriptor writer is named in the four targets at all (a stdio
    stream, or its unlocked, word, wide-character or locale writers, a
    copied descriptor, a positional, queued, listed or copying write, a Core
    Foundation stream or socket on a descriptor, a file handle made on a
    descriptor or for writing by a call that spells its type or one of the
    listed labels, the standard handles, Dispatch's channel, the
    printers): a tripwire with no site today, not a wall. Beside it, the
    file handle's type and the standard handles' names are read as words
    at today's lines alone (the app's process setups), so an alias of the
    type (at its declaration, not where it is used), an implicit standard
    handle and one reached through another handle's type are read too
    (#209). The tripwire reads the names it lists as spelled, applied or
    not; the C-write pin reads its names only where they are called or
    declared. So a line reaching the socket by another name is caught only
    when it names one of them so; not read: a C write taken as a value and
    called under another name, a file handle made by an initializer taken
    unapplied from another handle's type and called later, a write on a
    file handle that already exists, a child process that inherits the
    descriptor, a writer neither lists, and a file API and a path. Every
    `extension` header and every operator implementation in the four targets
    is today's, and each of today's extensions declares today's members, so
    no extension member or operator overload added elsewhere or inside one
    takes over a pinned line; no function or value there is declared with
    a capital name by `func`, `let` or `var`, in the tuple pattern of a
    `let` or `var` or in a `case let` pattern (a parameter, a closure's or
    a loop's binding is not read), so none takes over the call of a type
    it is named like; nothing stands at a file's top level but imports,
    types (structs, enums, classes, protocols, today's extensions) and
    today's one top-level alias, and no attribute there starts with an
    underscore or is `@c`, so no module-level function or value and no
    exported C symbol takes over a call; and no type is declared with a
    name a pinned line spells, or an imported module's, except at today's
    declarations, so no new type takes over a pinned line by its name. A
    visible edit to a decision-path file's unpinned lines stays code
    review's to read.
  - *The road, whole.* The decision's road is pinned as it is, flattened
    by scalars on the compiler's whitespace alone, in every scan copy: the
    verifier (`enum DecisionVerifier`: every check, the message, the
    diagnostic), the intake's `apply` and `perform`, and the slot's
    `read()`; and so are the bodies around it that fix a prompt's window and
    carry the last writes (#197–#199): the intake's `receive`, from the
    strict read to the entry a verdict goes back through (the gate's answer,
    the armed flag and the lifecycle's one open, with its default window),
    and its stored members and initializer, each closure it is handed (the
    armed flag among them) stored as a `let`, exactly as passed in (#211;
    what the host passes in is read by no pin: the host's initializer can
    rebind the armed closure, the record sink or the clock above the line
    that hands them on, and the sources behind its defaults are not
    pinned), the seam connection's `send` and `drain`, the channel
    server's stream type and its stdin reader's type (`StandardInput`, #212:
    its header, stored members, initializer, `start` and reader, so no
    superclass, conformance or member of it and no second reader wired in
    `start` takes its one read of standard input over; the server's `main`,
    which hands the reader's lines to the relay, is pinned whole too, #221;
    a read of standard input anywhere else the server's code reaches
    (elsewhere in the channel target, or in seam code it calls, a new seam
    file among them), and the wire's line reader's own body, are not read),
    and the relay's two receives. A line added on any of them fails unless
    the stripper reads it as whitespace or a `//` comment, also
    beside a pinned copy kept in a literal or an inactive block. A raw-text
    lock over the four targets and the phone app keeps out the scalars a
    text reading drops or matches to another: control and format characters,
    zero-width and other invisible scalars, a scalar joined to the
    whitespace before it, and one that compares equal to another. Each pin
    has canaries (the byte-copy forge in each shape found so far among them)
    and over-match controls. The pins cover the sites and bodies they name:
    a forge reaching none of them stays the accepted residual (#163), and
    raw-memory writes into a live object stay the pairing locks' accepted
    residual.
  - *The pairing guard's refusal (#180).* The live pairing database's own
    check refuses with `invalidArguments`, which the record path's batch
    reading calls unconfirmed. No Mac consumer tells the two apart: a
    refused fetch reads unreachable like every other fetch error, a refused
    deletion is not done like an unconfirmed one (the remembered name stays
    for the next launch's cleanup), the prompt writer's outcomes are only
    audited, and the decision path issues no CloudKit operation. The live
    path that hands the writer's outcome to the lifecycle decides it.
  - *Verification split.* CI plays the phone's part with software keys and
    CloudKit's with records built in memory, over the real store, verifier
    and intake, and an in-memory slot: no test touches the keychain, the
    defaults or iCloud.
- **Next.** The live read path for decision records, and the arming gates
  above with "paired" among them. The pure form of "paired" landed with
  #205: remote answers are held unless the toggle is on, an iPhone is
  paired and a live record path exists, all three; the row says to pair
  first, from the slot as last read at each menu or Settings open. Nothing
  is handed to the host yet, which stays unarmed. Owed live drill: a
  forwarded prompt with an NFD file name and non-ASCII text verifies end
  to end on real CloudKit, which also proves the whole-second time's round
  trip.

## Slice I1a: the registration rails

I1a (issue #190) bundles the server in the app, at
`Contents/MacOS/napcat-channel`, signed under its own identifier before the
app is, and adds two user-run scripts that register it with Claude Code;
#193 hardened them. Nothing arms: a registration only lets a session that
is started with the development flag load the channel.

- **The installer** (`scripts/install-channel.sh`, run as the owner's own
  user: never as root, no sudo) registers nothing until every check has
  passed. The bundle is a real directory, not a symlink, whose name ends
  in `.app` after at least one other character. The helper's and the
  app's signatures verify, and both name the same team, the one the
  committed entitlements name; each also satisfies a requirement, for its
  own identifier, that only a Developer ID Application certificate Apple
  issued to that team meets, so an ad-hoc build, an Apple Development
  build, or another team's, is refused. The Info.plist names NapCat and
  its channel version. The receipt's folder is a real directory of the
  owner's, created if missing and forced to 0700, and the receipt is a
  regular file if it exists: checked before Claude Code is called, so a
  refusal leaves no registration behind. That folder, with any missing
  folder above it, is the one thing the installer may change before every
  check has passed: it is created and set to 0700 before Claude Code is
  found or read, so a run that stops later can leave it in place. Then it
  registers the helper at user scope with `claude mcp add`, and writes the
  receipt (version and path, 0600). NapCat does not read the receipt yet;
  showing the registration in Settings › Claude is a later slice.
- **Development builds.** A plain `make` signs ad hoc, so the installer
  refuses its bundle, as it refuses one signed with an Apple Development
  certificate of NapCat's own team; a build registers only when it is
  signed with NapCat's Developer ID Application certificate
  (`make SIGN_IDENTITY=…`). No override exists.
- **What the check is not.** The installer verifies the bundle once, when
  it runs. The registration names a path, not the code: Claude Code starts
  whatever is at that path in every later session, and nothing re-checks
  its team or Developer ID signature. Anything that can write the bundle
  can change what runs, as it could by calling `claude mcp add` itself; an
  in-place update is picked up the same way. What a server may do at the
  seam is decided there, not by this registration.
- **Reading the registration.** `claude mcp get` prints for people, so both
  scripts act on two answers only: a stdio entry's one `Command:` line, or
  the not-found line alone (Claude Code 2.1.326's wording). Any other
  answer stops the installer, which never risks a second registration, and
  is an error in the uninstaller, never "nothing to remove". Only the exact
  shape the installer registers counts as another NapCat copy's helper: an
  absolute path, with no empty, `.` or `..` component, to a bundle whose
  name ends in `.app` after at least one other character. A command merely
  close to it is another server, left alone.
- **The uninstaller** removes the registration only when it runs a NapCat
  helper and the receipt records that same path. A NapCat helper the
  receipt does not record (no receipt, an unreadable one, or another path)
  is left in place and reported as an error, with the command that removes
  it. The receipt is kept while a registration step fails, so a later run
  can still match it. No receipt is read or deleted through a symlinked
  approvals folder, which the installer refuses too, and a recorded path is
  printed only in the shape the installer writes.
- **Tests and locks.** Structure locks pin the scripts' house guards, the
  order of their steps and the team (to the entitlements'). Behavioural
  tests run copies of both scripts in a scratch folder, with `codesign`,
  `id` and `claude` stubbed and a scratch home: never this machine's
  Claude Code configuration, receipt or installed app.

## The phone's prompt path (#194)

#194 lets the phone list, read only, the prompt records it reads in the
approvals zone whose window was still open when the list was last drawn,
while its switch is in effect. No Mac build writes one yet, and the phone
cannot check who wrote one. Nothing arms on either device, and in a live
launch every answer goes to a writer that writes nothing
(`UnsentDecisionWriter`), so the prompt screen is a preview with no answer
buttons, and the inbox refuses an answer before it asks for a match.

- **The phone's switch** (Settings › Remote approvals, "Prompts on This
  iPhone", off by default; `ApprovalsSwitch`). It takes effect only on a
  phone that holds a committed key, and it gates this phone's side alone:
  the prompt subscription, the reads and the waiting list. Nothing tells
  the Mac (owner ruling: pairing is the Mac-visible half of the opt-in),
  so off is a local pause. Switching it off empties the list, and deletes
  the prompt subscription only if the switch took effect earlier in the
  same launch; a failed deletion is retried on each later return to the
  foreground, pull to refresh, close of Settings or the launch's pairing
  sheet, or prompt push while the app stays open, and one still owed when
  the app quits stays: its pushes still come, and a later launch does not
  retry it.
- **What the live database runs.** `LiveCloudKitApprovalDatabase` checks
  each operation it is handed and runs exactly these: the pairing
  response's create-only save; a decision's create-only save (no app
  source builds a decision writer); one snapshot of the approvals zone
  asking for the prompt's six fields; and the prompt subscription's
  lookup, save and removal by its one ID. Before a record save it looks
  the zone up and creates it only when missing, as in C1.6. Anything else
  is never added: its own result block is told `invalidArguments`.
- **The snapshot.** Every record the approvals zone holds (no change
  token), asking for the prompt's six fields only. A prompt record is read
  strictly: its type, zone and prompt-ID name, the six fields with exactly
  the wire's encryption, the version, and a window of at most one hour.
  Every other record is dropped after its type is checked: its metadata
  (type and name), and any of the six fields it holds, may cross in the
  snapshot and are discarded unread. A failed read changes nothing.
- **When the phone reads.** At launch, on a return to the foreground, as
  the switch is turned on, on a pull to refresh, as Settings or the
  launch's pairing sheet closes, and on a prompt push that reaches the open
  app or is tapped; never on a timer, and only while the switch is in
  effect. Until the launch knows the prompt subscription exists (found or
  made), each read is preceded by its lookup, and by its save when the
  lookup finds it missing; once switching off has deleted it, the same
  starts again.
- **The push.** A query subscription on new PromptRequest records in the
  approvals zone (`ApprovalWire.promptSubscriptionID`). Its push is the
  app's title over fixed words ("A permission prompt is waiting.") with
  the default sound: no record field, no action and no silent
  wake. Tapping it opens that prompt once the inbox holds it.
