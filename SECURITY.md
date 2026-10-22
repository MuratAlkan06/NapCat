# Security Policy

## Supported versions

Only the latest tagged release receives security fixes. There are no
backports.

| Version                          | Supported |
|----------------------------------|-----------|
| The latest tagged release        | Yes       |
| Anything older                   | No        |

If you are on an older tag, update to the latest one and re-run
`sudo ./scripts/setup.sh`. It is idempotent, so the installed sudoers
entries and helper end up matching the version you are running.

## Reporting a vulnerability

Report it privately through GitHub's **private vulnerability reporting**:
open this repository's **Security** tab and click **Report a vulnerability**
(direct link: <https://github.com/MuratAlkan06/NapCat/security/advisories/new>).
Please do not open a public issue, pull request, or discussion for a suspected
vulnerability.

A useful report includes the NapCat tag or commit, your macOS version and Mac
model (Apple Silicon or Intel), steps to reproduce, and the impact you
observed. **Never include your ntfy topic.** It is a credential, so redact it
from logs, screenshots, and command lines before attaching them.

Please allow reasonable time for a fix before any public disclosure. The
discussion and the eventual advisory happen in the private report thread.

## Security model in brief

NapCat itself always runs unprivileged, as your user, and never asks for,
stores, or uses your password. Its only privileged operations are toggling
`pmset disablesleep` and pausing or resuming battery charging through two SMC
keys. Both go through `sudo -n` with a fixed set of NOPASSWD sudoers entries,
each an exact, argument-complete command string with no wildcards. Those
entries are installed only by `scripts/setup.sh`, a short script you read and
run yourself; the app never installs or changes them. They point at a
root-owned helper outside the app bundle (`/usr/local/napcat/smc`), so the
helper cannot be swapped without already being root. The optional lid-close
alert uses an ntfy topic that is a bearer credential: anyone who knows it can
read and post to the feed. It is stored only in NapCat's user defaults
(`com.muratalkan.napcat`), is never written to the log or shown in the menu,
and is deleted by `scripts/uninstall.sh`. The full rationale and the honest
trade-offs are in the README's
[Security model](README.md#security-model) section.
