#!/usr/bin/env python3
# teams_meetings.py - list today's meetings and join links from the Microsoft Teams
# desktop app's local cache. Useful when Teams/Outlook are down.
# Read-only and offline: it only reads Teams' cache files on this computer and sends nothing.
# Usage:  python3 teams_meetings.py [DAYS]    (DAYS = how many days to show from today, default 1)
import datetime as dt
import glob
import html
import os
import re
import struct
import sys
from collections import Counter

try:
    sys.stdout.reconfigure(errors="replace")
except Exception:
    pass

DAYS = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else 1


# ---------------------------------------------------------------- locate the cache
def find_stores():
    override = os.environ.get("TEAMS_CACHE_DIR")  # for testing: read this LevelDB folder instead
    if override:
        return [override] if os.path.isdir(override) else []
    home = os.path.expanduser("~")
    pats = [
        os.path.join(home, "Library/Containers/com.microsoft.teams2/Data/Library/Application Support/"
                           "Microsoft/MSTeams/EBWebView/WV2Profile_*/IndexedDB/https_teams.*.indexeddb.leveldb"),
        os.path.join(home, "Library/Application Support/Microsoft/Teams/IndexedDB/https_teams.*.indexeddb.leveldb"),
    ]
    if os.environ.get("LOCALAPPDATA"):
        pats.append(os.path.join(os.environ["LOCALAPPDATA"], "Packages", "MSTeams_8wekyb3d8bbwe", "LocalCache",
                                 "Microsoft", "MSTeams", "EBWebView", "WV2Profile_*", "IndexedDB",
                                 "https_teams.*.indexeddb.leveldb"))
    if os.environ.get("APPDATA"):
        pats.append(os.path.join(os.environ["APPDATA"], "Microsoft", "Teams", "IndexedDB",
                                 "https_teams.*.indexeddb.leveldb"))
    found = []
    for p in pats:
        found += [x for x in glob.glob(p) if os.path.isdir(x)]
    return found


# ---------------------------------------------------------------- LevelDB + Snappy
def varint(b, p):
    r = s = 0
    while True:
        c = b[p]
        p += 1
        r |= (c & 0x7F) << s
        if c < 0x80:
            return r, p
        s += 7


def snappy(b):
    _, p = varint(b, 0)
    out = bytearray()
    while p < len(b):
        tag = b[p]
        p += 1
        kind = tag & 3
        if kind == 0:
            n = tag >> 2
            if n >= 60:
                k = n - 59
                n = int.from_bytes(b[p:p + k], "little")
                p += k
            n += 1
            out += b[p:p + n]
            p += n
            continue
        if kind == 1:
            n = ((tag >> 2) & 7) + 4
            off = ((tag >> 5) << 8) | b[p]
            p += 1
        elif kind == 2:
            n = (tag >> 2) + 1
            off = int.from_bytes(b[p:p + 2], "little")
            p += 2
        else:
            n = (tag >> 2) + 1
            off = int.from_bytes(b[p:p + 4], "little")
            p += 4
        start = len(out) - off
        if off <= 0 or start < 0:
            raise ValueError("bad snappy data")
        if off >= n:
            out += out[start:start + n]
        else:
            for i in range(n):
                out.append(out[start + i])
    return bytes(out)


def read_block(data, off, size):
    raw = data[off:off + size]
    return snappy(raw) if data[off + size] == 1 else raw


def block_values(blk):
    nrest = struct.unpack("<I", blk[-4:])[0]
    end = len(blk) - 4 - 4 * nrest
    p = 0
    while p < end:
        _, p = varint(blk, p)
        nonshared, p = varint(blk, p)
        vlen, p = varint(blk, p)
        p += nonshared
        yield blk[p:p + vlen]
        p += vlen


