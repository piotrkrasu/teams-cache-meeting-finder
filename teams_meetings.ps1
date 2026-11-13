# teams_meetings.ps1 - list today's meetings and join links from the Microsoft Teams desktop
# app's local cache, using only what comes with Windows (PowerShell and its built-in C# compiler).
# Read-only and offline: it only reads Teams' cache files on this computer and sends nothing.
# Usage:  irm https://raw.githubusercontent.com/piotrkrasu/teams-cache-meeting-finder/main/teams_meetings.ps1 | iex
#   More days:  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/piotrkrasu/teams-cache-meeting-finder/main/teams_meetings.ps1))) 3

$TeamsCacheMeetingFinderSource = @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

public static class TeamsCacheMeetingFinder
{
    const string Tip = "Tip: to see more days, run:  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/piotrkrasu/teams-cache-meeting-finder/main/teams_meetings.ps1))) 3";
    static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
    static readonly DateTime Epoch = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);
    static StringBuilder Buf;
    static bool PermDenied;
    static string[] Pools;
    static Counter AllUrls;

    static void P(string s) { Buf.Append(s).Append(Environment.NewLine); }

    class BadData : Exception { }
    static readonly BadData BAD = new BadData();

    class DateV
    {
        public double Ms;
        public DateV(double ms) { Ms = ms; }
    }

    class Counter
    {
        public Dictionary<string, int> Counts = new Dictionary<string, int>(StringComparer.Ordinal);
        public List<string> Order = new List<string>();
        public void Add(string k)
        {
            int n;
            if (Counts.TryGetValue(k, out n)) Counts[k] = n + 1;
            else { Counts[k] = 1; Order.Add(k); }
        }
        public List<string> MostCommon()
        {
            List<string> keys = new List<string>(Order);
            Dictionary<string, int> idx = new Dictionary<string, int>(StringComparer.Ordinal);
            for (int i = 0; i < keys.Count; i++) idx[keys[i]] = i;
            keys.Sort(delegate(string a, string b)
            {
                int c = Counts[b].CompareTo(Counts[a]);
                return c != 0 ? c : idx[a].CompareTo(idx[b]);
            });
            return keys;
        }
    }

    class Ev
    {
        public DateTime St;
        public DateTime? En;
        public Dictionary<string, object> Obj;
        public int Idx;
    }

    // ------------------------------------------------------------ locate the cache
    static string[] SafeDirs(string dir, string pattern)
    {
        try
        {
            if (Directory.Exists(dir)) return Directory.GetDirectories(dir, pattern);
        }
        catch (UnauthorizedAccessException) { PermDenied = true; }
        catch (IOException) { }
        return new string[0];
    }

    static void AddStores(string idb, List<string> found)
    {
        foreach (string d in SafeDirs(idb, "https_teams.*.indexeddb.leveldb")) found.Add(d);
    }

    static List<string> FindStores()
    {
        List<string> found = new List<string>();
        string ov = Environment.GetEnvironmentVariable("TEAMS_CACHE_DIR");  // for testing: read this folder instead
        if (!string.IsNullOrEmpty(ov))
        {
            if (Directory.Exists(ov)) found.Add(ov);
            return found;
        }
        string local = Environment.GetEnvironmentVariable("LOCALAPPDATA");
        string roaming = Environment.GetEnvironmentVariable("APPDATA");
        string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        List<string> ebws = new List<string>();
        if (!string.IsNullOrEmpty(local))
            ebws.Add(Path.Combine(local, "Packages\\MSTeams_8wekyb3d8bbwe\\LocalCache\\Microsoft\\MSTeams\\EBWebView"));
        if (!string.IsNullOrEmpty(home))
            ebws.Add(Path.Combine(home, "Library/Containers/com.microsoft.teams2/Data/Library/Application Support/Microsoft/MSTeams/EBWebView"));
        foreach (string ebw in ebws)
            foreach (string prof in SafeDirs(ebw, "WV2Profile_*"))
                AddStores(Path.Combine(prof, "IndexedDB"), found);
        if (!string.IsNullOrEmpty(roaming)) AddStores(Path.Combine(roaming, "Microsoft\\Teams\\IndexedDB"), found);
        if (!string.IsNullOrEmpty(home)) AddStores(Path.Combine(home, "Library/Application Support/Microsoft/Teams/IndexedDB"), found);
        return found;
    }

    // ------------------------------------------------------------ LevelDB + Snappy
    static long Rv(byte[] b, ref int p)
    {
        long r = 0;
        int s = 0;
        while (true)
        {
            if (p >= b.Length || s > 63) throw BAD;
            int c = b[p++];
            r |= (long)(c & 0x7F) << s;
            if (c < 0x80) return r;
            s += 7;
        }
    }

    static int Le(byte[] b, int p, int k)
    {
        int r = 0;
        for (int i = 0; i < k; i++) r |= b[p + i] << (8 * i);
        return r;
    }

    static byte[] Snappy(byte[] b, int off, int size)
    {
        int p = off, end = off + size;
        long n = Rv(b, ref p);
        if (n < 0 || n > 1L << 30) throw BAD;
        byte[] o = new byte[n];
        int op = 0;
        while (p < end)
        {
            int tag = b[p++], kind = tag & 3, len, dist;
            if (kind == 0)
            {
                len = tag >> 2;
                if (len >= 60)
                {
                    int k = len - 59;
                    len = Le(b, p, k);
                    p += k;
                }
                len += 1;
                Buffer.BlockCopy(b, p, o, op, len);
                op += len;
                p += len;
                continue;
            }
            if (kind == 1)
            {
                len = ((tag >> 2) & 7) + 4;
                dist = ((tag >> 5) << 8) | b[p++];
            }
            else if (kind == 2)
            {
                len = (tag >> 2) + 1;
                dist = Le(b, p, 2);
                p += 2;
            }
            else
            {
                len = (tag >> 2) + 1;
                dist = Le(b, p, 4);
                p += 4;
            }
            int start = op - dist;
            if (dist <= 0 || start < 0 || op + len > n) throw BAD;
            if (dist >= len) Buffer.BlockCopy(o, start, o, op, len);
            else for (int i = 0; i < len; i++) o[op + i] = o[start + i];
            op += len;
        }
        if (op != n) Array.Resize(ref o, op);
        return o;
    }

    static byte[] ReadBlock(byte[] data, long off, long size)
    {
        if (off < 0 || size < 0 || off + size >= data.Length) throw BAD;
        if (data[off + size] == 1) return Snappy(data, (int)off, (int)size);
        byte[] r = new byte[size];
        Buffer.BlockCopy(data, (int)off, r, 0, (int)size);
        return r;
    }

    static List<byte[]> BlockValues(byte[] blk)
    {
        List<byte[]> vals = new List<byte[]>();
        long nrest = BitConverter.ToUInt32(blk, blk.Length - 4);
        long end = blk.Length - 4 - 4 * nrest;
        int p = 0;
        while (p < end)
        {
            Rv(blk, ref p);
            long nonshared = Rv(blk, ref p);
            long vlen = Rv(blk, ref p);
            p += (int)nonshared;
            byte[] v = new byte[vlen];
            Buffer.BlockCopy(blk, p, v, 0, (int)vlen);
            vals.Add(v);
            p += (int)vlen;
        }
        return vals;
    }

    static byte[] ReadAll(string path)
    {
        // Share flags let us read while Teams has the files open.
        using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        using (MemoryStream ms = new MemoryStream())
        {
            fs.CopyTo(ms);
            return ms.ToArray();
        }
    }

    static byte[] LoadStore(string folder, out DateTime newest)
    {
        List<string> names = new List<string>();
        foreach (string f in Directory.GetFiles(folder)) names.Add(Path.GetFileName(f));
        names.Sort(StringComparer.Ordinal);
        newest = DateTime.MinValue;
        foreach (string n in names)
        {
            try
            {
                DateTime t = File.GetLastWriteTime(Path.Combine(folder, n));
                if (t > newest) newest = t;
            }
            catch (Exception) { }
        }
        List<string> files = new List<string>();
        foreach (string n in names) if (n.EndsWith(".ldb", StringComparison.Ordinal)) files.Add(n);
        foreach (string n in names) if (n.EndsWith(".log", StringComparison.Ordinal)) files.Add(n);
        List<byte[]> chunks = new List<byte[]>();
        foreach (string n in files)
        {
            byte[] data;
            try { data = ReadAll(Path.Combine(folder, n)); }
            catch (UnauthorizedAccessException) { throw; }
            catch (Exception e) { P("  (could not read " + n + ": " + e.Message + ")"); continue; }
            if (n.EndsWith(".log", StringComparison.Ordinal)) { chunks.Add(data); continue; }
            try
            {
                int fp = data.Length - 48;
                if (fp < 0) throw BAD;
                Rv(data, ref fp);
                Rv(data, ref fp);
                long io = Rv(data, ref fp);
                long isz = Rv(data, ref fp);
                foreach (byte[] h in BlockValues(ReadBlock(data, io, isz)))
                {
                    int hp = 0;
                    long bo = Rv(h, ref hp);
                    long bs = Rv(h, ref hp);
                    try { chunks.Add(ReadBlock(data, bo, bs)); }
                    catch (Exception) { }
                }
            }
            catch (Exception) { chunks.Add(data); }
        }
        long total = 0;
        foreach (byte[] c in chunks) total += c.Length;
        byte[] raw = new byte[total];
        long o = 0;
        foreach (byte[] c in chunks) { Buffer.BlockCopy(c, 0, raw, (int)o, c.Length); o += c.Length; }
        return raw;
    }

    // ------------------------------------------------------------ V8 value reader
    static string Latin1(byte[] b, int a, int z)
    {
        char[] c = new char[z - a];
        for (int i = a; i < z; i++) c[i - a] = (char)b[i];
        return new string(c);
    }

    static int SkipPad(byte[] b, int p)
    {
        while (p < b.Length && b[p] == 0) p++;
        if (p >= b.Length) throw BAD;
        return p;
    }

    static object V8Value(byte[] b, ref int p, int depth)
    {
        if (depth > 30) throw BAD;
        p = SkipPad(b, p);
        int t = b[p++];
        if (t == 0x22 || t == 0x63 || t == 0x53)  // latin-1, utf-16, utf-8 string
        {
            long n = Rv(b, ref p);
            if (n < 0 || p + n > b.Length) throw BAD;
            int s = p;
            p += (int)n;
            if (t == 0x22) return Latin1(b, s, p);
            if (t == 0x63) return Encoding.Unicode.GetString(b, s, (int)n & ~1);
            return Encoding.UTF8.GetString(b, s, (int)n);
        }
        if (t == 0x44 || t == 0x4E)  // date, double
        {
            if (p + 8 > b.Length) throw BAD;
            double d = BitConverter.ToDouble(b, p);
            p += 8;
            if (t == 0x44) return new DateV(d);
            return d;
        }
        if (t == 0x49) { long n = Rv(b, ref p); return (n >> 1) ^ -(n & 1); }  // zigzag int
        if (t == 0x55) return Rv(b, ref p);
        if (t == 0x54) return true;
        if (t == 0x46) return false;
        if (t == 0x5F || t == 0x30 || t == 0x2D) return null;  // undefined, null, hole
        if (t == 0x5E) { Rv(b, ref p); return null; }  // back-reference
        if (t == 0x6F) return V8Object(b, ref p, depth + 1, -1);
        if (t == 0x41 || t == 0x61)  // dense / sparse array
        {
            long n = Rv(b, ref p);
            if (n > 100000) throw BAD;
            List<object> arr = new List<object>();
            if (t == 0x41)
                for (long i = 0; i < n; i++) arr.Add(V8Value(b, ref p, depth + 1));
            int props = 0;
            int endTag = t == 0x41 ? 0x24 : 0x40;
            while (true)
            {
                p = SkipPad(b, p);
                if (b[p] == endTag)
                {
                    p++;
                    long np = Rv(b, ref p);
                    Rv(b, ref p);
                    if (np != props) throw BAD;
                    return arr;
                }
                V8Value(b, ref p, depth + 1);
                object v = V8Value(b, ref p, depth + 1);
                if (t == 0x61) arr.Add(v);
                props++;
            }
        }
        throw BAD;
    }

    static string KeyString(object k)
    {
        if (k is string) return (string)k;
        if (k is long) return ((long)k).ToString(Inv);
        throw BAD;
    }

    static Dictionary<string, object> V8Object(byte[] b, ref int p, int depth, int target)
    {
        Dictionary<string, object> obj = new Dictionary<string, object>(StringComparer.Ordinal);
        int count = 0;
        bool hit = target < 0;
        while (true)
        {
            p = SkipPad(b, p);
            if (b[p] == 0x7B)  // end of object
            {
                p++;
                long np = Rv(b, ref p);
                if (np != count || !hit) throw BAD;
                return obj;
            }
            if (p == target) hit = true;
            string k = KeyString(V8Value(b, ref p, depth + 1));
            object v = V8Value(b, ref p, depth + 1);
            obj[k] = v;
            count++;
        }
    }

    static readonly string[] NearKeys = { "location", "endTime", "isReminderSet", "reminderMinutesBeforeStart", "subject", "organizerName" };

    static Dictionary<string, object> PartialEvent(byte[] raw, string latin, int s)
    {
        // Events with a huge body (e.g. a full HTML invite) start too far back to find the
        // object start, so read the event from the nearest known field up to its end instead.
        List<int> starts = new List<int>();
        int lo = Math.Max(0, s - 3000);
        foreach (string k in NearKeys)
        {
            string tok = "\"" + (char)k.Length + k;
            if (s < 1) break;
            int i = latin.LastIndexOf(tok, s - 1, StringComparison.Ordinal);
            if (i >= lo) starts.Add(i);
        }
        starts.Sort();
        starts.Add(s);
        foreach (int st in starts)
        {
            Dictionary<string, object> obj = new Dictionary<string, object>(StringComparer.Ordinal);
            int p = st;
            bool hit = false, ok = true;
            try
            {
                while (true)
                {
                    p = SkipPad(raw, p);
                    if (raw[p] == 0x7B) break;
                    if (p == s) hit = true;
                    object k = V8Value(raw, ref p, 0);
                    object v = V8Value(raw, ref p, 0);
                    obj[k == null ? "" : Convert.ToString(k, Inv)] = v;
                }
            }
            catch (Exception) { ok = false; }
            if (ok && hit) return obj;
        }
        return null;
    }

    static List<Dictionary<string, object>> FindEvents(byte[] raw, string latin)
    {
        List<Dictionary<string, object>> events = new List<Dictionary<string, object>>();
        const string key = "\"\tstartTime";
        int s = latin.IndexOf(key, StringComparison.Ordinal);
        while (s >= 0)
        {
            int lo = Math.Max(0, s - 8000), c = s, tries = 0;
            Dictionary<string, object> obj = null;
            while (tries < 600)
            {
                c--;
                while (c >= lo && raw[c] != 0x6F) c--;
                if (c < lo) break;
                tries++;
                try
                {
                    int p = c + 1;
                    obj = V8Object(raw, ref p, 0, s);
                    break;
                }
                catch (Exception) { obj = null; }
            }
            if (obj == null) obj = PartialEvent(raw, latin, s);
            if (obj != null && Get(obj, "subject") is string)
            {
                obj["_pos"] = (long)s;
                events.Add(obj);
            }
            s = latin.IndexOf(key, s + 1, StringComparison.Ordinal);
        }
        return events;
    }

    // ------------------------------------------------------------ helpers
    static object Get(Dictionary<string, object> d, string k)
    {
        object v;
        return d.TryGetValue(k, out v) ? v : null;
    }

    static string Str(Dictionary<string, object> d, string k)
    {
        string v = Get(d, k) as string;
        return v ?? "";
    }

    static readonly Regex IsoRe = new Regex(@"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d");

    static DateTime? ToLocal(object v)
    {
        try
        {
            DateV d = v as DateV;
            if (d != null)
            {
                if (double.IsNaN(d.Ms) || double.IsInfinity(d.Ms)) return null;
                return Epoch.AddMilliseconds(d.Ms).ToLocalTime();
            }
            string s = v as string;
            if (s != null && IsoRe.IsMatch(s))
            {
                DateTime t = DateTime.ParseExact(s.Substring(0, 19), "yyyy-MM-dd'T'HH:mm:ss", Inv,
                    DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal);
                return DateTime.SpecifyKind(t, DateTimeKind.Utc).ToLocalTime();
            }
        }
        catch (Exception) { }
        return null;
    }

    // Host must be the real domain or a subdomain of it (so "evilzoom.us" or "zoom.us.evil.com" never match).
    static readonly Regex MeetRe = new Regex(
        @"https://(?:[A-Za-z0-9-]+\.)*(?:zoom\.us/(?:j|w|my)/|teams\.microsoft\.com/(?:l/meetup-join|meet)/|" +
        @"teams\.live\.com/meet/|meet\.google\.com/|webex\.com/|gotomeet\.me/|meet\.goto\.com/|whereby\.com/)" +
        @"[A-Za-z0-9\-._~:/?#\[\]@!$&()*+,;=%]*", RegexOptions.CultureInvariant);
    static readonly Regex EmailRe = new Regex(@"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}");
    static readonly Regex EmailSkipRe = new Regex(@"no-?reply|notification|calendar-server|microsoft\.com$|\.spaces$|thread\.");
    static readonly Regex EmailIdRe = new Regex(@"^[0-9a-f_-]{20,}@");
    // Cached text comes from invites anyone can send you, so strip terminal control codes and
    // bidi/zero-width characters before printing it.
    static readonly Regex UnsafeRe = new Regex(@"[\x00-\x1f\x7f-\x9f\u200b-\u200f\u202a-\u202e\u2066-\u2069]");
    static readonly Regex SpaceRe = new Regex(@"\s+");
    static readonly Regex StyleRe = new Regex(@"<style.*?</style>", RegexOptions.IgnoreCase | RegexOptions.Singleline);
    static readonly Regex TagRe = new Regex(@"<[^<>]{0,2000}>");
    static readonly Regex LeadTagRe = new Regex(@"^[^<>]*>");
    static readonly Regex TrailTagRe = new Regex(@"<[^>]*$");
    static readonly Regex NonPrintRe = new Regex(@"[^\x20-\x7e\u00a0-\u024f\u2013\u2014\u2019]+");
    static readonly Regex EntRe = new Regex(@"&(#[xX][0-9a-fA-F]{1,6}|#\d{1,7}|[A-Za-z]{2,8});");
    static readonly Regex HeaderRe = new Regex(@"^\s\d\d:\d\d:\d\d GMT");
    static readonly Regex ZoomIdRe = new Regex(@"zoom\.us/j/(\d{9,11})");
    static readonly Regex WordRe = new Regex(@"\w+");
    static readonly Regex CancelRe = new Regex(@"^cancel", RegexOptions.IgnoreCase);

    static string Safe(string s)
    {
        return SpaceRe.Replace(UnsafeRe.Replace(s, " "), " ").Trim();
    }

    static readonly Dictionary<string, string> Ent = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        { "amp", "&" }, { "lt", "<" }, { "gt", ">" }, { "quot", "\"" }, { "apos", "'" }, { "nbsp", "\u00a0" },
        { "ndash", "\u2013" }, { "mdash", "\u2014" }, { "rsquo", "\u2019" }, { "lsquo", "\u2018" },
        { "ldquo", "\u201c" }, { "rdquo", "\u201d" }, { "hellip", "\u2026" }, { "bull", "\u2022" },
        { "copy", "\u00a9" }, { "reg", "\u00ae" }, { "euro", "\u20ac" }, { "middot", "\u00b7" }
    };

    static string EntityReplace(Match m)
    {
        string e = m.Groups[1].Value;
        if (e[0] == '#')
        {
            int code;
            bool hex = e.Length > 1 && (e[1] == 'x' || e[1] == 'X');
            bool ok = hex
                ? int.TryParse(e.Substring(2), NumberStyles.HexNumber, Inv, out code)
                : int.TryParse(e.Substring(1), NumberStyles.Integer, Inv, out code);
            if (!ok || code < 0 || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)) return " ";
            return char.ConvertFromUtf32(code);
        }
        string r;
        return Ent.TryGetValue(e, out r) ? r : m.Value;
    }

    static string Clean(string s)
    {
        for (int i = 0; i < 2; i++)  // invite HTML is sometimes stored HTML-escaped
        {
            s = EntRe.Replace(s, new MatchEvaluator(EntityReplace));
            s = StyleRe.Replace(s, " ");
            s = TagRe.Replace(s, " ");
        }
        s = LeadTagRe.Replace(s, " ");   // tag cut off at the start of the window
        s = TrailTagRe.Replace(s, " ");  // tag cut off at the end of the window
        s = NonPrintRe.Replace(s, " ");
        return Safe(s);
    }

    static bool IsText(int c)
    {
        return c == 9 || c == 10 || c == 13 || (c >= 0x20 && c <= 0x7e) || (c >= 0xa0 && c <= 0x24f) ||
            (c >= 0x2000 && c <= 0x206f) || c == 0x20ac;
    }

    static string TextRun(string t, int i)
    {
        // The stretch of readable text around position i, i.e. the cached string that contains it.
        int lo = Math.Max(0, i - 6000), hi = Math.Min(t.Length, i + 3000), a = i, b = i;
        while (a > lo && IsText(t[a - 1])) a--;
        while (b < hi && IsText(t[b])) b++;
        return t.Substring(a, b - a);
    }

    static List<int> FindAll(string text, string needle, int limit)
    {
        List<int> res = new List<int>();
        int i = text.IndexOf(needle, StringComparison.Ordinal);
        while (i >= 0 && res.Count < limit)
        {
            res.Add(i);
            i = text.IndexOf(needle, i + 1, StringComparison.Ordinal);
        }
        return res;
    }

    static string[] DatePhrases(DateTime d)
    {
        string M = d.ToString("MMMM", Inv), m = d.ToString("MMM", Inv), W = d.ToString("dddd", Inv);
        string day = d.Day.ToString(Inv), Y = d.Year.ToString(Inv);
        return new string[] {
            m + " " + day + ", " + Y, M + " " + day + ", " + Y, day + " " + m + " " + Y, day + " " + M + " " + Y,
            W + ", " + M + " " + day, W + ", " + day + " " + M, W + " " + m + " " + day,
            d.ToString("dd'/'MM'/'yyyy", Inv), d.ToString("MM'/'dd'/'yyyy", Inv), d.ToString("dd'.'MM'.'yyyy", Inv)
        };
    }

    static string Expand(string url)
    {
        string best = null;
        int bestN = 0;
        foreach (string u in AllUrls.Order)
        {
            if (u.Length > url.Length && u.StartsWith(url, StringComparison.Ordinal))
            {
                int n = AllUrls.Counts[u];
                if (best == null || n > bestN || (n == bestN && u.Length < best.Length)) { best = u; bestN = n; }
            }
        }
        return best ?? url;
    }

    static bool ZoomPasscode(string url, out string digits, out string code)
    {
        digits = null;
        code = null;
        Match mid = ZoomIdRe.Match(url);
        if (!mid.Success) return false;
        digits = mid.Groups[1].Value;
        string[] ds = new string[digits.Length];
        for (int i = 0; i < digits.Length; i++) ds[i] = digits[i].ToString();
        Regex re = new Regex(string.Join(@"\s?", ds) +
            @"[\s\S]{0,300}?(?:Passcode|Password)\s*:?\s*([A-Za-z0-9.@#$%^&*!_-]{4,20})");
        Counter codes = new Counter();
        foreach (string t in Pools)
            foreach (Match m in re.Matches(t)) codes.Add(m.Groups[1].Value);
        List<string> mc = codes.MostCommon();
        if (mc.Count > 0) code = mc[0];
        return true;
    }

    static List<string> EmailsNear(string subject)
    {
        List<string> res = new List<string>();
        string key = subject.Trim();
        if (key.Length > 40) key = key.Substring(0, 40);
        if (key.Length < 6) return res;
        Counter seen = new Counter();
        foreach (string t in Pools)
        {
            foreach (int i in FindAll(t, key, 60))
            {
                int a = Math.Max(0, i - 3000), z = Math.Min(t.Length, i + 8000);
                foreach (Match m in EmailRe.Matches(t.Substring(a, z - a))) seen.Add(m.Value.ToLowerInvariant());
            }
        }
        List<string> mc = seen.MostCommon();
        for (int i = 0; i < mc.Count && i < 20 && res.Count < 8; i++)
            if (!EmailSkipRe.IsMatch(mc[i]) && !EmailIdRe.IsMatch(mc[i])) res.Add(mc[i]);
        return res;
    }

    static string Hm(DateTime d) { return d.ToString("HH:mm", Inv); }

    static void PermissionHelp()
    {
        P("Permission denied reading the Teams cache.");
        P("Quit Teams completely (right-click its icon by the clock, then Quit) and run the command again.");
    }

    // ------------------------------------------------------------ main
    public static string Run(string[] args)
    {
        Buf = new StringBuilder();
        PermDenied = false;
        int days = 1;
        if (args != null && args.Length > 0 && args[0] != null && Regex.IsMatch(args[0], @"^\d+$"))
            days = int.Parse(args[0], Inv);
        List<string> stores = FindStores();
        if (stores.Count == 0)
        {
            if (PermDenied) PermissionHelp();
            else
            {
                P("No Microsoft Teams desktop cache found on this computer.");
                P("(Looked for new and classic Teams on Windows and macOS.)");
            }
            return Buf.ToString();
        }
        DateTime today = DateTime.Today;
        P("Read-only scan of the Teams desktop cache. Nothing is sent anywhere.");
        foreach (string folder in stores)
        {
            byte[] raw;
            DateTime newest;
            try { raw = LoadStore(folder, out newest); }
            catch (UnauthorizedAccessException) { P(""); PermissionHelp(); continue; }
            P("Cache: " + folder);
            P("Cache last updated: " + newest.ToString("ddd dd MMM yyyy HH:mm", Inv));

            string latin = Latin1(raw, 0, raw.Length);
            Pools = new string[] {
                latin,
                Encoding.Unicode.GetString(raw, 0, raw.Length & ~1),
                raw.Length > 1 ? Encoding.Unicode.GetString(raw, 1, (raw.Length - 1) & ~1) : ""
            };
            AllUrls = new Counter();
            foreach (string t in Pools)
                foreach (Match m in MeetRe.Matches(t)) AllUrls.Add(m.Value);

            // newest cached version of each event wins
            List<string> order = new List<string>();
            Dictionary<string, Dictionary<string, object>> best = new Dictionary<string, Dictionary<string, object>>(StringComparer.Ordinal);
            Dictionary<string, string> bestMod = new Dictionary<string, string>(StringComparer.Ordinal);
            Dictionary<string, long> bestPos = new Dictionary<string, long>(StringComparer.Ordinal);
            foreach (Dictionary<string, object> ev in FindEvents(raw, latin))
            {
                string key = Str(ev, "objectId");
                if (key.Length == 0) key = Str(ev, "subject") + "|" + Str(ev, "iCalUID");
                string mod = Str(ev, "lastModifiedTime");
                long pos = (long)ev["_pos"];
                if (!best.ContainsKey(key))
                {
                    order.Add(key);
                    best[key] = ev; bestMod[key] = mod; bestPos[key] = pos;
                }
                else
                {
                    int c = string.CompareOrdinal(mod, bestMod[key]);
                    if (c > 0 || (c == 0 && pos > bestPos[key])) { best[key] = ev; bestMod[key] = mod; bestPos[key] = pos; }
                }
            }
            List<Ev> events = new List<Ev>();
            foreach (string k in order)
            {
                DateTime? st = ToLocal(Get(best[k], "startTime"));
                if (!st.HasValue) continue;
                Ev e = new Ev();
                e.St = st.Value;
                e.En = ToLocal(Get(best[k], "endTime"));
                e.Obj = best[k];
                e.Idx = events.Count;
                events.Add(e);
            }
            events.Sort(delegate(Ev a, Ev b)
            {
                int c = a.St.CompareTo(b.St);
                return c != 0 ? c : a.Idx.CompareTo(b.Idx);
            });
            P("Calendar events in cache: " + events.Count.ToString(Inv));

            for (int di = 0; di < Math.Max(days, 1); di++)
            {
                DateTime day = today.AddDays(di);
                P("");
                P(new string('=', 78));
                P("MEETINGS ON " + day.ToString("dddd dd MMMM yyyy", Inv).ToUpperInvariant() + "  (times in this computer's time zone)");
                P(new string('=', 78));
                bool any = false;
                foreach (Ev e in events)
                {
                    if (e.St.Date != day) continue;
                    any = true;
                    Dictionary<string, object> ev = e.Obj;
                    string subj = Safe(Str(ev, "subject"));
                    if (subj.Length == 0) subj = "(no subject)";
                    string body = Str(ev, "bodyPreview");
                    string loc = Str(ev, "location");
                    P("");
                    P(Hm(e.St) + "-" + (e.En.HasValue ? Hm(e.En.Value) : "?") + "  " + subj);
                    object canc = Get(ev, "isCancelled");
                    if ((canc is bool && (bool)canc) || CancelRe.IsMatch(subj)) P("   ** looks CANCELLED **");
                    string org = Str(ev, "organizerName");
                    P("   Organizer : " + Safe(org.Length > 0 ? org : "?"));
                    string reply = Str(ev, "myResponseType");
                    if (reply.Length > 0) P("   Your reply: " + Safe(reply));
                    if (loc.Length > 0) P("   Location  : " + Safe(loc));
                    List<string> links = new List<string>();
                    foreach (string k in new string[] { "skypeTeamsMeetingUrl", "shortOnlineMeetingJoinUrl", "onlineMeetingUrl", "joinUrl" })
                    {
                        string v = Str(ev, k);
                        if (v.StartsWith("http", StringComparison.Ordinal)) links.Add(v);
                    }
                    // links typed into the description are often cut short; use the full copy if cached
                    foreach (Match m in MeetRe.Matches(loc)) links.Add(Expand(m.Value));
                    foreach (Match m in MeetRe.Matches(body)) links.Add(Expand(m.Value));
                    List<string> shown = new List<string>();
                    foreach (string u in links)
                    {
                        if (shown.Contains(u)) continue;
                        shown.Add(u);
                        P("   Join link : " + u);
                        string zid, code;
                        if (ZoomPasscode(u, out zid, out code))
                        {
                            int[] groups;
                            if (zid.Length == 9) groups = new int[] { 3, 3, 3 };
                            else if (zid.Length == 10) groups = new int[] { 3, 3, 4 };
                            else if (zid.Length == 11) groups = new int[] { 3, 4, 4 };
                            else groups = new int[] { zid.Length };
                            List<string> parts = new List<string>();
                            int k2 = 0;
                            foreach (int g in groups) { parts.Add(zid.Substring(k2, g)); k2 += g; }
                            P("   Zoom ID   : " + string.Join(" ", parts.ToArray()) + "   Passcode: " + (code ?? "(not found in cache)"));
                        }
                    }
                    if (shown.Count == 0) P("   Join link : (none in cache - see invite text below)");
                    if (body.Length > 0)
                    {
                        string pv = Clean(body);
                        P("   Preview   : " + (pv.Length > 220 ? pv.Substring(0, 220) : pv));
                    }
                    List<string> em = EmailsNear(subj);
                    if (em.Count > 0) P("   Emails seen near this invite: " + string.Join(", ", em.ToArray()));
                    string lm = Str(ev, "lastModifiedTime");
                    if (lm.Length > 0)
                        P("   (cached version last changed " + Safe((lm.Length > 16 ? lm.Substring(0, 16) : lm).Replace("T", " ")) + " UTC)");
                }
                if (!any)
                {
                    P("No cached calendar events for this day. Teams only caches meetings it has");
                    P("loaded recently, so check the 'invites mentioning this date' section below.");
                }

                // raw invite emails / chat meeting cards that mention the date
                P("");
                P("--- Invites / messages in the cache that mention " + day.ToString("dd MMM", Inv) + " ---");
                List<Dictionary<string, bool>> shownSnips = new List<Dictionary<string, bool>>();
                int count = 0;
                bool done = false;
                foreach (string phrase in DatePhrases(day))
                {
                    foreach (string t in Pools)
                    {
                        foreach (int i in FindAll(t, phrase, 40))
                        {
                            int a = i + phrase.Length;
                            string after = a < t.Length ? t.Substring(a, Math.Min(14, t.Length - a)) : "";
                            if (HeaderRe.IsMatch(after)) continue;  // web request header, not a meeting
                            string seg = TextRun(t, i);
                            string c = Clean(seg);
                            int j = c.IndexOf(phrase, StringComparison.Ordinal);
                            if (j < 0) continue;
                            int s0 = Math.Max(0, j - 700), e0 = Math.Min(c.Length, j + 450);
                            string snip = c.Substring(s0, e0 - s0);
                            Dictionary<string, bool> words = new Dictionary<string, bool>(StringComparer.Ordinal);
                            foreach (Match m in WordRe.Matches(snip.ToLowerInvariant())) words[m.Value] = true;
                            bool dup = false;
                            foreach (Dictionary<string, bool> w in shownSnips)
                            {
                                int inter = 0;
                                foreach (string x in words.Keys) if (w.ContainsKey(x)) inter++;
                                if (inter > 0.7 * (words.Count + w.Count - inter)) { dup = true; break; }
                            }
                            if (dup) continue;  // same invite already shown
                            shownSnips.Add(words);
                            count++;
                            P("");
                            P("[" + count.ToString(Inv) + "] ..." + snip + "...");
                            List<string> ls = new List<string>();
                            foreach (Match m in MeetRe.Matches(seg))
                            {
                                string ex = Expand(m.Value);
                                if (!ls.Contains(ex)) ls.Add(ex);
                            }
                            ls.Sort(StringComparer.Ordinal);
                            foreach (string u in ls) P("    link: " + u);
                            if (count >= 6) { done = true; break; }
                        }
                        if (done) break;
                    }
                    if (done) break;
                }
                if (count == 0) P("(none found)");
            }
        }
        P("");
        P(Tip);
        P("Double-check times: cached data may be out of date if a meeting was moved after Teams last synced.");
        return Buf.ToString();
    }
}
'@

if (-not ('TeamsCacheMeetingFinder' -as [type])) {
    Add-Type -TypeDefinition $TeamsCacheMeetingFinderSource -Language CSharp -IgnoreWarnings
}
[TeamsCacheMeetingFinder]::Run([string[]]$args)
