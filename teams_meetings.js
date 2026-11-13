// teams_meetings.js - list today's meetings and join links from the Microsoft Teams desktop
// app's local cache, using only the JavaScript built into macOS (no Python needed).
// Read-only and offline: it only reads Teams' cache files on this computer and sends nothing.
// Usage:  osascript -l JavaScript teams_meetings.js [DAYS]    (DAYS = days to show from today, default 1)
ObjC.import('Foundation');

var TIP = "Tip: to see more days, end the command with  | osascript -l JavaScript - 3";
var OUT = $.NSFileHandle.fileHandleWithStandardOutput;
function out(s) {
  OUT.writeData($((s === undefined ? '' : String(s)) + '\n').dataUsingEncoding($.NSUTF8StringEncoding));
}

// ---------------------------------------------------------------- files
var FM = $.NSFileManager.defaultManager;
var PERM_DENIED = false;

function listDir(p) {
  // (Asking osascript for the NSError object crashes it on recent macOS, so infer permission problems:
  // the folder exists but cannot be listed.)
  var u = ObjC.deepUnwrap(FM.contentsOfDirectoryAtPathError($(p), null));
  if (Array.isArray(u)) return u;
  if (FM.fileExistsAtPath($(p))) PERM_DENIED = true;
  return null;
}

function mtime(p) {
  try {
    return FM.attributesOfItemAtPathError($(p), null).objectForKey($('NSFileModificationDate')).timeIntervalSince1970;
  } catch (e) {
    return 0;
  }
}

var B64 = new Uint8Array(256);
(function () {
  var a = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  for (var i = 0; i < 64; i++) B64[a.charCodeAt(i)] = i;
})();

function readBytes(p) {
  var d = $.NSData.dataWithContentsOfFile($(p));
  if (!d || d.isNil()) throw new Error('could not read ' + p);
  var s = d.base64EncodedStringWithOptions(0).js;
  var pad = s.charAt(s.length - 1) === '=' ? (s.charAt(s.length - 2) === '=' ? 2 : 1) : 0;
  var n = (s.length / 4) * 3 - pad, outb = new Uint8Array(n), o = 0;
  for (var i = 0; i < s.length; i += 4) {
    var v = (B64[s.charCodeAt(i)] << 18) | (B64[s.charCodeAt(i + 1)] << 12) |
            (B64[s.charCodeAt(i + 2)] << 6) | B64[s.charCodeAt(i + 3)];
    if (o < n) outb[o++] = (v >> 16) & 255;
    if (o < n) outb[o++] = (v >> 8) & 255;
    if (o < n) outb[o++] = v & 255;
  }
  return outb;
}

function env(name) {
  var v = ObjC.unwrap($.NSProcessInfo.processInfo.environment.objectForKey($(name)));
  return typeof v === 'string' ? v : '';
}

var STORE_RE = /^https_teams\..*\.indexeddb\.leveldb$/;

function findStores() {
  var override = env('TEAMS_CACHE_DIR');  // for testing: read this LevelDB folder instead
  if (override) return listDir(override) !== null ? [override] : [];
  var home = $.NSHomeDirectory().js, found = [];
  var ebw = home + '/Library/Containers/com.microsoft.teams2/Data/Library/Application Support/Microsoft/MSTeams/EBWebView';
  (listDir(ebw) || []).filter(function (n) { return n.indexOf('WV2Profile_') === 0; }).forEach(function (prof) {
    var idb = ebw + '/' + prof + '/IndexedDB';
    (listDir(idb) || []).filter(function (n) { return STORE_RE.test(n); }).forEach(function (n) {
      if (listDir(idb + '/' + n) !== null) found.push(idb + '/' + n);
    });
  });
  var classic = home + '/Library/Application Support/Microsoft/Teams/IndexedDB';
  (listDir(classic) || []).filter(function (n) { return STORE_RE.test(n); }).forEach(function (n) {
    if (listDir(classic + '/' + n) !== null) found.push(classic + '/' + n);
  });
  return found;
}

