-- NapCat lid-close alert sender (Track B, slice B2).
--
-- FIXED script, shipped as an app-bundle resource (precedent:
-- Resources/napcat-watchdog.sh) and invoked as:
--
--     /usr/bin/osascript <this file> <recipient> <body>
--
-- Both values arrive through argv. They are NEVER interpolated into this
-- source, so nothing a caller supplies can be re-parsed as AppleScript.
-- The message body itself is app-generated from a fixed template
-- (LidGuardPolicy.messageBody) — no session, transcript, or path text can
-- reach it.
--
-- Unprivileged: no elevated rights and no entitlement are involved, only the
-- user's Automation (TCC) grant for Messages, which is obtained by the
-- config-time test send while the user is present.

on run argv
	if (count of argv) is not 2 then error "napcat: expected a recipient and a body argument"
	set theRecipient to item 1 of argv
	set theBody to item 2 of argv
	with timeout of 8 seconds
		tell application "Messages"
			send theBody to participant theRecipient of (1st account whose service type is iMessage)
		end tell
	end timeout
end run
