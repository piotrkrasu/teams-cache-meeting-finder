#!/usr/bin/env python3
# Check a script's output against the made-up meetings in tests/make_fixture.py.
# Usage: python3 tests/check_output.py OUTPUT_FILE
import sys

raw = open(sys.argv[1], "rb").read()
if raw.startswith(b"\xff\xfe"):
    text = raw.decode("utf-16")          # Windows PowerShell 5.1 writes UTF-16 files
elif raw.startswith(b"\xef\xbb\xbf"):
    text = raw[3:].decode("utf-8", "replace")
else:
    text = raw.decode("utf-8", "replace")
text = text.replace("\r\n", "\n")

must = [
    "Calendar events in cache: 3",
    "12:30-13:00  Weekly team sync",
    "Join link : https://teams.microsoft.com/l/meetup-join/19%3ameeting_FIXTURE%40thread.v2/0?context=%7b%7d",
    "Organizer : Sam [2J ]0;pwned Example",
    "15:00-15:30  Partner catch-up call",
    "Join link : https://us02web.zoom.us/j/1234567890?pwd=AbCdEf123.1",
    "Zoom ID   : 123 456 7890   Passcode: Fx7Ka2",
    "Emails seen near this invite: alex@example.com",
    "17:00-17:30  Spotkanie zespo",
    "Join link : https://meet.google.com/abc-defg-hij",
    "Invites / messages in the cache that mention",
    "\n[1] ...",
    "Meeting ID: 123 456 7890 Passcode: Fx7Ka2 When CHANGED",
]
must_not = [
    "09:00-09:30",      # stale cached version of the moved meeting
    "link : https://evilzoom", "link: https://evilzoom",   # look-alike link offered as a join link
    "phish.example", "evil.example",                     # untrusted stored link field
    "\x1b", "\x07",     # terminal control codes
    "Traceback", "Exception",
]

failed = 0
for s in must:
    ok = s in text
    failed += not ok
    print("%s  contains %r" % ("PASS" if ok else "FAIL", s))
for s in must_not:
    ok = s not in text
    failed += not ok
    print("%s  lacks    %r" % ("PASS" if ok else "FAIL", s))
if "Spotkanie zespo\u0142u" not in text:
    print("note: non-ASCII subject not shown exactly (console encoding); not a failure")
print("%d check(s) failed" % failed if failed else "All checks passed")
sys.exit(1 if failed else 0)
