# F4: the refusal catalogue

Status: regenerated in slice S1 (issue #125) from the test rows, which are
normative, and revised in slice S-GATE (issue #145), which only made the gate
stricter. `Tests/NapCatTests/ApprovalClassificationTests.swift` pins every
gate entry below and the S1 tests (`ChannelRelayTests`, `ApprovalChannelTests`,
`ApprovalSeamTests`, `ApprovalIntakeTests`) pin the seam and server entries;
where a row and this note differ, the row wins. Companion to
[remote-approvals.md](remote-approvals.md).

Each entry is something a prompt could carry and what happens to it. Nothing
listed here is ever forwarded: a refused prompt stays fully answerable in the
terminal and is only logged, by its code. The codes are the gate's own:
`forbidden.<family>`, `localOnly.mcp`, `localOnly.fileEdit` and
`unclassifiable.<reason>`. In the
examples, `~` stands for an absolute home directory and `<topic>` for the
alert topic; the tests use synthetic values for both.

## The forbidden families

Checked first, for every tool, by path, by command and by substring.

- **`forbidden.privilegeEscalation`**
  - `sudo` in any case, path or position: `sudo ls`, `SUDO ls`,
    `/usr/bin/sudo ls`, `ls && sudo make`, `echo $(sudo id)`.
  - Its relatives: `su`, `sudoedit`, `visudo`, `doas`, `pkexec`, `osascript`
    (and the words "administrator privileges"), `launchctl`, `dscl`,
    `dseditgroup`, `sysadminctl`, `authopen`, `chown`, `chgrp`, `pmset`,
    `nvram`.
  - System and privileged-helper locations: `/etc` and `/private/etc`
    (`/etc/sudoers`, `/etc/sudoers.d/…`), `/usr` (including `/usr/local/bin`
    and NapCat's own `/usr/local/napcat`), `/bin`, `/sbin`, `/System`,
    `/Library/LaunchDaemons`, `/Library/PrivilegedHelperTools`, and any file
    named like an escalation command (a `PATH` shim such as `~/project/bin/sudo`).
  - Bash with `dangerouslyDisableSandbox: true`.
- **`forbidden.configurationOrHooks`**
  - Claude Code's configuration: `~/.claude/…` (settings, hooks, agents),
    `.claude` in any project, `~/.claude.json`, `.mcp.json`, `CLAUDE.md`,
    `CLAUDE.local.md`, `managed-settings.json`, `managed-mcp.json`,
    `Library/Application Support/ClaudeCode` (the system directory and the
    one in the home directory), in any letter case.
  - Code that runs later: `.git` (hooks, config), `~/.gitconfig`,
    `~/.config/git`, `.githooks`, `.husky`, `git config`, shell startup files
    (`.zshrc`, `.zshenv`, `.zprofile`, `.zlogin`, `.zlogout`, `.bashrc`,
    `.bash_profile`, `.bash_login`, `.bash_logout`, `.profile`), `.envrc`,
    `~/Library/LaunchAgents`, `/opt/homebrew/bin`, `crontab`.
  - The `claude` command itself (`claude mcp add …`).
- **`forbidden.secretAccess`**
  - The keychain: the `security` command, `~/Library/Keychains`,
    `*.keychain`, `*.keychain-db`.
  - Key and token files: `.ssh` and `id_rsa`/`id_dsa`/`id_ecdsa`/`id_ed25519`
    keys, `.gnupg`, `.aws`, `.azure`, `.kube`, `.docker`, `.netrc`,
    `.git-credentials`, `.npmrc`, `.pypirc`, `.pgpass`, `.password-store`,
    `~/.config/gh`, `~/.config/gcloud`, `.env` and `.env.*`, `credentials`,
    `credentials.json`, `*.pem`, `*.p12`, `*.pfx`, `*.p8`, `*.key`, `*.kdbx`.
  - The alert topic: `<topic>` itself anywhere in the prompt, the name of its
    keychain account, its retired defaults key and NapCat's old defaults file,
    for every tool (in a Write's content too).
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
`forbidden.privilegeEscalation` outside the sandbox).

The positive grammar still runs first, as a refusal filter only: printable
ASCII, plain words joined by standalone `&&`, `||`, `|` or `;`. Each class
below is refused, as `unclassifiable.commandOutsideGrammar` when the grammar
cannot read it and `unclassifiable.commandNotInTable` when it reads but is
not a listed command.

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
| Paths | `..` and empty components; and any word naming a forbidden location is that family (`ls /etc`, `git add ../../.ssh`) |
| Encoding | look-alikes and non-ASCII (a no-break space, fullwidth letters, a Cyrillic letter in a command name, an em dash), zero-width characters (`unclassifiable.hiddenText`), an empty or blank command, more than 2,048 bytes, 8 commands or 64 words, a NUL escape (`unclassifiable.previewNotStrictJSON`) |

## Every other tool and shape (fail closed)

- **Tool names:** only `Bash`, `Write`, `Edit`, `NotebookEdit` and `Read`,
  exactly. Unknown tools (`WebFetch`, `Glob`, `Task`), the wrong case, a
  space, a look-alike letter or more than 64 bytes are
  `unclassifiable.unknownTool` or `unclassifiable.malformedToolName`.
- **File-edit tools** (`Write`, `Edit`, `NotebookEdit`) are local-only since
  slice S-GATE: each prompt is still checked in full, so a forbidden or
  malformed one is logged for what it is, and one that passes every check is
  `localOnly.fileEdit`. Only `Bash` and `Read` can forward.
- **MCP tools** (`mcp__…`) are `localOnly.mcp` in the MVP, whatever their
  arguments.
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
  `missingArgument` or `argumentKind`; a Bash value of the right type that is
  not allowed (above) is `argumentValue`.
- **Paths** must be absolute and canonical: relative, `~`, `..`, `.`, `//`, a
  trailing slash, `/` alone, a backslash or a Windows path, non-ASCII, a
  look-alike letter, a tab, a space, a middle dot or more than 1 KiB are
  `unclassifiable.pathNotCanonical` (a forbidden path with a space is still
  logged as its family).
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
  version (including `"1"`, `1.0` and `10e-1`), a verdict other than exactly
  `allow` or `deny`, the other side's kind, more than 256 KiB, invalid UTF-8.
  Each is refused and closes the connection.
- **Verdicts:** for a request the server never relayed, already answered, or
  open on a link that has since closed, a verdict is dropped. On NapCat's
  side only a valid, signed decision inside the TTL for a forwarded prompt
  becomes a verdict frame; an unsigned, wrong-version, early, late, duplicate
  or retracted one is ignored and logged with its reason.
- **Peers:** another user by socket credentials or by audit token, or
  credentials that cannot be read, are closed before a byte is read. A
  socket outside a private directory, a symlink or any other kind of file at
  the socket path is never connected to and never replaced.