// ---------------------------------------------------------------- LevelDB + Snappy
var BAD = { bad: true };
var VP = 0;  // position after the last varint / value read

function rv(b, p) {
  var r = 0, m = 1, c;
  do {
    if (p >= b.length) throw BAD;
    c = b[p++];
    r += (c & 0x7F) * m;
    m *= 128;
  } while (c & 0x80);
  VP = p;
  return r;
}

function le(b, p, k) {
  var r = 0, m = 1;
  for (var i = 0; i < k; i++) { r += b[p + i] * m; m *= 256; }
  return r;
}

function snappy(b) {
  var n = rv(b, 0), p = VP, outb = new Uint8Array(n), o = 0;
  while (p < b.length) {
    var tag = b[p++], kind = tag & 3, len, off;
    if (kind === 0) {
      len = tag >> 2;
      if (len >= 60) {
        var k = len - 59;
        len = le(b, p, k);
        p += k;
      }
      len += 1;
      outb.set(b.subarray(p, p + len), o);
      o += len;
      p += len;
      continue;
    }
    if (kind === 1) {
      len = ((tag >> 2) & 7) + 4;
      off = ((tag >> 5) << 8) | b[p++];
    } else if (kind === 2) {
      len = (tag >> 2) + 1;
      off = le(b, p, 2);
      p += 2;
    } else {
      len = (tag >> 2) + 1;
      off = le(b, p, 4);
      p += 4;
    }
    var start = o - off;
    if (off <= 0 || start < 0 || o + len > n) throw new Error('bad snappy data');
    if (off >= len) {
      outb.copyWithin(o, start, start + len);
    } else {
      for (var i = 0; i < len; i++) outb[o + i] = outb[start + i];
    }
    o += len;
  }
  return outb.subarray(0, o);
}

function readBlock(data, off, size) {
  var raw = data.subarray(off, off + size);
  return data[off + size] === 1 ? snappy(raw) : raw;
}

function blockValues(blk) {
  var nrest = le(blk, blk.length - 4, 4), end = blk.length - 4 - 4 * nrest, p = 0, vals = [];
  while (p < end) {
    rv(blk, p);
    var nonshared = rv(blk, VP);
    var vlen = rv(blk, VP);
    p = VP + nonshared;
    vals.push(blk.subarray(p, p + vlen));
    p += vlen;
  }
  return vals;
}

function loadStore(folder) {
  var names = listDir(folder);
  if (names === null) return null;
  names.sort();
  var chunks = [], newest = 0;
  names.forEach(function (n) { newest = Math.max(newest, mtime(folder + '/' + n)); });
  var files = names.filter(function (n) { return /\.ldb$/.test(n); })
    .concat(names.filter(function (n) { return /\.log$/.test(n); }));
  files.forEach(function (n) {
    var data;
    try {
      data = readBytes(folder + '/' + n);
    } catch (e) {
      out('  (could not read ' + n + ')');
      return;
    }
    if (/\.log$/.test(n)) { chunks.push(data); return; }
    try {
      var foot = data.subarray(data.length - 48);
      rv(foot, 0); rv(foot, VP);
      var io = rv(foot, VP), isz = rv(foot, VP);
      blockValues(readBlock(data, io, isz)).forEach(function (h) {
        var bo = rv(h, 0), bs = rv(h, VP);
        try { chunks.push(readBlock(data, bo, bs)); } catch (e) {}
      });
    } catch (e) {
      chunks.push(data);
    }
  });
  var total = 0;
  chunks.forEach(function (c) { total += c.length; });
  var raw = new Uint8Array(total), o = 0;
  chunks.forEach(function (c) { raw.set(c, o); o += c.length; });
  return { raw: raw, newest: newest };
}

// ---------------------------------------------------------------- V8 value reader
function DateV(ms) { this.ms = ms; }
var DV = null;  // DataView over the raw bytes (set in main)

function latin1(b, a, z) {
  var parts = [];
  for (var i = a; i < z; i += 16384) parts.push(String.fromCharCode.apply(null, b.subarray(i, Math.min(z, i + 16384))));
  return parts.join('');
}

