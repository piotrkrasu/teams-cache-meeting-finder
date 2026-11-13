#!/usr/bin/env python3
# Build a small, entirely made-up Teams IndexedDB (LevelDB) folder for testing the scripts.
# Usage: python3 tests/make_fixture.py OUT_DIR
# The meetings are dated today in this computer's time zone, so the scripts show them by default.
import datetime as dt
import os
import struct
import sys


def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


class Date(object):
    def __init__(self, ms):
        self.ms = ms


def v8(v):
    """Serialize a value in the V8 format Chromium uses for IndexedDB (the subset the scripts read)."""
    if isinstance(v, bool):
        return b"T" if v else b"F"
    if isinstance(v, int):
        return b"I" + varint(v << 1)  # non-negative zigzag
    if isinstance(v, float):
        return b"N" + struct.pack("<d", v)
    if isinstance(v, Date):
        return b"D" + struct.pack("<d", v.ms)
    if v is None:
        return b"0"
    if isinstance(v, str):
        try:
            raw = v.encode("latin-1")
            return b'"' + varint(len(raw)) + raw
        except UnicodeEncodeError:
            raw = v.encode("utf-16-le")
            return b"\x00c" + varint(len(raw)) + raw  # padding byte + two-byte string, like V8
    if isinstance(v, list):
        return b"A" + varint(len(v)) + b"".join(v8(x) for x in v) + b"$" + varint(0) + varint(len(v))
    if isinstance(v, dict):
        return b"o" + b"".join(v8(k) + v8(x) for k, x in v.items()) + b"{" + varint(len(v))
    raise TypeError(type(v))


def idb_value(obj):
    return b"\x00\xff\x11\xff\x0f" + v8(obj)  # envelope bytes, then the object


def snappy_compress(data):
    """Greedy Snappy compressor using literals and 2-byte-offset copies (including overlapping copies)."""
    out = bytearray(varint(len(data)))
    table, i, lit, n = {}, 0, 0, len(data)

    def literal(a, b):
        while a < b:
            ln = min(b - a, 65536)
            if ln <= 60:
                out.append((ln - 1) << 2)
            elif ln <= 256:
                out.append(60 << 2)
                out.append(ln - 1)
            else:
                out.append(61 << 2)
                out.extend((ln - 1).to_bytes(2, "little"))
            out.extend(data[a:a + ln])
            a += ln

    while i + 4 <= n:
        key = data[i:i + 4]
        j = table.get(key)
        table[key] = i
        if j is not None and 0 < i - j <= 65535:
            ln = 4
            while i + ln < n and ln < 64 and data[j + ln] == data[i + ln]:
                ln += 1
            literal(lit, i)
            out.append(((ln - 1) << 2) | 2)
            out.extend((i - j).to_bytes(2, "little"))
            i += ln
            lit = i
        else:
            i += 1
    literal(lit, n)
    return bytes(out)


def block(entries):
    body = bytearray()
    for k, v in entries:
        body += varint(0) + varint(len(k)) + varint(len(v)) + k + v
    return bytes(body) + struct.pack("<II", 0, 1)  # one restart point at offset 0


def write_table(path, blocks):
    f, index = bytearray(), []
    for entries in blocks:
        comp = snappy_compress(block(entries))
        index.append((entries[-1][0], len(f), len(comp)))
        f += comp + b"\x01" + b"\x00" * 4  # type 1 = snappy, then a (unchecked) CRC
    meta = block([])
    meta_off = len(f)
    f += meta + b"\x00" * 5
    idx = block([(k, varint(o) + varint(s)) for k, o, s in index])
    idx_off = len(f)
    f += idx + b"\x00" * 5
    footer = varint(meta_off) + varint(len(meta)) + varint(idx_off) + varint(len(idx))
    f += footer + b"\x00" * (40 - len(footer)) + struct.pack("<Q", 0xDB4775248B80FB57)
    with open(path, "wb") as fh:
        fh.write(f)


