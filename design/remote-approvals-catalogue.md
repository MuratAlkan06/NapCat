# F4: the refusal catalogue

Status: regenerated in slice S1 (issue #125) from the test rows, which are
normative, and revised in slice S-GATE (issue #145), for Read's arguments
(issue #149), for the path alphabet (issue #159) and for Read prompts kept
on the Mac (issue #231), each of which only made the gate stricter, for seam
frame version 2 (issue #150), which made the seam stricter, for withheld
verdicts (issue #221), which made the server stricter, and for the
never-sent floor and the forwarding policy (issue #253), which made the gate
stricter in one way: a listed command is kept on the Mac when the prompt
Claude Code sends alongside it names something on the floor.
`Tests/NapCatTests/ApprovalClassificationTests.swift` pins every
gate entry below (`ApprovalGateOracleTests` holds every entry whose code
changed in #253, and `ApprovalRelayFixtureTests` the previews Claude Code
relayed in a recorded session), and the S1 tests (`ChannelRelayTests`, `ApprovalChannelTests`,
`ApprovalSeamTests`, `ApprovalIntakeTests`) pin the seam and server entries;
where a row and this note differ, the row wins. Companion to
[remote-approvals.md](remote-approvals.md).

Each entry is something a prompt could carry and what happens to it. Nothing
listed here is ever forwarded: a refused prompt stays fully answerable in the
terminal. Once the feature is armed, NapCat logs it by its code, as
`suppressed.gate.` followed by the code; while it is unarmed (every build so
far), every prompt the gate classifies, refused or not, is logged
`suppressed.notArmed` instead (see "Precedence"); a prompt the intake turns
away before the gate (a frame its strict reader refuses, another server
version or an unconfirmed client, a repeated request, a limit reached, no
prompt ID to draw) is logged by its `seam.` code. The log holds what
NapCat decided: an answer given at the Mac does not reach NapCat, so it is
not in the log.
The codes are the gate's own:
`floor.<group>`, `floorUnreadable.<reason>`, `forbidden.<family>`,
`localOnly.mcp`, `localOnly.fileEdit`, `localOnly.read` and
`unclassifiable.<reason>`. In the
examples, `~` stands for an absolute home directory and `<topic>` for the
alert topic; the tests use synthetic values for both.

What can leave the Mac at all is a Bash prompt whose whole command is one of
the listed commands (see "Bash: listed commands only"). No other tool
forwards: MCP tools, the file-edit tools and Read are local-only, each with
its own code. The gate forwards a prompt only when the set it is handed
admits the prompt's kind and every forbidden family it carries; NapCat hands
it one set, the listed commands with no family.

## Precedence

The gate checks a prompt in this order:

1. The tool name's shape (`unclassifiable.malformedToolName`), then the
   preview's size (`unclassifiable.previewTooLarge`). The floor reads
   nothing larger.
2. The never-sent floor, over the tool name and the raw preview
   (`floor.<group>`, or `floorUnreadable.topic` while a topic exists that
   could not be read; see "The never-sent floor").
3. The relay's credential placeholder, in the tool name or anywhere in the
   raw preview (`forbidden.secretAccess`), then the relay's other
   placeholders in the raw preview (`unclassifiable.previewNotFaithful`).
4. One strict JSON object (`unclassifiable.previewNotStrictJSON`).
5. Every decoded string, keys included: the topic, its names and the
   credential placeholder (`forbidden.secretAccess`), then the other
   placeholders (`unclassifiable.previewNotFaithful`), then hidden text
   (`unclassifiable.hiddenText`).
6. The never-sent floor again, over every decoded key and string, at every
   depth (`floor.<group>`).
7. MCP tools (`localOnly.mcp`), then a tool the table does not list
   (`unclassifiable.unknownTool`).
8. The tool's row: a key it does not list (`unknownArgument`), a missing
   required one (`missingArgument`), then every value. Every forbidden
   family found in any value is noted (`forbidden.<family>`: a location in
   a path whose shape passes — absolute, at most 1 KiB, printable ASCII
   without a backslash, no empty, `.` or `..` component, no trailing slash;
   in Bash, `dangerouslyDisableSandbox: true`, a substring of the command,
   and, when the grammar reads the command, a forbidden command leading one
   of its simple commands or a location in a later word of one, up to that
   simple command's first word with a `..` or an empty component); the
   first other refusal in the preview's order (`argumentKind`,
   `argumentValue`, `pathNotCanonical`, `commandOutsideGrammar`,
   `commandNotInTable`) keeps the prompt. Then the floor's rule that a
   command or a path is printable ASCII
   (`floorUnreadable.notPrintableASCII`).
9. The row's local-only code: `localOnly.fileEdit` for Write, Edit and
   NotebookEdit, `localOnly.read` for Read.
10. The set of prompts the gate is handed: a listed command with no family
    noted (the only set NapCat hands it).
11. Only then, and only for Bash, the gate's own copy of the preview and
    the forward.

A floor outcome keeps the prompt at once, with its own code, under every
setting. Every other prompt kept is logged with the first code, in this
order, that the set does not admit: the credential placeholder and each
forbidden family are noted where the order meets them, a family before the
row's other refusals, and every other refusal keeps the prompt at once.
Under the set NapCat hands the gate, which admits no family, that is the
first code the order meets: the code the gate logged before #253, unless the
floor names the prompt first.

So a Read that names the alert topic is `floor.alertTopic`; a Read of a
forbidden location keeps its family's code (or the floor's, where the floor
names the path) unless its preview, its keys or its path's shape are
malformed, and a malformed Read keeps its `unclassifiable` code; every other
Read is `localOnly.read`. NapCat's intake then applies its own holds: a
topic that exists but could not be read keeps every prompt as
`forbidden.secretAccess`, and while the feature is unarmed (every build so
far) each prompt the gate classified is logged `suppressed.notArmed` instead
of the gate's code.

## The never-sent floor

The floor names what a prompt may never carry off the Mac, whatever any
setting says. It reads the tool name and the raw preview first, before
anything else but the tool name's shape and the preview's size, and every
decoded key and string again once the preview is read (see "Precedence").
A match keeps the prompt with `floor.<group>`, for the first group, in this
order, that matches:

- `alertTopic`: the alert topic's own bytes.
- `ownNames`: NapCat's bundle and keychain names, its preference keys, its
  helper, watchdog, socket and receipt, its record zone, subscriptions,
  policy header and signing domains, its connector's tools
  (`mcp__napcat…`), and the word `napcat` (`pkill -x NapCat`, a folder
  named `NapCat`).
- `privilegedFootprint`: the root helper's folder (`/usr/local/napcat`),
  the sleep setting (`pmset -a disablesleep 1`), the sudoers file, the
  failsafe login item, the busy hook and the install scripts.
- `sourceTree`: NapCat's source folders and build files.
- `keychain`: the keychain as a whole: the `security` command in any letter
  case, the keychain files, the keychain API's names and the tool's item
  verbs (`find-generic-password`).
- `claudeCodeHelpers`: the files and settings that decide which helpers
  Claude Code runs and how its prompts are answered (`~/.claude.json`,
  `.mcp.json`, the managed settings and their folder), and the `claude`
  command.
- `signingAndICloud`: code signing (`codesign`), the certificate kind and
  team NapCat is signed with, provisioning profiles and Apple's CloudKit
  tool.

Each string is read as written, with every quote and backslash removed,
percent-decoded, and with doubled and `/./` slashes written once, in any
letter case; a word name (`napcat`, `security`, `claude`) matches a whole
word, also glued to an option cluster (`open -aNapCat`); free text is also
read case-folded, so a look-alike letter that folds to a name's letter (the
Kelvin sign, the long s) reads as that letter. The topic is matched by its
exact bytes, as written, without quotes and backslashes, and
percent-decoded.

Two codes keep a prompt the floor cannot judge, `floorUnreadable.<reason>`:

- `topic`: the gate is told an alert topic exists but is handed no
  value it can read, so no prompt can be checked against it and every
  prompt is kept.
- `notPrintableASCII`: a string the tool's row reads as a command or a path
  holds a byte outside printable ASCII. The row's own rules refuse such a
  string first today (`commandOutsideGrammar`, `pathNotCanonical`).

A floor outcome is final: it keeps the prompt under every setting, and it
comes before every other code the prompt could have (see "Precedence").
Anything the floor does not name is left to the gate's other rules, which
keep every prompt they cannot classify.

## The forbidden families

Checked by path, by command and by substring, in the order "Precedence"
gives: the alert topic for every prompt, the rest in the tool's row, before
that row's local-only code. An MCP tool or an unlisted tool has no row, so
apart from the alert topic its arguments are not checked against the
families: it is `localOnly.mcp` or `unclassifiable.unknownTool` whatever
they name (or a floor code, where the floor names them).

Each family the gate finds in a prompt is noted, every one of them, not
only the first; the set NapCat hands the gate admits none, so each keeps its
prompt, logged with the first family found. The floor comes first: an entry
below that the floor also names is logged with the floor's code, marked
(floor) here. Every other spelling keeps its family's code.

- **`forbidden.privilegeEscalation`**
  - `sudo` in any case, path or position: `sudo ls`, `SUDO ls`,
    `/usr/bin/sudo ls`, `ls && sudo make`, `echo $(sudo id)`.
  - Its relatives: `su`, `sudoedit`, `visudo`, `doas`, `pkexec`, `osascript`
    (and the words "administrator privileges"), `launchctl`, `dscl`,
    `dseditgroup`, `sysadminctl`, `authopen`, `chown`, `chgrp`, `pmset`
    (`pmset -a disablesleep 1`: floor), `nvram`.
  - System and privileged-helper locations: `/etc` and `/private/etc`
    (`/etc/sudoers`, `/etc/sudoers.d/…`: floor), `/usr` (including
    `/usr/local/bin`, and NapCat's own `/usr/local/napcat`: floor), `/bin`,
    `/sbin`, `/System`,
    `/Library/LaunchDaemons`, `/Library/PrivilegedHelperTools`, and any file
    named like an escalation command (a `PATH` shim such as `~/project/bin/sudo`).
  - Bash with `dangerouslyDisableSandbox: true`, kept under every setting.
- **`forbidden.configurationOrHooks`**
  - Claude Code's configuration: `~/.claude/…` (settings, hooks, agents),
    `.claude` in any project, `~/.claude.json` (floor), `.mcp.json` (floor),
    `CLAUDE.md`, `CLAUDE.local.md`, `managed-settings.json` (floor),
    `managed-mcp.json` (floor), `Library/Application Support/ClaudeCode`
    (floor: the system directory and the one in the home directory), in any
    letter case.
  - Code that runs later: `.git` (hooks, config), `~/.gitconfig`,
    `~/.config/git`, `.githooks`, `.husky`, `git config`, shell startup files
    (`.zshrc`, `.zshenv`, `.zprofile`, `.zlogin`, `.zlogout`, `.bashrc`,
    `.bash_profile`, `.bash_login`, `.bash_logout`, `.profile`), `.envrc`,
    `~/Library/LaunchAgents`, `/opt/homebrew/bin`, `crontab`.
  - The `claude` command itself (`claude mcp add …`: floor).
- **`forbidden.secretAccess`**
  - The keychain (floor): the `security` command, `~/Library/Keychains`,
    `*.keychain`, `*.keychain-db`.
  - Key and token files: `.ssh` and `id_rsa`/`id_dsa`/`id_ecdsa`/`id_ed25519`
    keys, `.gnupg`, `.aws`, `.azure`, `.kube`, `.docker`, `.netrc`,
    `.git-credentials`, `.npmrc`, `.pypirc`, `.pgpass`, `.password-store`,
    `~/.config/gh`, `~/.config/gcloud`, `.env` and `.env.*`, `credentials`,
    `credentials.json`, `*.pem`, `*.p12`, `*.pfx`, `*.p8`, `*.key`, `*.kdbx`.
  - The alert topic (floor): `<topic>` itself, the name of its keychain
    account and its retired defaults key, anywhere in the prompt, for every
    tool (in a Write's content too). NapCat's old defaults file
    (`com.muratalkan.napcat.plist`, floor) is also a location rule of this
    family.
  - The relay placeholders in `ApprovalGate.maskMarkers`, anywhere in the
    preview, the same way (see "Relay placeholders" below).

## Bash: listed commands only

Bash forwards only listed exact commands (CL-2, tightened in slice S-GATE):
the whole command must be, byte for byte, one of `git status`, `git diff`,
`make test`, `swift build`, `swift test` or `npm test`, with no option,
operand, joiner or extra space of its own (`ApprovalGate.bashCommands`; each
entry has its own audit test case). Its other arguments are fixed:
`run_in_background` absent or `false`, `dangerouslyDisableSandbox` absent or
`false`, and `timeout` absent or a whole number of milliseconds from 1 to
600,000; anything else there is `unclassifiable.argumentValue` (or
`forbidden.privilegeEscalation` outside the sandbox), under every setting.

A listed command is still kept when anything else in the prompt names the
floor: the description Claude Code sends alongside it (the model writes it,
and it never leaves the Mac) included. `git status` with the description
"Run the NapCat unit tests" is `floor.ownNames`; with "Show working tree
status" it forwards. A listed command whose description holds the relay's
credential placeholder is `forbidden.secretAccess`.

The positive grammar still runs first, as a refusal filter only: printable
ASCII, plain words joined by standalone `&&`, `||`, `|` or `;`. Each class
below is refused, as `unclassifiable.commandOutsideGrammar` when the grammar
cannot read it and `unclassifiable.commandNotInTable` when it reads but is
not a listed command, unless a forbidden family found in the command comes
first (see "Precedence").

| Class | Refused examples |
| :- | :- |
| Not listed | everything the grammar alone used to forward: `ls`, `ls -la`, `cat README.md`, `head -n 20 notes.txt`, `echo hello world`, `grep -n TODO Sources/App.swift`, `mkdir -p build/out`, `make`, `npm run test:unit`, `git add .`, `git commit -m '…'`, `git status \| head -n 5`, `make test && git status` |
| Near misses | `git status -s`, `git status --short`, `git diff HEAD`, two spaces, a leading or trailing space, `Git status`, `git 'status'`, `make tests`, `make test -j8`, `npm run test`, `swift build -c release`; a tab, a line break, a no-break space, a middle dot or a fullwidth letter between or in the words (`commandOutsideGrammar`); a zero-width character (`hiddenText`) |
| Chaining | `ls;pwd`, `ls & pwd`, a newline, carriage return or tab between commands, `ls \|& cat`, a dangling or doubled joiner; and, read but not listed, `ls \| sh`, `ls \| xargs rm`, `make test \|\| rm -rf build` |
| Expansion | `$(…)`, backticks, `$VAR`, `${…}`, `$'…'`, `$((…))`, `<(…)` and `>(…)`, history `!!`, each also inside quotes |
| Redirection | `>`, `>>`, `<`, `2>&1`, `&>`, `>\|`, heredocs and here-strings |
| Quoting | quote-split command names (`s'u'do`, `'ls'`, `l"s"`), backslash escapes, unterminated quotes, a backslash inside quotes, quoted options (`ls '-R'`) |
| Globbing and expansion characters | `*`, `?`, `[…]`, `{a,b}`, `~user`, `~+`, `~` inside a word, `=cmd`, `^`, `#` comments, parentheses |
| Wrappers and interpreters | variable assignments (`FOO=bar ls`, `PATH=/tmp ls`), `env`, `command`, `builtin`, `exec`, `eval`, `nice`, `nohup`, `time`, `timeout`, `xargs`, `sh -c`, `bash -c`, `zsh -c`, `python3 -c`, `node -e`, `perl -e`, `awk`, `source` and `.`, absolute or relative command paths, `cd`, `find -delete`, a command name in the wrong case |
| Options | anything not listed, including the ones that can run code or rewrite history: `git -c`, `git -C`, `--porcelain=v2`, `git commit --amend`, `--no-verify`, `git push`, `git diff --output=…`, `make -f`, `make SHELL=…`, `make --eval=…`, `grep -r`/`-R`/`--include`/`-f`, `ls -R`, `--`, unbounded or malformed counts (`head -n 9999999`, `head -n20`), `tail -f`, `npm install`, `swift run`, wrong operand counts |
| Paths | a word with a `..` or an empty component (`commandOutsideGrammar`); a word naming a forbidden location is that family (`ls /etc`), but in each simple command only the words after its name and before its first word with a `..` or an empty component are read as paths (see "Precedence"); a substring in `ApprovalGate.commandNeedles` is its family wherever it stands (`git add ../../.ssh` is `forbidden.secretAccess` by its `.ssh`) |
| Encoding | look-alikes and non-ASCII (a no-break space, fullwidth letters, a Cyrillic letter in a command name, an em dash), zero-width characters (`unclassifiable.hiddenText`), an empty or blank command, more than 2,048 bytes, 8 commands or 64 words, a NUL escape (`unclassifiable.previewNotStrictJSON`) |

The gate reads the prompt, not what a command goes on to do. A listed
command runs whatever the project's build files and tests say (`Makefile`,
`package.json`, `Package.swift`, the test code), and `git status` and
`git diff` run any program the repository's git configuration names, all
with your privileges. The phone would show only the command.

## Read: local-only, a path and plain numbers

No Read is forwarded, whatever its path (issue #231): a list of locations
cannot name every credential file. Claude Code does not ask, by default,
before a Read inside a session's working directories, and folders you trust
beyond those belong in Claude Code's own settings (an allow rule or an
added directory), which NapCat never edits. A Read prompt is still checked
in full: one that names the alert topic or a forbidden location keeps that
code (see "Precedence"), a malformed one its `unclassifiable` code, and one
that passes every check is `localOnly.read`. The checks take a canonical
path (see "Paths" below) and, since issue #149, its optional arguments only
in the shapes the Read tool writes:

- `pages` absent, or a PDF page range: one page (`"3"`) or a range
  (`"1-5"`, `"10-20"`), pages counted from 1 up to 99,999, the first no later
  than the last, and at most 20 pages (the tool's own maximum per request);
- `offset` absent, or a line number from 0 to 10,000,000;
- `limit` absent, or a line count from 1 to 100,000.

Each is written plainly: ASCII digits only, with no sign, fraction, exponent,
space or leading zero, and the one hyphen of a range. Anything else there is
`unclassifiable.argumentValue`. `pages` was free text the model writes and
the phone showed, the channel the Bash description was closed for; a Read
that passes is a canonical path and plain numbers, nothing else.

| Class | Refused examples |
| :- | :- |
| Words | anything but a page range in `pages` (`"read-only status check, safe to approve"`, `"1-3 (safe to approve)"`), 600 characters of anything |
| Page shapes | `"0"`, `"0-3"`, `"01"`, `"1-05"`, an empty string, `"-"`, `"1-"`, `"-5"`, `"1--2"`, `"1-2-3"`, `"1,3"`, `"1 - 5"`, `" 3"`, `"3 "`, `"+3"`, `"1e5"`, `"1.5"`, an en dash, six digits |
| Page bounds | an inverted range (`"5-1"`), more than 20 pages (`"1-21"`, `"1-25"`, `"99979-99999"`) |
| Numbers | a sign (`-5`, `-0`), a fraction (`1.5`, `1.0`), an exponent (`1e3`, `1E+3`, `1e308`), past the bound (an `offset` of 10,000,001, a `limit` of 100,001 or 0); a leading zero (`01`) is `unclassifiable.previewNotStrictJSON` |
| Encoding | non-ASCII digits (Arabic-Indic, fullwidth), and any invisible character in `pages`, including the ones the hidden-text list does not hold (variation selectors, Hangul fillers, Mongolian variation selectors); one it does hold is `unclassifiable.hiddenText` |
| Types | `pages` as a number, an array or null; `offset` or `limit` as a string, a boolean or null (`unclassifiable.argumentKind`) |
| Keys | `allow_large`, either value, like every other key not listed (`unclassifiable.unknownArgument`) |

### The path alphabet

Since issue #159, a path passes the path check only when every character is
printable ASCII from `!` to `~` other than the double quote `"` and the
backslash `\`.
That leaves 92 characters: letters, digits and
`` ! # $ % & ' ( ) * + , - . / : ; < = > ? @ [ ] ^ _ ` { | } ~ ``. Every
other character is refused, as one of three codes:

- `unclassifiable.pathNotCanonical`: the space, the double quote, the
  backslash, a tab, a newline, a carriage return, and any non-ASCII
  character the "Hidden text" bullet below does not name (an accented
  letter, a look-alike letter, a middle dot).
- `unclassifiable.hiddenText`: every other control character but NUL (the
  rest of C0, DEL and C1), and every other character that bullet names. It
  is checked in every string in the preview, before any path rule.
- `unclassifiable.previewNotStrictJSON`: NUL, because a NUL escape is not
  strict JSON (see "The preview" below).

Each code is for the character as JSON escapes it. Written raw, a C0 control
is not strict JSON at all, so it is `previewNotStrictJSON` too.

The space and the double quote are checked after the forbidden families, so
a forbidden path holding either one is still logged as its family
(`ApprovalGate.pathBytesRefusedAfterFamilies`).

Why the double quote:

- The phone shows the gate's copy of a forwarded prompt verbatim, as JSON,
  in a monospaced face; a Read's copy was `{"file_path":"…","offset":…}`.
- Every boundary between its members holds a double quote.
- The copy writes a quote inside a path as `\"`. So the path
  `/tmp/a","limit":1` would be drawn `{"file_path":"/tmp/a\",\"limit\":1"}`,
  which can read as a second member.

Without the double quote, and with the backslash already refused, a path
puts no quote into the copy at all. The only quotes left are the copy's own,
two per key and two per string value. So braces, brackets, commas, colons
and the rest of the punctuation can only read as part of the one quoted
path. They stay allowed, because real paths hold them: `app/[slug]/page.tsx`,
`app/(marketing)/page.tsx`, `{{cookiecutter.project_slug}}`, `a,b.csv`,
`12:30.log`.

The single quote and the backquote stay allowed too. In the monospaced
drawing each one is a single mark in a cell of its own, and two of them take
two cells; a double quote is one glyph in one cell.

None of this widens what an Allow authorizes. An Allow still covers only the
named tool on that exact path, so this rule protects what the phone
displays, not what can run.

Since issue #231 no tool with a path forwards (the file-edit tools have not
since slice S-GATE, and Read no longer does), so today these rules only
decide which code such a prompt is kept with.

## Every other tool and shape (fail closed)

- **Tool names:** only `Bash`, `Write`, `Edit`, `NotebookEdit` and `Read`,
  exactly. Unknown tools (`WebFetch`, `Glob`, `Task`), the wrong case, a
  space, a look-alike letter or more than 64 bytes are
  `unclassifiable.unknownTool` or `unclassifiable.malformedToolName` (an
  unknown tool's own code comes after the checks "Precedence" puts first,
  as an MCP tool's does).
- **File-edit tools** (`Write`, `Edit`, `NotebookEdit`) are local-only since
  slice S-GATE: each prompt is still checked in full, so a forbidden or
  malformed one is logged for what it is, and one that passes every check is
  `localOnly.fileEdit`.
- **Read** is local-only since issue #231, whatever its path, the same way:
  one that passes every check is `localOnly.read` (see "Read" above). Only
  `Bash` can forward.
- **MCP tools** (`mcp__…`) are `localOnly.mcp` in the MVP, whatever their
  arguments name, unless a check that comes first in "Precedence" (the
  tool name's shape, the preview's size or form, the floor, a relay
  placeholder, hidden text) gives its own code: NapCat's own connector
  (`mcp__napcat…`) is `floor.ownNames`.
- **The preview** must be one strict JSON object of at most 32 KiB and at
  most 3,000 code points as relayed:
  empty, plain text, an array or a string, truncated, trailing text or comma,
  a duplicate key, single quotes, a byte order mark, a leading zero, a plus
  sign, a bare fraction dot, NaN, a lone surrogate, a raw newline in a
  string, an unknown escape or a NUL escape are
  `unclassifiable.previewNotStrictJSON` (or `previewTooLarge`).
- **Relay placeholders:** a preview holding any of the relay's placeholders
  in `ApprovalGate.unfaithfulMarkers` (in its raw text or in any decoded
  string or key, escaped or not, in any letter case, even when the preview
  does not parse) is `unclassifiable.previewNotFaithful`, for every tool and
  before any tool rule; one holding a placeholder in `ApprovalGate.maskMarkers`
  is `forbidden.secretAccess`.
- **Arguments** are an exact, typed set per tool: an unknown or look-alike
  key, a missing required one or the wrong JSON type (a command as an array
  or null, a timeout or boolean as a string) are `unknownArgument`,
  `missingArgument` or `argumentKind`; a Bash or Read value of the right type
  that is not allowed (above) is `argumentValue`.
- **Paths** must be absolute and canonical: relative, `~`, `..`, `.`, `//`, a
  trailing slash, `/` alone, a backslash or a Windows path, non-ASCII, a
  look-alike letter, a tab, a space, a double quote (written plainly or as
  `\u0022`), a middle dot or more than 1 KiB are
  `unclassifiable.pathNotCanonical`. A forbidden path with a space or a
  double quote is still logged as its family. The full alphabet is in "The
  path alphabet" above.
- **Hidden text:** a character that renders invisibly or reorders text,
  anywhere in the preview (C0 and C1 controls other than tab, newline and
  carriage return, the soft hyphen, zero-width and joiner characters, bidi
  marks, embeddings, overrides and isolates, the byte order mark, the
  interlinear annotation controls, tag characters) is
  `unclassifiable.hiddenText`: the phone could not show what would be
  approved.
- **What leaves the Mac** for a forwarded prompt is the gate's own copy of its
  preview (`ApprovalGate.forwardedPreview`): the members the tool's row
  checks, re-serialized, without the Bash `description` member, which the
  gate reads only to refuse. The relayed text itself is never saved.

## The seam and the server (S1)

What is refused before the gate ever sees a prompt, or after:

- **MCP lines from Claude Code:** anything that is not one strict JSON-RPC
  2.0 message (a wrong or missing `jsonrpc`, a duplicate or extra member, a
  null, fractional, exponent, boolean, array or 20-digit id, a batch,
  trailing text, a byte order mark, a NUL escape, invalid UTF-8) gets no
  answer and has no effect. A verdict-shaped notification arriving from
  Claude Code is ignored, never echoed.
- **Permission requests:** a request ID other than five letters from a to z
  without l; a missing, extra or non-string field; anything before the
  handshake; anything in a session whose client is not exactly a confirmed
  Claude Code build (`ApprovalChannel.confirmedClients`, name and version byte
  for byte) or did not name itself at `initialize` (the handshake is still
  answered; a later handshake can only keep prompts local); a request ID seen
  before; a prompt too large for one frame; more than 32 waiting at once.
  None is relayed.
- **Seam frames:** not exactly the members of its kind, another frame
  version (including `1`, the version before #150, and `"2"`, `2.0` and
  `20e-1`), a prompt frame's server version other than an integer or its
  client or client version other than a string, a verdict other than exactly
  `allow` or `deny`, the other side's kind, more than 256 KiB, invalid UTF-8.
  Each is refused and closes the connection.
- **Another server or client (#150):** a prompt frame from a server of
  another version than NapCat's own, or naming a client that is not exactly
  a confirmed Claude Code build (byte for byte, as the server checks it), is
  refused by NapCat's intake before the gate, logged
  `seam.serverVersionRefused` or `seam.clientRefused`, and closes the
  connection; no prompt ID is drawn and nothing is saved.
- **Verdicts:** since #221 the server drops every verdict frame its strict
  reader accepts, for an open request too (`relay: verdictWithheld`): it
  passes no answer back to Claude Code until the seam checks which program
  listens. Once it does, a verdict for a request the server never relayed,
  already answered, or open on a link that has since closed is dropped. On
  NapCat's side only a valid, signed decision inside the TTL for a forwarded
  prompt becomes a verdict frame; an unsigned, wrong-version, early, late,
  duplicate or retracted one is ignored and logged with its reason.
- **Peers:** another user by socket credentials or by audit token, or
  credentials that cannot be read, are closed before a byte is read. A
  socket outside a private directory, a symlink or any other kind of file at
  the socket path is never connected to and never replaced.