function utf16(b, a, z) {
  var parts = [], codes = [];
  for (var i = a; i + 1 < z; i += 2) {
    codes.push(b[i] | (b[i + 1] << 8));
    if (codes.length === 16384) { parts.push(String.fromCharCode.apply(null, codes)); codes = []; }
  }
  if (codes.length) parts.push(String.fromCharCode.apply(null, codes));
  return parts.join('');
}

function utf8(b, a, z) {
  var s = latin1(b, a, z);
  try { return decodeURIComponent(escape(s)); } catch (e) { return s; }
}

function skipPad(b, p) {
  while (p < b.length && b[p] === 0) p++;
  if (p >= b.length) throw BAD;
  return p;
}

function v8Value(b, p, depth) {
  if (depth > 30) throw BAD;
  p = skipPad(b, p);
  var t = b[p++], n, i;
  if (t === 0x22 || t === 0x63 || t === 0x53) {  // latin-1, utf-16, utf-8 string
    n = rv(b, p);
    p = VP;
    if (p + n > b.length) throw BAD;
    VP = p + n;
    return t === 0x22 ? latin1(b, p, p + n) : (t === 0x63 ? utf16(b, p, p + n) : utf8(b, p, p + n));
  }
  if (t === 0x44 || t === 0x4E) {  // date, double
    if (p + 8 > b.length) throw BAD;
    var d = DV.getFloat64(p, true);
    VP = p + 8;
    return t === 0x44 ? new DateV(d) : d;
  }
  if (t === 0x49) { n = rv(b, p); return (n % 2) ? -(n + 1) / 2 : n / 2; }  // zigzag int
  if (t === 0x55) return rv(b, p);
  if (t === 0x54) { VP = p; return true; }
  if (t === 0x46) { VP = p; return false; }
  if (t === 0x5F || t === 0x30 || t === 0x2D) { VP = p; return null; }  // undefined, null, hole
  if (t === 0x5E) { rv(b, p); return null; }  // back-reference
  if (t === 0x6F) return v8Object(b, p, depth + 1, -1);
  if (t === 0x41 || t === 0x61) {  // dense / sparse array
    n = rv(b, p);
    p = VP;
    if (n > 100000) throw BAD;
    var arr = [];
    if (t === 0x41) {
      for (i = 0; i < n; i++) { arr.push(v8Value(b, p, depth + 1)); p = VP; }
    }
    var props = 0, endTag = t === 0x41 ? 0x24 : 0x40;
    while (true) {
      p = skipPad(b, p);
      if (b[p] === endTag) {
        var np = rv(b, p + 1);
        rv(b, VP);
        if (np !== props) throw BAD;
        return arr;
      }
      v8Value(b, p, depth + 1);
      p = VP;
      var v = v8Value(b, p, depth + 1);
      p = VP;
      if (t === 0x61) arr.push(v);
      props++;
    }
  }
  throw BAD;
}

function v8Object(b, p, depth, target) {
  var obj = Object.create(null), count = 0, hit = target < 0;
  while (true) {
    p = skipPad(b, p);
    if (b[p] === 0x7B) {  // end of object
      var np = rv(b, p + 1);
      if (np !== count || !hit) throw BAD;
      return obj;
    }
    if (p === target) hit = true;
    var k = v8Value(b, p, depth + 1);
    p = VP;
    if (typeof k !== 'string' && !(typeof k === 'number' && Math.floor(k) === k)) throw BAD;
    var v = v8Value(b, p, depth + 1);
    p = VP;
    obj[k] = v;
    count++;
  }
}

var NEAR_KEYS = ['location', 'endTime', 'isReminderSet', 'reminderMinutesBeforeStart', 'subject', 'organizerName'];

