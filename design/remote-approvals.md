# F4: remote permission approvals (frozen design)

Status: design FROZEN 2026-11-22 with three ratified amendments (CL-1, CL-2,
CL-3). Spike S-4 passed the same day. This document is the in-repo record of
the design tracked on issue #98; slice S0 (issue #122) lands it together with
the pure core described at the end.

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
   Allow (biometric, in-app only; see CL-3).
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
  biometric check holds Allow; Deny needs only the phone in hand.
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
  command table; MCP tools are local-only; an unknown tool, an unknown or
  missing argument, a preview that is not a strict JSON object, or anything
  else the tables do not recognise fails closed. There is no default-forward
  branch.
- **Lifecycle state machine**: one prompt from gate to a terminal state. Only
  a valid, signed remote decision for the same prompt, inside the TTL, ever
  produces a verdict; expiry, retraction and the kill switch only withdraw the
  record. The first decision wins and every loser is reported for the audit
  log.

Networking, processes, UI, entitlements and CloudKit calls belong to later
slices.

## Slice S1: the channel server

S1 adds `napcat-channel`, the channel server Claude Code spawns for a wired
session. Its version stamp, which must match `ApprovalChannel.serverVersion`
(parity-locked):

napcat-channel-version: 1