def load_store(folder):
    names = sorted(os.listdir(folder))
    chunks = []
    for n in [x for x in names if x.endswith(".ldb")] + [x for x in names if x.endswith(".log")]:
        try:
            with open(os.path.join(folder, n), "rb") as f:
                data = f.read()
        except OSError as e:
            print("  (could not read %s: %s)" % (n, e))
            continue
        if n.endswith(".log"):
            chunks.append(data)
            continue
        try:
            foot = data[-48:]
            p = 0
            _, p = varint(foot, p)
            _, p = varint(foot, p)
            io, p = varint(foot, p)
            isz, p = varint(foot, p)
            for h in block_values(read_block(data, io, isz)):
                bo, q = varint(h, 0)
                bs, _ = varint(h, q)
                try:
                    chunks.append(read_block(data, bo, bs))
                except Exception:
                    pass
        except Exception:
            chunks.append(data)
    newest = max([os.path.getmtime(os.path.join(folder, x)) for x in names] or [0])
    return b"".join(chunks), newest


# ---------------------------------------------------------------- V8 value reader
class Bad(Exception):
    pass


class Date(object):
    def __init__(self, ms):
        self.ms = ms


def skip_pad(b, p):
    while p < len(b) and b[p] == 0:
        p += 1
    if p >= len(b):
        raise Bad()
    return p


def v8_value(b, p, depth=0):
    if depth > 30:
        raise Bad()
    p = skip_pad(b, p)
    t = b[p]
    p += 1
    if t in (0x22, 0x63, 0x53):  # '"' latin-1, 'c' utf-16, 'S' utf-8 string
        n, p = varint(b, p)
        if p + n > len(b):
            raise Bad()
        enc = {0x22: "latin-1", 0x63: "utf-16-le", 0x53: "utf-8"}[t]
        return b[p:p + n].decode(enc, "replace"), p + n
    if t in (0x44, 0x4E):  # 'D' date, 'N' double
        v = struct.unpack("<d", b[p:p + 8])[0]
        return (Date(v) if t == 0x44 else v), p + 8
    if t == 0x49:  # 'I' zigzag int
        v, p = varint(b, p)
        return (v >> 1) ^ -(v & 1), p
    if t == 0x55:  # 'U' uint
        return varint(b, p)
    if t == 0x54:
        return True, p
    if t == 0x46:
        return False, p
    if t in (0x5F, 0x30, 0x2D):  # undefined, null, hole
        return None, p
    if t == 0x5E:  # back-reference
        _, p = varint(b, p)
        return None, p
    if t == 0x6F:  # 'o' object
        return v8_object(b, p, depth + 1)
    if t in (0x41, 0x61):  # 'A' dense / 'a' sparse array
        n, p = varint(b, p)
        if n > 100000:
            raise Bad()
        arr = []
        if t == 0x41:
            for _ in range(n):
                v, p = v8_value(b, p, depth + 1)
                arr.append(v)
        props = 0
        end_tag = 0x24 if t == 0x41 else 0x40
        while True:
            p = skip_pad(b, p)
            if b[p] == end_tag:
                np_, p = varint(b, p + 1)
                _, p = varint(b, p)
                if np_ != props:
                    raise Bad()
                return arr, p
            _, p = v8_value(b, p, depth + 1)
            v, p = v8_value(b, p, depth + 1)
            if t == 0x61:
                arr.append(v)
            props += 1
    raise Bad()


def v8_object(b, p, depth=0, target=None):
    obj, count, hit = {}, 0, target is None
    while True:
        p = skip_pad(b, p)
        if b[p] == 0x7B:  # '{' end of object
            np_, p = varint(b, p + 1)
            if np_ != count or not hit:
                raise Bad()
            return obj, p
        if p == target:
            hit = True
        k, p = v8_value(b, p, depth + 1)
        if not isinstance(k, (str, int)):
            raise Bad()
        v, p = v8_value(b, p, depth + 1)
        obj[k] = v
        count += 1


PARSE_ERRORS = (Bad, IndexError, ValueError, struct.error, RecursionError)
NEAR_KEYS = [b"location", b"endTime", b"isReminderSet", b"reminderMinutesBeforeStart", b"subject", b"organizerName"]


