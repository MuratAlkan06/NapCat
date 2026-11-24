# F4: remote permission approvals (frozen design)

Status: design FROZEN 2026-11-22 with three ratified amendments (CL-1, CL-2,
CL-3). Spike S-4 passed the same day. This document is the in-repo record of
the design tracked on issue #98; slice S0 (issue #122) lands it together with
the pure core described at the end, slice S1 (issue #125) adds the server
side, slice S2 (issue #134) the Mac's control surface, slice S3 (issue
#146) the CloudKit record path and the phone's request screen, and the
S-PAIR slices (issue #161) pairing and signed decisions (CL-1).

## Problem

When Claude Code opens a permission prompt on the Mac, the session stalls
until the owner is back at the keyboard. NapCat already notices these waits
and buzzes the phone (F3: a CloudKit push in about a second), but that push is
read-only. The owner still has to walk to the Mac to answer a yes/no question.

## User and journey

The single owner of this Mac and iPhone (same iCloud account), running
interactive Claude Code sessions, away from the keyboard.

1. Claude Code opens a permission dialog in a session on the Mac.
2. The phone gets an actionable notification: tool name, input preview and
   originating project.
3. The owner taps Deny (works from the lock screen) or opens the app and taps
   Allow (biometric, in-app only; see CL-3). Since the uniform-signing
   ruling (below), both answers are in-app and ask for the biometric match.
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
  existing CloudKit private container, a phone push with an actionable
  notification, and an in-app list of pending prompts.
- Decision return: the phone writes a decision record and the Mac resolves the
  dialog. One-shot decisions only, each bound to one prompt.
- A Mac-side category gate deciding which prompts may leave the Mac at all.
- Several pending prompts, listed individually and labelled by project; a
  decision affects only its own prompt.
- Opt-in toggles on both devices (default OFF) and a kill switch.
- Audit logging on the Mac.
- A forwarded prompt replaces the plain waiting buzz for that episode: one
  actionable push, not two notifications.

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
   Amended by CL-2.
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
- **Uniform signing (owner ruling, 2026-11-24, during S-PAIR).** Deny is
  signed like Allow, so it asks for the same biometric match, in-app: both
  verdicts need a match of the biometrics enrolled now, and both produce a
  signed decision. This withdraws CL-3's lock-screen Deny and every "Deny
  never asks" statement below. The Mac's verifier is unchanged (one key,
  blind to the verdict). Relaxing Deny later would be a design slice of its
  own, never a default.

## Technical rulings

- The seam between the channel server and the app is an authenticated Unix
  domain socket.
- Prompt records are named by random 128-bit IDs.
- A forwarded prompt lives at most 10 minutes (the TTL).
- Records live in a dedicated custom zone of the private database, with their
  content fields encrypted.
- Preview posture: build on Claude Code's development flag for channels (set
  by the owner's own shell configuration, never by NapCat). The first server
  slice also probes whether a managed-settings channel allowlist can replace
  the per-session flag.

## Security requirements

- **Opt-in on both sides.** Dark by default; it must be enabled on the Mac and
  on the phone before anything is forwarded.
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
  answerable locally.
- **Classification and display rely on the tool name and the parsed input
  preview, never on the description.** The S-1 spike showed why: the
  description is often the tool's generic text, while the preview carries the
  real path and contents.
- **Timeouts.** An unanswered forwarded prompt does nothing: the local dialog
  stays open, never auto-approved and never auto-denied. A decision that
  arrives after local resolution or after the TTL is ignored and logged.
- **Race.** The first decision wins, local or remote; the other is discarded
  and logged. Local always keeps full capability.
- **Audit trail** (a new Mac log category): every forwarded prompt, every gate
  suppression, every decision with its origin (local or remote) and verdict,
  the prompt ID and timestamps. Never tool input, never the alert topic, never
  raw session IDs.
- **Kill switch.** Turning the Mac toggle off stops forwarding, retracts the
  pending records and makes in-flight remote decisions ignored. Turning the
  phone toggle off stops showing and answering. Quitting NapCat is also a hard
  stop.

## Constraints

- CloudKit container `iCloud.com.muratalkan.napcat`, private database,
  existing rails only.
- Zero idle cost: no polling, no CloudKit traffic and no battery draw from
  this feature on either device while no prompt is pending. Per-prompt cost is
  bounded to that prompt's pushes and record operations.
- Existing hard rules stay intact: the app never invokes sudo for this
  feature, the debug simulator is unaffected, and the six-event busy-hook
  contract is unchanged.
- Any channel registration installs through user-run rails like the existing
  hook installer, version-stamped and surfaced like the hook stamp.

## Acceptance criteria

1. Fresh install, defaults: nothing is ever forwarded; behaviour is identical
   to the release before F4.
2. Both toggles on, wired session: a permission dialog produces one actionable
   phone push within a few seconds, showing the tool name, preview and project
   label.
3. Allow on the phone (after authentication) resolves the Mac dialog as allow;
   Deny resolves it as deny; the terminal dialog was answerable the whole
   time.
4. A forbidden-category prompt is never forwarded, stays answerable locally,
   and the suppression is logged.
5. Unanswered prompt: no automatic action, ever; the local dialog is
   unaffected; late, stale or duplicate decisions are ignored and logged.
6. Two pending prompts (same or different sessions) are listed separately;
   answering one leaves the other open and unchanged.
7. Kill switch while a prompt is pending: the pending records are retracted
   within seconds, and a later phone decision has no effect and is logged as
   ignored.
8. Audit: entries exist for every forward, suppression and decision, with
   origin and verdict, and contain no tool input, topic or session IDs.
9. Idle: with the feature on and nothing pending, zero CloudKit operations
   attributable to F4 on both devices over an observation window.
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
  checked first and are never forwarded; a Bash command is forwarded only when
  it parses under the positive grammar and every command matches a row of the
  command table (since slice S-GATE: only when it is exactly one of a short
  list of commands, with the grammar kept as a refusal filter); MCP tools are
  local-only (since S-GATE, the file-edit tools too); an unknown tool, an
  unknown or missing argument, a preview that is not a strict JSON object, or
  anything else the tables do not recognise fails closed. There is no
  default-forward branch.
- **Lifecycle state machine**: one prompt from gate to a terminal state. Only
  a valid, signed remote decision for the same prompt, inside the TTL, ever
  produces a verdict; expiry, retraction and the kill switch only withdraw the
  record. The first decision wins and every loser is reported for the audit
  log.

Networking, processes, UI, entitlements and CloudKit calls belong to later
slices.

## Slice S1: the channel server

S1 adds the server side: `napcat-channel`, the channel server Claude Code
spawns for a wired session; the authenticated socket seam between it and
NapCat; NapCat's intake behind the seam, where the S0 gate and lifecycle run;
and a read-only probe of the managed-settings channel allowlist. Every
inbound line on every path is read by the S0 strict reader and by nothing
else. The server's version stamp, which must match
`ApprovalChannel.serverVersion` (parity-locked, like the busy hook's):

napcat-channel-version: 1

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
  the handshake named a confirmed Claude Code build), once per request ID
  (Claude Code drops any verdict for a repeated ID), and at most 32 wait at
  once. A verdict goes back only for a request the server relayed and still
  holds open, and only once. The server never sends a channel message into the
  session, reads no Claude Code configuration and no environment, and
  connects to NapCat only when a prompt opens; once connected it keeps the
  link until NapCat lets it go (slice S2: after a quiet minute with no prompt
  waiting on the phone). Every failure keeps the prompt local.
- **The seam** (`Sources/NapCatSeam`). A Unix socket,
  `~/Library/Application Support/NapCat/approvals/seam.sock`, in a 0700
  directory (the socket itself 0600). NapCat listens and each server
  connects. Both ends check the peer before reading a byte: it must run as
  this user by its socket credentials and by its audit token alike, and
  unreadable credentials are a refusal. The listener replaces only a stale
  socket of its own, never another kind of file, another user's socket or a
  live listener; the server connects only to a socket of its own user inside
  a directory nobody else can enter. A frame must be written within 2
  seconds (since slice S2 a deadline per frame, over non-blocking writes), so
  a stuck or slow-reading peer cannot hold either side. Frames are one JSON object per line, at
  most 256 KiB, frame version 1: `prompt` (frame, v, request, tool, preview)
  from the server, `verdict` (frame, v, request, verdict) from NapCat, each
  with exactly those members. Each side refuses the other's kind, and any
  refused frame closes the connection.
- **The intake** (`ApprovalIntake`, behind `ApprovalSeamHost`). For every
  prompt frame: the strict read, then the gate (with the alert topic as a
  secret), then the lifecycle opens with the gate's answer. A record is saved
  only when the gate forwards the prompt and the feature is armed. The one
  verdict frame is the lifecycle's acceptance of a valid signed decision
  inside the TTL, sent to the server the prompt came from. A server going
  away (its session ended), the kill switch and the TTL only withdraw. The
  audit trail is the `approvals` log category: the random prompt ID and a
  closed code, never prompt text, a request ID, a session ID or the topic.
- **Dark by default.** In S1 nothing constructed the host or ran the probe
  (lint-locked). Slice S2 wires both behind the Mac toggle, never armed (see
  below); with the toggle off no socket exists, a server finds nothing to
  connect to, and every prompt stays local.
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
  lifecycle, the strict reader as the only parser, and the seam and probe
  unwired (slice S2 replaced that last lock with one that allows them only
  behind the toggle). The refusal catalogue the gate and the seam are tested against is
  in [remote-approvals-catalogue.md](remote-approvals-catalogue.md).

Later slices own the rest: bundling and signing the server, the user-run
registration rails and the per-session flag, a code-signing check on the
seam's peer (the audit token is already read for it), the project label,
CloudKit, the phone, pairing and the toggles (the Mac's is slice S2). The relay carries no signal
that a dialog was answered at the Mac; a remote verdict that arrives after a
local answer is dropped by Claude Code, and the TTL withdraws the record.

## Slice S2: the Mac control surface

S2 adds the Mac's switch for the feature and wires the S1 pieces behind it.
It builds controls only: nothing can be forwarded yet.

- **The toggle.** One stored setting, off by default; only a stored `true`
  turns it on, so a missing or junk value never arms anything. It shows as a
  Remote approvals row in the menu's Alerts card, under Session alerts, and as
  a group in Settings › Claude (the same action; the switch there is named for
  what it does today, "Mac-only preview", and promises no iPhone answering).
  Off is the kill switch: every open prompt is withdrawn, every channel server
  disconnected and the socket removed, and a later decision for a withdrawn
  prompt is ignored and logged. Quitting NapCat is the same stop, final.
- **Behind the toggle only.** Until the first switch-on nothing exists: no
  host, no socket or socket directory, no listener, no probe, no timer. Once
  off completes, no socket, listener, connection, probe or timer remains; the
  stopped host and the empty private (0700) socket directory stay, by design
  (the host still answers a late decision for a withdrawn prompt). On, NapCat
  builds the seam host once and listens; the managed-settings probe runs
  while on (at enable, and when the menu or Settings opens) and Settings ›
  Claude shows its reading, there only: in this slice no reading changes what
  NapCat does, so none is a problem the panel must show. A lock replaces S1's
  dark-by-default lock: the host is built in one place, never armed, with a
  record sink that writes nothing; it stays private to the toggle, its
  listener and intake are built only inside it, and only the toggle's state
  machine starts it or runs the probe.
- **Fail-dark.** On, NapCat hears a wired session's prompts, classifies and
  audits them, and keeps every one on the Mac; the row says so ("Local only —
  the iPhone app cannot answer prompts yet"). No CloudKit record operation
  exists in this slice. Before any slice makes forwarding real, two gates
  apply: a pre-arming revision of the category gate (done: S-GATE, #145) and
  an owner-run live test.
- **The waiting buzz.** While the toggle is on and listening, the plain
  waiting push says how many permission prompts wired sessions just relayed,
  and of which kind, in fixed words ("— 1 Bash permission prompt"). Only
  prompts the gate would forward are counted, as counts per tool kind: never
  a command, path or preview, and never a prompt the gate keeps. Off, or for
  an unwired session, the push is unchanged.
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
  defaults, keychain or home, registers a channel or starts a process.

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
  claim, unsigned or unverifiable, never a verdict. Each record's own
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
  window: until the Mac's expiry, and never longer than the TTL after the
  phone first saw it. Expired and withdrawn are terminal. The request screen
  shows the tool, the project and the input verbatim, every whitespace
  character drawn as a mark so a wrapped line never hides a space or passes
  for a line break (`VisibleWhitespace`), in a box that scrolls past a third
  of the screen so the answers stay in reach. Allow asks for a
  biometric match every time (CL-3: biometrics only, no passcode fallback);
  Deny never asks (S3; since S-PAIR-B Deny asks too); both re-check the
  window right before the one write. A saved answer reads "Sent", never
  "Allowed". The decision record is named after its prompt (one per prompt:
  a second save is refused as already answered) and carries no signature
  (S3; since S-PAIR-B it carries the paired key's). Only a
  `-NapCatRequest` launch shows a request (a fixture, answered in memory);
  no app source builds the CloudKit decision writer.
- **The records.** Both types live in the approvals zone, with the readable
  fields encrypted as `ApprovalWire` lists them. The readers on both sides
  refuse a record whose type, zone, field set, encryption or version
  differs.
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
  prompt stays `saving` until then, so no decision can count), the waiting
  buzz superseded by the alert lane, the project label, and signed
  decisions (CL-1) before any decision counts. Also owed before arming:
  - Retraction is best-effort: a failed one is only audited. Fix it before
    arming: retry or sweep, delete the prompt record apart from its
    decisions, and have the Mac reader require the `<promptID>-decision`
    name, which also caps a retraction at two records.
  - A decision record the Mac never read is never deleted.
  - The project label passes the gate's filters before it is ever written.
  - The tracked pre-arming issues: #149 (Read's pages/offset/limit strictly
    validated), #150 (serverVersion bump and an intake-side client
    re-check), #153 (the alert lane's CloudKit structure locks and the
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
  single-use prompt; `decided` is whole seconds, for the audit trail only
  (freshness is still judged on the Mac's clock against the TTL); `shown`
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
  decline or the end of the window burns the nonce, and the pairing record
  is deleted at every ceremony end. The phone's new key is provisional
  until its own confirmation, so a stale or stray QR code cannot replace a
  working pairing. Pair in private: the QR code is a secret while it is on
  screen.
- **One slot; re-pairing is the recovery.** At most one key is paired, and
  a new pairing replaces it. Unpair on the Mac deletes the stored key and
  stops the feature through the kill switch. Re-enrolling Face ID
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
- **S-PAIR-B** (this slice). The phone signs. Nothing on the Mac changes:
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
- **Next.** The PairingResponse record names in NapCatWire and the phone's
  CloudKit writer for them, then the owner-run Production schema deploy of
  the new PairingResponse record type, then S-PAIR-C1 (the ceremony, the key
  store and Unpair on the Mac) and S-PAIR-C2 (the verifier wired as the
  only road from a reading to the lifecycle, and "paired" as a precondition
  for arming). Owed live drill: a forwarded prompt with an NFD file name
  and non-ASCII text verifies end to end on real CloudKit, which also
  proves the whole-second time's round trip.