function partialEvent(raw, latin, s) {
  // Events with a huge body (e.g. a full HTML invite) start too far back to find the
  // object start, so read the event from the nearest known field up to its end instead.
  var starts = [], lo = Math.max(0, s - 3000);
  NEAR_KEYS.forEach(function (k) {
    var tok = '"' + String.fromCharCode(k.length) + k, i = latin.lastIndexOf(tok, s - tok.length);
    if (i >= lo) starts.push(i);
  });
  starts.sort(function (a, b) { return a - b; });
  starts.push(s);
  for (var j = 0; j < starts.length; j++) {
    var obj = Object.create(null), p = starts[j], hit = false;
    try {
      while (true) {
        p = skipPad(raw, p);
        if (raw[p] === 0x7B) break;
        if (p === s) hit = true;
        var k = v8Value(raw, p, 0);
        p = VP;
        var v = v8Value(raw, p, 0);
        p = VP;
        obj[k] = v;
      }
    } catch (e) {
      continue;
    }
    if (hit) return obj;
  }
  return null;
}

function findEvents(raw, latin) {
  var events = [], key = '"\x09startTime', s = latin.indexOf(key);
  while (s >= 0) {
    var lo = Math.max(0, s - 8000), c = s, tries = 0, obj = null;
    while (tries < 600) {
      c--;
      while (c >= lo && raw[c] !== 0x6F) c--;
      if (c < lo) break;
      tries++;
      try {
        obj = v8Object(raw, c + 1, 0, s);
        break;
      } catch (e) {
        obj = null;
      }
    }
    if (obj === null) obj = partialEvent(raw, latin, s);
    if (obj && typeof obj.subject === 'string') {
      obj._pos = s;
      events.push(obj);
    }
    s = latin.indexOf(key, s + 1);
  }
  return events;
}

// ---------------------------------------------------------------- helpers
var WD = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
var MO = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October',
  'November', 'December'];
function p2(n) { return (n < 10 ? '0' : '') + n; }
function hm(d) { return p2(d.getHours()) + ':' + p2(d.getMinutes()); }
function sameDay(a, b) {
  return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
}

function toLocal(v) {
  if (v instanceof DateV) return isFinite(v.ms) ? new Date(v.ms) : null;
  if (typeof v === 'string') {
    var m = /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d)(?::(\d\d))?/.exec(v);
    if (m) return new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +(m[6] || 0)));
  }
  return null;
}

// Host must be the real domain or a subdomain of it (so "evilzoom.us" or "zoom.us.evil.com" never match).
var MEET_SRC = "https://(?:[A-Za-z0-9-]+\\.)*(?:zoom\\.us/(?:j|w|my)/|teams\\.microsoft\\.com/(?:l/meetup-join|meet)/|" +
  "teams\\.live\\.com/meet/|meet\\.google\\.com/|webex\\.com/|gotomeet\\.me/|meet\\.goto\\.com/|whereby\\.com/)" +
  "[A-Za-z0-9\\-._~:/?#\\[\\]@!$&()*+,;=%]*";
function meetLinks(s) { return s.match(new RegExp(MEET_SRC, 'g')) || []; }
var MEET_FULL_RE = new RegExp('^(?:' + MEET_SRC + ')$');
var EMAIL_RE = /[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}/g;

// Cached text comes from invites anyone can send you, so strip terminal control codes and
// bidi/zero-width characters before printing it.
var UNSAFE_RE = /[\x00-\x1f\x7f-\x9f\u200b-\u200f\u202a-\u202e\u2066-\u2069]/g;
function safe(s) { return String(s).replace(UNSAFE_RE, ' ').replace(/\s+/g, ' ').trim(); }

var ENT = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: '\u00a0', ndash: '\u2013', mdash: '\u2014',
  rsquo: '\u2019', lsquo: '\u2018', ldquo: '\u201c', rdquo: '\u201d', hellip: '\u2026', bull: '\u2022',
  copy: '\u00a9', reg: '\u00ae', euro: '\u20ac', middot: '\u00b7' };
function unescapeHtml(s) {
  return s.replace(/&(#[xX][0-9a-fA-F]{1,6}|#\d{1,7}|[A-Za-z]{2,8});/g, function (m, e) {
    if (e.charAt(0) === '#') {
      var c = (e.charAt(1) === 'x' || e.charAt(1) === 'X') ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
      try { return String.fromCodePoint(c); } catch (x) { return ' '; }
    }
    return Object.prototype.hasOwnProperty.call(ENT, e) ? ENT[e] : m;
  });
}