def partial_event(raw, s):
    # Events with a huge body (e.g. a full HTML invite) start too far back to find the
    # object start, so read the event from the nearest known field up to its end instead.
    starts = []
    for k in NEAR_KEYS:
        i = raw.rfind(b'"' + bytes([len(k)]) + k, max(0, s - 3000), s)
        if i >= 0:
            starts.append(i)
    for st in sorted(starts) + [s]:
        obj, p, hit = {}, st, False
        try:
            while True:
                p = skip_pad(raw, p)
                if raw[p] == 0x7B:
                    break
                if p == s:
                    hit = True
                k, p = v8_value(raw, p)
                v, p = v8_value(raw, p)
                obj[k] = v
        except PARSE_ERRORS:
            continue
        if hit:
            return obj
    return None


def find_events(raw):
    events = []
    for m in re.finditer(re.escape(b'"\x09startTime'), raw):
        s = m.start()
        lo, c, tries, obj = max(0, s - 8000), s, 0, None
        while tries < 600:
            c = raw.rfind(b"o", lo, c)
            if c < 0:
                break
            tries += 1
            try:
                obj, _ = v8_object(raw, c + 1, 0, target=s)
                break
            except PARSE_ERRORS:
                obj = None
        if obj is None:
            obj = partial_event(raw, s)
        if obj and isinstance(obj.get("subject"), str):
            obj["_pos"] = s
            events.append(obj)
    return events


# ---------------------------------------------------------------- helpers
def to_local(v):
    try:
        if isinstance(v, Date):
            return dt.datetime.fromtimestamp(v.ms / 1000.0, tz=dt.timezone.utc).astimezone()
        if isinstance(v, str) and re.match(r"\d{4}-\d\d-\d\dT\d\d:\d\d", v):
            d = dt.datetime.strptime(v[:19], "%Y-%m-%dT%H:%M:%S")
            return d.replace(tzinfo=dt.timezone.utc).astimezone()
    except Exception:
        pass
    return None


# Host must be the real domain or a subdomain of it (so "evilzoom.us" or "zoom.us.evil.com" never match).
MEET_RE = re.compile(
    r"https://(?:[A-Za-z0-9-]+\.)*(?:zoom\.us/(?:j|w|my)/|teams\.microsoft\.com/(?:l/meetup-join|meet)/|"
    r"teams\.live\.com/meet/|meet\.google\.com/|webex\.com/|gotomeet\.me/|meet\.goto\.com/|whereby\.com/)"
    r"[A-Za-z0-9\-._~:/?#\[\]@!$&()*+,;=%]*")

# Cached text comes from invites anyone can send you, so strip terminal control codes and
# bidi/zero-width characters before printing it.
UNSAFE_RE = re.compile(u"[\x00-\x1f\x7f-\x9f\u200b-\u200f\u202a-\u202e\u2066-\u2069]")


def safe(s):
    return re.sub(r"\s+", " ", UNSAFE_RE.sub(" ", str(s))).strip()
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}")


def clean(s):
    for _ in range(2):  # invite HTML is sometimes stored HTML-escaped
        s = html.unescape(s)
        s = re.sub(r"(?is)<style.*?</style>", " ", s)
        s = re.sub(r"<[^<>]{0,2000}>", " ", s)
    s = re.sub(r"^[^<>]*>", " ", s)   # tag cut off at the start of the window
    s = re.sub(r"<[^>]*$", " ", s)    # tag cut off at the end of the window
    s = re.sub(u"[^\x20-\x7e\u00a0-\u024f\u2013\u2014\u2019]+", " ", s)
    return safe(s)


NON_TEXT_RE = re.compile(u"[^\t\n\r\x20-\x7e\u00a0-\u024f\u2000-\u206f\u20ac]")


def text_run(t, i, back=6000, fwd=3000):
    # The stretch of readable text around position i, i.e. the cached string that contains it.
    lo, hi = max(0, i - back), min(len(t), i + fwd)
    m = NON_TEXT_RE.search(t[lo:i][::-1])
    a = i - m.start() if m else lo
    m = NON_TEXT_RE.search(t, i, hi)
    b = m.start() if m else hi
    return t[a:b]


