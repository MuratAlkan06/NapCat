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
helper cannot be swapped without already being root. sudo matches an entry's
arguments as one space-joined string, which is why the entries are never
widened with wildcards. The optional lid-close and session alerts share an
ntfy topic that is a bearer credential: anyone who knows it can read and post
to the feed. It is stored as one generic-password item in your login keychain
(service `com.muratalkan.napcat`, account `ntfy-topic`) and is never synced
through iCloud Keychain. An older NapCat kept it in its user defaults
(`com.muratalkan.napcat`); the first launch of a keychain-era build moves it
across and deletes the plaintext copy only after the keychain copy reads back
identical, keeping it (and retrying at the next launch) if that fails. NapCat
reads the item once at startup and keeps the topic in memory. It is never
written to the log or shown in the menu (the settings dialog masks it unless
you tick Show), and `scripts/uninstall.sh` deletes the keychain item and the
user defaults without printing either. The full rationale and the honest
trade-offs are in the README's [Security model](README.md#security-model)
section.

## The paired iPhone key

Remote approvals (a preview, off by default) pair one iPhone with the Mac.
The Mac keeps that phone's **public** key as one generic-password item in
your login keychain: service `com.muratalkan.napcat`, account
`paired-iphone-key`, shown in Keychain Access as **NapCat paired iPhone
key**. The item holds the phone's P-256 public key, the short code both
devices showed, and when it was paired, as text. It asks for no
synchronization, so iCloud Keychain never carries it off this Mac.

It is not a secret, but it is what the Mac would trust a signed answer by,
so its integrity matters: NapCat writes it only when you confirm, on the
Mac, that both devices show the same code, and a new pairing replaces it in
one write. **Unpair…** in Settings › Claude asks the keychain to delete it
and turns Remote approvals off either way. If the keychain refuses, the
item stays: Settings › Claude re-reads it, so a pairing still there still
shows, and NapCat logs `pairing.unpairFailed`. `scripts/uninstall.sh`
deletes it too, as you and without printing it. The keychain's access
prompt guards reading this item, not replacing it: software already
running as you can replace it without a prompt, so the key is as
trustworthy as your user account, no more.

While a pairing is under way, the iPhone's reply travels as one record in
your iCloud private database, every field but the format version
encrypted, and the Mac asks iCloud to delete it when the pairing ends. A
deletion that did not go through is tried again at each later launch,
until it does or a new pairing starts; a reply the iPhone saves after the
Mac's pairing has ended is not deleted. The pairing code
on the Mac's screen never leaves it: the record is named after a hash of
that code, which is how the Mac finds it, and it carries only a proof that
the phone saw the code. Pair in private while the code is up.