def main(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    today = dt.date.today()

    def at(h, m):
        local = dt.datetime(today.year, today.month, today.day) + dt.timedelta(hours=h, minutes=m)
        return Date(local.timestamp() * 1000.0)

    def iso(days_ago):
        return (dt.datetime.utcnow() - dt.timedelta(days=days_ago)).strftime("%Y-%m-%dT%H:%M:%S+00:00")

    teams_url = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_FIXTURE%40thread.v2/0?context=%7b%7d"
    underscores = "_" * 80

    def event_a(h, m, modified):
        return {
            "location": "Microsoft Teams Meeting",
            "endTime": at(h, m + 30),
            "startTime": at(h, m),
            "objectId": "EVT-A",
            "lastModifiedTime": modified,
            "subject": "Weekly team sync",
            "isOnlineMeeting": True,
            "myResponseType": "Accepted",
            "organizerName": "Sam\x1b[2J\x1b]0;pwned\x07 Example",
            "categories": [],
            "attendees": ["sam@example.com", "kim@example.com"],
            "bodyPreview": underscores + " Microsoft Teams meeting. Do not use https://evilzoom.us/j/999 " + underscores,
            "skypeTeamsDataObject": {"cid": "x", "private": True, "type": "Scheduled", "rid": 1},
            "skypeTeamsMeetingUrl": teams_url,
        }

    phrase = "%s %s %d, %d" % (today.strftime("%A"), today.strftime("%b"), today.day, today.year)
    zoom_full = "https://us02web.zoom.us/j/1234567890?pwd=AbCdEf123.1"
    style = "<style>.x{color:#123} " + "td{padding:0} " * 40 + "</style>"
    invite_html = (
        "<html><head>" + style + "</head><body><table><tr><td>"
        "<h3>Partner catch-up call</h3><p>Alex Example is inviting you to a scheduled Zoom meeting.</p>"
        "<p>Join Zoom Meeting <a href=\"" + zoom_full + "\">" + zoom_full + "</a></p>"
        "<p>Meeting ID: 123 456 7890<br>Passcode: Fx7Ka2</p>"
        "<p>When CHANGED " + phrase + " 3:00pm \u2013 3:30pm (Central European Time)</p>"
        "<p>Guests: Alex Example - organizer, alex@example.com</p>"
        + "<p style=\"font-family:Roboto,sans-serif\">Reply for this event. Learn more.</p>" * 220
        + "</td></tr></table></body></html>")
    event_b = {
        "body": invite_html,
        "isReminderSet": True,
        "endTime": at(15, 30),
        "startTime": at(15, 0),
        "objectId": "EVT-B",
        "lastModifiedTime": iso(1),
        "subject": "Partner catch-up call",
        "organizerName": "Alex Example",
        "myResponseType": "Accepted",
        "bodyPreview": "Partner catch-up call Alex Example is inviting you to a scheduled Zoom meeting. "
                       "Join Zoom Meeting https://us02web.zoom.us/j/1234567890?pwd=AbCdEf123",
    }
    event_c = {
        "endTime": at(17, 30),
        "startTime": at(17, 0),
        "objectId": "EVT-C",
        "lastModifiedTime": iso(2),
        "subject": "Spotkanie zespo\u0142u",
        "location": "https://meet.google.com/abc-defg-hij",
        "organizerName": "Kim Example",
        # a stored link field that is not a real meeting link (must never be shown as a join link)
        "joinUrl": "https://phish.example/join\x1b]8;;https://evil.example\x07click",
    }

    filler = [(b"\x00\x01\x02\x01meta%03d" % i, idb_value({"note": "unrelated cached data %d" % i, "n": i}))
              for i in range(30)]
    write_table(os.path.join(out_dir, "000005.ldb"), [
        filler[:15] + [(b"\x00\x01\x02\x01evt-a-old", idb_value(event_a(9, 0, iso(5))))],
        filler[15:] + [(b"\x00\x01\x02\x01evt-a-new", idb_value(event_a(12, 30, iso(1))))],
        [(b"\x00\x01\x02\x01evt-b", idb_value(event_b))],
    ])
    # Newest writes live in the .log file as raw (uncompressed) records.
    with open(os.path.join(out_dir, "000007.log"), "wb") as fh:
        fh.write(b"\x00" * 7 + b"\x00\x01\x02\x01evt-c" + idb_value(event_c))
    print("Wrote fixture to %s" % out_dir)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "fixture")