def find_all(text, needle, limit=60):
    out, i = [], text.find(needle)
    while i >= 0 and len(out) < limit:
        out.append(i)
        i = text.find(needle, i + 1)
    return out


def date_phrases(d):
    M, m, W = d.strftime("%B"), d.strftime("%b"), d.strftime("%A")
    day, Y = str(d.day), str(d.year)
    return [m + " " + day + ", " + Y, M + " " + day + ", " + Y, day + " " + m + " " + Y, day + " " + M + " " + Y,
            W + ", " + M + " " + day, W + ", " + day + " " + M, W + " " + m + " " + day,
            d.strftime("%d/%m/%Y"), d.strftime("%m/%d/%Y"), d.strftime("%d.%m.%Y")]


# ---------------------------------------------------------------- main
def main():
    stores = find_stores()
    if not stores:
        print("No Microsoft Teams desktop cache found on this computer.")
        print("(Looked for new and classic Teams on macOS and Windows.)")
        return
    today = dt.date.today()
    days = [today + dt.timedelta(days=i) for i in range(max(DAYS, 1))]
    print("Read-only scan of the Teams desktop cache. Nothing is sent anywhere.")
    for folder in stores:
        try:
            raw, newest = load_store(folder)
        except PermissionError:
            print("\nPermission denied reading the Teams cache.")
            print("macOS: allow Terminal to access data from other apps when asked, or give Terminal")
            print("Full Disk Access (System Settings > Privacy & Security), then reopen Terminal and retry.")
            continue
        print("Cache: %s" % folder)
        print("Cache last updated: %s" % dt.datetime.fromtimestamp(newest).strftime("%a %d %b %Y %H:%M"))

        pools = [raw.decode("latin-1"), raw.decode("utf-16-le", "replace"), raw[1:].decode("utf-16-le", "replace")]
        all_urls = Counter()
        for t in pools:
            all_urls.update(MEET_RE.findall(t))

        def expand(url):
            longer = [u for u in all_urls if u.startswith(url) and len(u) > len(url)]
            return max(longer, key=lambda u: (all_urls[u], -len(u))) if longer else url

        def zoom_passcode(url):
            mid = re.search(r"zoom\.us/j/(\d{9,11})", url)
            if not mid:
                return None, None
            digits = mid.group(1)
            pat = re.compile(r"\s?".join(digits) + r".{0,300}?(?:Passcode|Password)\s*:?\s*([A-Za-z0-9.@#$%^&*!_-]{4,20})",
                             re.S)
            codes = Counter()
            for t in pools:
                codes.update(m.group(1) for m in pat.finditer(t))
            return digits, (codes.most_common(1)[0][0] if codes else None)

        def emails_near(subject):
            key = subject.strip()[:40]
            seen = Counter()
            if len(key) < 6:
                return []
            for t in pools:
                for i in find_all(t, key):
                    seen.update(e.lower() for e in EMAIL_RE.findall(t[max(0, i - 3000):i + 8000]))
            return [e for e, _ in seen.most_common(20)
                    if not re.search(r"no-?reply|notification|calendar-server|microsoft\.com$|\.spaces$|thread\.", e)
                    and not re.match(r"[0-9a-f_-]{20,}@", e)][:8]

        # newest cached version of each event wins
        best = {}
        for ev in find_events(raw):
            key = ev.get("objectId") or (ev.get("subject"), str(ev.get("iCalUID")))
            rank = (str(ev.get("lastModifiedTime") or ""), ev["_pos"])
            if key not in best or rank > best[key][0]:
                best[key] = (rank, ev)
        events = []
        for _, ev in best.values():
            st, en = to_local(ev.get("startTime")), to_local(ev.get("endTime"))
            if st:
                events.append((st, en, ev))
        events.sort(key=lambda x: x[0])
        print("Calendar events in cache: %d" % len(events))

        for day in days:
            print("\n" + "=" * 78)
            print("MEETINGS ON %s  (times in this computer's time zone)" % day.strftime("%A %d %B %Y").upper())
            print("=" * 78)
            todays = [e for e in events if e[0].date() == day]
            if not todays:
                print("No cached calendar events for this day. Teams only caches meetings it has")
                print("loaded recently, so check the 'invites mentioning this date' section below.")
            for st, en, ev in todays:
                subj = safe(ev.get("subject") or "") or "(no subject)"
                body = ev.get("bodyPreview") if isinstance(ev.get("bodyPreview"), str) else ""
                loc = ev.get("location") if isinstance(ev.get("location"), str) else ""
                print("\n%s-%s  %s" % (st.strftime("%H:%M"), en.strftime("%H:%M") if en else "?", subj))
                if ev.get("isCancelled") is True or re.match(r"(?i)cancel", subj):
                    print("   ** looks CANCELLED **")
                print("   Organizer : %s" % safe(ev.get("organizerName") or "?"))
                if ev.get("myResponseType"):
                    print("   Your reply: %s" % safe(ev.get("myResponseType")))
                if loc:
                    print("   Location  : %s" % safe(loc))
                links = []
                for k in ("skypeTeamsMeetingUrl", "shortOnlineMeetingJoinUrl", "onlineMeetingUrl", "joinUrl"):
                    if isinstance(ev.get(k), str) and ev[k].startswith("http"):
                        links.append(ev[k])
                # links typed into the description are often cut short; use the full copy if cached
                links += [expand(u) for u in MEET_RE.findall(loc) + MEET_RE.findall(body)]
                shown = []
                for u in links:
                    if u not in shown:
                        shown.append(u)
                        print("   Join link : %s" % u)
                        zid, code = zoom_passcode(u)
                        if zid:
                            groups = {9: (3, 3, 3), 10: (3, 3, 4), 11: (3, 4, 4)}.get(len(zid), (len(zid),))
                            parts, k = [], 0
                            for g in groups:
                                parts.append(zid[k:k + g])
                                k += g
                            print("   Zoom ID   : %s   Passcode: %s" % (" ".join(parts), code or "(not found in cache)"))
                if not shown:
                    print("   Join link : (none in cache - see invite text below)")
                if body:
                    print("   Preview   : %s" % clean(body)[:220])
                em = emails_near(subj)
                if em:
                    print("   Emails seen near this invite: %s" % ", ".join(em))
                if ev.get("lastModifiedTime"):
                    print("   (cached version last changed %s UTC)" % safe(str(ev["lastModifiedTime"])[:16].replace("T", " ")))

            # raw invite emails / chat meeting cards that mention the date
            print("\n--- Invites / messages in the cache that mention %s ---" % day.strftime("%d %b"))
            shown_snips, count = [], 0
            for phrase in date_phrases(day):
                for t in pools:
                    for i in find_all(t, phrase, 40):
                        if re.match(r"\s\d\d:\d\d:\d\d GMT", t[i + len(phrase):i + len(phrase) + 14]):
                            continue  # web request header, not a meeting
                        seg = text_run(t, i)
                        c = clean(seg)
                        j = c.find(phrase)
                        if j < 0:
                            continue
                        snip = c[max(0, j - 700):j + 450]
                        words = set(re.findall(r"\w+", snip.lower()))
                        if any(len(words & w) > 0.7 * len(words | w) for w in shown_snips):
                            continue  # same invite already shown
                        shown_snips.append(words)
                        count += 1
                        print("\n[%d] ...%s..." % (count, snip))
                        for u in sorted(set(expand(u) for u in MEET_RE.findall(seg))):
                            print("    link: %s" % u)
                        if count >= 6:
                            break
                    if count >= 6:
                        break
                if count >= 6:
                    break
            if not count:
                print("(none found)")
    print("\nTip: run with a number to see more days, e.g. 'python3 teams_meetings.py 3'.")
    print("Double-check times: cached data may be out of date if a meeting was moved after Teams last synced.")


if __name__ == "__main__":
    main()