function clean(s) {
  for (var i = 0; i < 2; i++) {  // invite HTML is sometimes stored HTML-escaped
    s = unescapeHtml(s);
    s = s.replace(/<style[\s\S]*?<\/style>/gi, ' ');
    s = s.replace(/<[^<>]{0,2000}>/g, ' ');
  }
  s = s.replace(/^[^<>]*>/, ' ');  // tag cut off at the start of the window
  s = s.replace(/<[^>]*$/, ' ');   // tag cut off at the end of the window
  s = s.replace(/[^\x20-\x7e\u00a0-\u024f\u2013\u2014\u2019]+/g, ' ');
  return safe(s);
}

function isText(c) {
  return c === 9 || c === 10 || c === 13 || (c >= 0x20 && c <= 0x7e) || (c >= 0xa0 && c <= 0x24f) ||
    (c >= 0x2000 && c <= 0x206f) || c === 0x20ac;
}

function textRun(t, i) {
  // The stretch of readable text around position i, i.e. the cached string that contains it.
  var lo = Math.max(0, i - 6000), hi = Math.min(t.length, i + 3000), a = i, b = i;
  while (a > lo && isText(t.charCodeAt(a - 1))) a--;
  while (b < hi && isText(t.charCodeAt(b))) b++;
  return t.substring(a, b);
}

function findAll(text, needle, limit) {
  var res = [], i = text.indexOf(needle);
  while (i >= 0 && res.length < limit) { res.push(i); i = text.indexOf(needle, i + 1); }
  return res;
}

function datePhrases(d) {
  var M = MO[d.getMonth()], m = M.slice(0, 3), W = WD[d.getDay()], day = String(d.getDate()), Y = String(d.getFullYear());
  var dd = p2(d.getDate()), mm = p2(d.getMonth() + 1);
  return [m + ' ' + day + ', ' + Y, M + ' ' + day + ', ' + Y, day + ' ' + m + ' ' + Y, day + ' ' + M + ' ' + Y,
    W + ', ' + M + ' ' + day, W + ', ' + day + ' ' + M, W + ' ' + m + ' ' + day,
    dd + '/' + mm + '/' + Y, mm + '/' + dd + '/' + Y, dd + '.' + mm + '.' + Y];
}

function counter() { return new Map(); }
function bump(c, k) { c.set(k, (c.get(k) || 0) + 1); }
function mostCommon(c) {  // [key, count] sorted by count, ties in first-seen order
  return Array.from(c.entries()).sort(function (a, b) { return b[1] - a[1]; });
}

// ---------------------------------------------------------------- main
function main(argv) {
  var DAYS = (argv.length > 0 && /^\d+$/.test(argv[0])) ? parseInt(argv[0], 10) : 1;
  var stores = findStores();
  if (!stores.length) {
    if (PERM_DENIED) {
      out('Permission denied reading the Teams cache.');
      out('macOS: allow Terminal to access data from other apps when asked, or give Terminal');
      out('Full Disk Access (System Settings > Privacy & Security), then reopen Terminal and retry.');
    } else {
      out('No Microsoft Teams desktop cache found on this computer.');
      out('(Looked for new and classic Teams on macOS.)');
    }
    return;
  }
  var now = new Date(), days = [];
  for (var di = 0; di < Math.max(DAYS, 1); di++) days.push(new Date(now.getFullYear(), now.getMonth(), now.getDate() + di));
  out('Read-only scan of the Teams desktop cache. Nothing is sent anywhere.');
  stores.forEach(function (folder) {
    var st = loadStore(folder);
    if (st === null) {
      out('\nPermission denied reading the Teams cache.');
      out('macOS: allow Terminal to access data from other apps when asked, or give Terminal');
      out('Full Disk Access (System Settings > Privacy & Security), then reopen Terminal and retry.');
      return;
    }
    var raw = st.raw;
    DV = new DataView(raw.buffer, raw.byteOffset, raw.byteLength);
    var nd = new Date(st.newest * 1000);
    out('Cache: ' + folder);
    out('Cache last updated: ' + WD[nd.getDay()].slice(0, 3) + ' ' + p2(nd.getDate()) + ' ' + MO[nd.getMonth()].slice(0, 3) +
      ' ' + nd.getFullYear() + ' ' + hm(nd));

    var latin = latin1(raw, 0, raw.length);
    var odd = raw.slice(1);
    var pools = [latin, utf16(raw, 0, raw.length), utf16(odd, 0, odd.length)];
    var allUrls = counter();
    pools.forEach(function (t) { meetLinks(t).forEach(function (u) { bump(allUrls, u); }); });

    function expand(url) {
      var best = null;
      allUrls.forEach(function (n, u) {
        if (u.length > url.length && u.indexOf(url) === 0) {
          if (best === null || n > allUrls.get(best) || (n === allUrls.get(best) && u.length < best.length)) best = u;
        }
      });
      return best === null ? url : best;
    }

    function zoomPasscode(url) {
      var mid = /zoom\.us\/j\/(\d{9,11})/.exec(url);
      if (!mid) return null;
      var digits = mid[1];
      var re = new RegExp(digits.split('').join('\\s?') +
        '[\\s\\S]{0,300}?(?:Passcode|Password)\\s*:?\\s*([A-Za-z0-9.@#$%^&*!_-]{4,20})', 'g');
      var codes = counter();
      pools.forEach(function (t) {
        var m;
        re.lastIndex = 0;
        while ((m = re.exec(t)) !== null) bump(codes, m[1]);
      });
      var mc = mostCommon(codes);
      return { digits: digits, code: mc.length ? mc[0][0] : null };
    }

    function emailsNear(subject) {
      var key = subject.trim().slice(0, 40), seen = counter();
      if (key.length < 6) return [];
      pools.forEach(function (t) {
        findAll(t, key, 60).forEach(function (i) {
          (t.substring(Math.max(0, i - 3000), i + 8000).match(EMAIL_RE) || []).forEach(function (e) {
            bump(seen, e.toLowerCase());
          });
        });
      });
      return mostCommon(seen).slice(0, 20).map(function (x) { return x[0]; }).filter(function (e) {
        return !/no-?reply|notification|calendar-server|microsoft\.com$|\.spaces$|thread\./.test(e) &&
          !/^[0-9a-f_-]{20,}@/.test(e);
      }).slice(0, 8);
    }

    // newest cached version of each event wins
    var best = new Map();
    findEvents(raw, latin).forEach(function (ev) {
      var key = (typeof ev.objectId === 'string' && ev.objectId) ? ev.objectId : ev.subject + '|' + String(ev.iCalUID);
      var mod = ev.lastModifiedTime ? String(ev.lastModifiedTime) : '';
      var cur = best.get(key);
      if (!cur || mod > cur.mod || (mod === cur.mod && ev._pos > cur.ev._pos)) best.set(key, { mod: mod, ev: ev });
    });
    var events = [];
    best.forEach(function (x) {
      var s = toLocal(x.ev.startTime), e = toLocal(x.ev.endTime);
      if (s) events.push({ st: s, en: e, ev: x.ev });
    });
    events.sort(function (a, b) { return a.st - b.st; });
    out('Calendar events in cache: ' + events.length);

    days.forEach(function (day) {
      out('\n' + new Array(79).join('='));
      out('MEETINGS ON ' + (WD[day.getDay()] + ' ' + p2(day.getDate()) + ' ' + MO[day.getMonth()] + ' ' +
        day.getFullYear()).toUpperCase() + "  (times in this computer's time zone)");
      out(new Array(79).join('='));
      var todays = events.filter(function (e) { return sameDay(e.st, day); });
      if (!todays.length) {
        out('No cached calendar events for this day. Teams only caches meetings it has');
        out("loaded recently, so check the 'invites mentioning this date' section below.");
      }
      todays.forEach(function (x) {
        var ev = x.ev;
        var subj = safe(ev.subject || '') || '(no subject)';
        var body = typeof ev.bodyPreview === 'string' ? ev.bodyPreview : '';
        var loc = typeof ev.location === 'string' ? ev.location : '';
        out('\n' + hm(x.st) + '-' + (x.en ? hm(x.en) : '?') + '  ' + subj);
        if (ev.isCancelled === true || /^cancel/i.test(subj)) out('   ** looks CANCELLED **');
        out('   Organizer : ' + safe(ev.organizerName || '?'));
        if (ev.myResponseType) out('   Your reply: ' + safe(ev.myResponseType));
        if (loc) out('   Location  : ' + safe(loc));
        var links = [];
        ['skypeTeamsMeetingUrl', 'shortOnlineMeetingJoinUrl', 'onlineMeetingUrl', 'joinUrl'].forEach(function (k) {
          // only trust a stored link if all of it is a link on a real meeting domain
          if (typeof ev[k] === 'string' && MEET_FULL_RE.test(ev[k])) links.push(ev[k]);
        });
        // links typed into the description are often cut short; use the full copy if cached
        meetLinks(loc).concat(meetLinks(body)).forEach(function (u) { links.push(expand(u)); });
        var shown = [];
        links.forEach(function (u) {
          if (shown.indexOf(u) >= 0) return;
          shown.push(u);
          out('   Join link : ' + u);
          var z = zoomPasscode(u);
          if (z) {
            var groups = { 9: [3, 3, 3], 10: [3, 3, 4], 11: [3, 4, 4] }[z.digits.length] || [z.digits.length];
            var parts = [], k = 0;
            groups.forEach(function (g) { parts.push(z.digits.substr(k, g)); k += g; });
            out('   Zoom ID   : ' + parts.join(' ') + '   Passcode: ' + (z.code || '(not found in cache)'));
          }
        });
        if (!shown.length) out('   Join link : (none in cache - see invite text below)');
        if (body) out('   Preview   : ' + clean(body).slice(0, 220));
        var em = emailsNear(subj);
        if (em.length) out('   Emails seen near this invite: ' + em.join(', '));
        if (ev.lastModifiedTime) {
          out('   (cached version last changed ' + safe(String(ev.lastModifiedTime).slice(0, 16).split('T').join(' ')) + ' UTC)');
        }
      });

      // raw invite emails / chat meeting cards that mention the date
      out('\n--- Invites / messages in the cache that mention ' + p2(day.getDate()) + ' ' + MO[day.getMonth()].slice(0, 3) + ' ---');
      var shownSnips = [], count = 0, phrases = datePhrases(day);
      outer:
      for (var pi = 0; pi < phrases.length; pi++) {
        var phrase = phrases[pi];
        for (var ti = 0; ti < pools.length; ti++) {
          var t = pools[ti], hits = findAll(t, phrase, 40);
          for (var hi = 0; hi < hits.length; hi++) {
            var i = hits[hi];
            if (/^\s\d\d:\d\d:\d\d GMT/.test(t.substr(i + phrase.length, 14))) continue;  // web request header
            var seg = textRun(t, i), c = clean(seg), j = c.indexOf(phrase);
            if (j < 0) continue;
            var snip = c.substring(Math.max(0, j - 700), j + 450);
            var words = new Set(snip.toLowerCase().match(/\w+/g) || []);
            var dup = shownSnips.some(function (w) {
              var inter = 0;
              words.forEach(function (x) { if (w.has(x)) inter++; });
              return inter > 0.7 * (words.size + w.size - inter);
            });
            if (dup) continue;  // same invite already shown
            shownSnips.push(words);
            count++;
            out('\n[' + count + '] ...' + snip + '...');
            var ls = [];
            meetLinks(seg).forEach(function (u) { var e = expand(u); if (ls.indexOf(e) < 0) ls.push(e); });
            ls.sort().forEach(function (u) { out('    link: ' + u); });
            if (count >= 6) break outer;
          }
        }
      }
      if (!count) out('(none found)');
    });
  });
  out('\n' + TIP);
  out('Double-check times: cached data may be out of date if a meeting was moved after Teams last synced.');
}

function run(argv) {
  main(argv || []);
}
