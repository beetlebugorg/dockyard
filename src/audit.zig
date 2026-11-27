//! The audit log of the agent program (`docs/dev/audit.md`). One stream
//! of records for each project: JSON lines with a SHA-256 chain, an index
//! of fixed records for a fast filter, and an export. The folder of the
//! log is outside the project (`dirFor`), since the agent program can
//! write the project folder.
//!
//! The files in the folder (mode 0700):
//!   log-NNNNNN.jsonl  the records, up to `max_file` bytes in each file
//!   index             a header of 64 bytes, then one `Entry` for each record
//!
//! The header: the magic "DYAUDIT1", the seq of the last record (u64),
//! the number of the log file of the last record (u32), 4 zero bytes, and
//! the SHA-256 of the line of the last record. All integers are little
//! endian. The writer takes an flock on the index for each record, so two
//! windows of one project write one chain.
//!
//! The order of the writes of one record: the line, the entry, the
//! header. `repair` makes the files agree again after a crash between two
//! of these writes.
//!
//! Tcl commands:
//!   dockyard::audit log KIND DICT ?OPTIONS?    Adds a record. DICT has the fields of `data`.
//!   dockyard::audit json KIND JSON ?OPTIONS?   Adds a record with `data` as a JSON object.
//!     OPTIONS: -session ID, -turn ID, -call ID, -source NAME, -time MS.
//!   dockyard::audit session                    Starts a new session id and gives it.
//!   dockyard::audit context ?-session ID? ?-turn ID?
//!                                              Sets the session and the turn of the next records.
//!   dockyard::audit query ?FILTERS?            Gives the records that match, as dicts.
//!   dockyard::audit count ?FILTERS?            Gives the number of records that match.
//!     FILTERS: -kind LIST, -source LIST, -session ID, -turn ID, -call ID,
//!     -since MS, -until MS, -after SEQ, -before SEQ, -text TEXT,
//!     -limit N (the first N), -last N (the last N), -format dict|json.
//!   dockyard::audit last                       Gives the seq of the last record.
//!   dockyard::audit verify                     Checks the chain. Gives a dict.
//!   dockyard::audit path                       Gives the folder of the log.

const std = @import("std");
const builtin = @import("builtin");
const ztcl = @import("ztcl");
const c = std.c;
const Sha256 = std.crypto.hash.sha2.Sha256;

const on_win = builtin.os.tag == .windows;

pub const version = 1;
/// The size limit of one log file.
pub var max_file: u64 = 64 << 20;
/// The size limit of one line.
const max_line = 512 * 1024;
const header_size = 64;
const magic = "DYAUDIT1";
const zero_hash: [64]u8 = @splat('0');

pub const kinds = [_][]const u8{ "session", "turn", "tool", "exec", "exit", "file", "net", "dns", "blocked", "build", "share", "rule", "note" };
pub const sources = [_][]const u8{ "hook", "helper", "proxy", "nat", "watch", "app" };

/// One record of the index. The ids are the low 32 bits of the Wyhash of
/// the id text, and 0 for null. A match of an id hash is checked against
/// the line, so a collision gives no wrong match.
pub const Entry = extern struct {
    seq: u64,
    time: i64,
    off: u32,
    len: u32,
    session: u32,
    turn: u32,
    call: u32,
    file: u16,
    kind: u8,
    source: u8,
};

comptime {
    std.debug.assert(@sizeOf(Entry) == 40);
}

const Header = struct {
    seq: u64 = 0,
    file: u32 = 1,
    hash: [64]u8 = zero_hash,
};

fn idHash(id: ?[]const u8) u32 {
    const s = id orelse return 0;
    const h: u32 = @truncate(std.hash.Wyhash.hash(0x617564, s));
    return if (h == 0) 1 else h;
}

fn indexOf(list: []const []const u8, name: []const u8) ?u8 {
    for (list, 0..) |n, i| if (std.mem.eql(u8, n, name)) return @intCast(i);
    return null;
}

/// The folder of the audit log of `project`. HASH is the Wyhash of the
/// project path, as in `host.controlPath`.
pub fn dirFor(a: std.mem.Allocator, env: *const std.process.Environ.Map, project: []const u8) ![:0]const u8 {
    const hash = std.hash.Wyhash.hash(0, project);
    if (comptime on_win) {
        const base = env.get("LOCALAPPDATA") orelse return error.NoStateFolder;
        return std.fmt.allocPrintSentinel(a, "{s}\\dockyard\\audit\\{x:0>16}", .{ base, hash }, 0);
    }
    const home = env.get("HOME") orelse "";
    if (comptime builtin.os.tag.isDarwin()) {
        if (home.len == 0) return error.NoStateFolder;
        return std.fmt.allocPrintSentinel(a, "{s}/Library/Application Support/dockyard/audit/{x:0>16}", .{ home, hash }, 0);
    }
    if (env.get("XDG_STATE_HOME")) |s| if (s.len > 0 and s[0] == '/')
        return std.fmt.allocPrintSentinel(a, "{s}/dockyard/audit/{x:0>16}", .{ s, hash }, 0);
    if (home.len == 0) return error.NoStateFolder;
    return std.fmt.allocPrintSentinel(a, "{s}/.local/state/dockyard/audit/{x:0>16}", .{ home, hash }, 0);
}

/// Makes each folder of `path` that does not exist, with mode 0700.
fn mkdirs(path: [:0]const u8) bool {
    if (comptime on_win) return false;
    var buf: [1024]u8 = undefined;
    if (path.len >= buf.len) return false;
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i < path.len and path[i] != '/') continue;
        @memcpy(buf[0..i], path[0..i]);
        buf[i] = 0;
        _ = c.mkdir(@ptrCast(&buf), 0o700);
    }
    return true;
}

/// One open log: the folder, the index, and the maps of the log files
/// for the readers.
pub const Log = struct {
    dir: [:0]const u8 = "",
    index_fd: c.fd_t = -1,
    log_fd: c.fd_t = -1,
    log_num: u32 = 0,
    /// The entries of the index that this process read or wrote.
    entries: std.ArrayList(Entry) = .empty,
    maps: std.ArrayList([]const u8) = .empty,
    a: std.mem.Allocator,
    /// The session and the turn of the next records.
    session: []u8 = &.{},
    turn: ?[]u8 = null,
    clock: *const fn () i64 = wallMs,
    path_buf: [1024]u8 = undefined,

    pub fn open(a: std.mem.Allocator, dir: [:0]const u8) !Log {
        if (comptime on_win) return error.Unsupported;
        if (!mkdirs(dir)) return error.NoFolder;
        var l: Log = .{ .a = a, .dir = try a.dupeSentinel(u8, dir, 0) };
        const p = try l.path("index", 0);
        l.index_fd = c.open(p.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
        if (l.index_fd < 0) return error.NoIndex;
        return l;
    }

    pub fn close(l: *Log) void {
        for (l.maps.items) |m| if (m.len > 0) unmap(m);
        l.maps.deinit(l.a);
        l.entries.deinit(l.a);
        if (l.log_fd >= 0) _ = c.close(l.log_fd);
        if (l.index_fd >= 0) _ = c.close(l.index_fd);
        l.log_fd = -1;
        l.index_fd = -1;
    }

    /// The path of a file of the folder, in `path_buf`: `name`, or with
    /// `num` above 0 the log file of that number.
    fn path(l: *Log, name: []const u8, num: u32) ![:0]const u8 {
        if (num == 0) return std.fmt.bufPrintSentinel(&l.path_buf, "{s}/{s}", .{ l.dir, name }, 0);
        return std.fmt.bufPrintSentinel(&l.path_buf, "{s}/log-{d:0>6}.jsonl", .{ l.dir, num }, 0);
    }

    fn readHeader(l: *Log) Header {
        var b: [header_size]u8 = undefined;
        if (c.pread(l.index_fd, &b, b.len, 0) != header_size or !std.mem.eql(u8, b[0..8], magic)) return .{};
        var h: Header = .{
            .seq = std.mem.readInt(u64, b[8..16], .little),
            .file = std.mem.readInt(u32, b[16..20], .little),
        };
        h.hash = std.fmt.bytesToHex(b[24..56].*, .lower);
        return h;
    }

    fn writeHeader(l: *Log, h: Header) bool {
        var b: [header_size]u8 = @splat(0);
        @memcpy(b[0..8], magic);
        std.mem.writeInt(u64, b[8..16], h.seq, .little);
        std.mem.writeInt(u32, b[16..20], h.file, .little);
        _ = std.fmt.hexToBytes(b[24..56], &h.hash) catch return false;
        return c.pwrite(l.index_fd, &b, b.len, 0) == header_size;
    }

    fn indexCount(l: *Log) u64 {
        const end = c.lseek(l.index_fd, 0, c.SEEK.END);
        if (end < header_size) return 0;
        return @intCast(@divFloor(end - header_size, @sizeOf(Entry)));
    }

    fn readEntry(l: *Log, seq: u64) ?Entry {
        var e: Entry = undefined;
        const off: i64 = @intCast(header_size + (seq - 1) * @sizeOf(Entry));
        if (c.pread(l.index_fd, std.mem.asBytes(&e), @sizeOf(Entry), off) != @sizeOf(Entry)) return null;
        return e;
    }

    fn writeEntry(l: *Log, e: Entry) bool {
        const off: i64 = @intCast(header_size + (e.seq - 1) * @sizeOf(Entry));
        return c.pwrite(l.index_fd, std.mem.asBytes(&e), @sizeOf(Entry), off) == @sizeOf(Entry);
    }

    fn useLog(l: *Log, num: u32) bool {
        if (l.log_fd >= 0 and l.log_num == num) return true;
        if (l.log_fd >= 0) _ = c.close(l.log_fd);
        const p = l.path("", num) catch return false;
        l.log_fd = c.open(p.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .APPEND = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
        l.log_num = num;
        return l.log_fd >= 0;
    }

    fn logSize(l: *Log) u64 {
        const end = c.lseek(l.log_fd, 0, c.SEEK.END);
        return if (end > 0) @intCast(end) else 0;
    }

    /// Makes the index and the header agree with the log files, under
    /// the lock. A complete line after the last entry that fits the
    /// chain goes into the index. A partial last line is cut. A line that
    /// does not fit the chain stays, and the next records go into a new
    /// log file after a note.
    fn repair(l: *Log, h: *Header) !void {
        const count = l.indexCount();
        if (count > h.seq) _ = c.ftruncate(l.index_fd, @intCast(header_size + h.seq * @sizeOf(Entry)));
        if (count < h.seq) {
            // The header is the last write, so this is a cut index.
            h.seq = count;
            if (count == 0) h.hash = zero_hash else {
                const e = l.readEntry(count).?;
                h.file = e.file;
                const line = try l.readLine(e);
                defer l.a.free(line);
                h.hash = hexHash(line);
            }
        }
        var num = h.file;
        var notes: std.ArrayList([]const u8) = .empty;
        defer {
            for (notes.items) |n| l.a.free(n);
            notes.deinit(l.a);
        }
        while (true) {
            if (!l.useLog(num)) return error.NoLog;
            const size = l.logSize();
            var from: u64 = 0;
            if (h.seq > 0) if (l.readEntry(h.seq)) |e| if (e.file == num) {
                from = @as(u64, e.off) + e.len + 1;
            };
            if (size > from) {
                const tail = try l.a.alloc(u8, @intCast(size - from));
                defer l.a.free(tail);
                if (c.pread(l.log_fd, tail.ptr, tail.len, @intCast(from)) != @as(isize, @intCast(tail.len))) return error.NoLog;
                var at: usize = 0;
                var bad = false;
                while (std.mem.indexOfScalarPos(u8, tail, at, '\n')) |end| : (at = end + 1) {
                    const line = tail[at..end];
                    const e = parseEntry(l.a, line, h.seq + 1, &h.hash) orelse {
                        bad = true;
                        break;
                    };
                    var ent = e;
                    ent.file = @intCast(num);
                    ent.off = @intCast(from + at);
                    ent.len = @intCast(line.len);
                    if (!l.writeEntry(ent)) return error.NoIndex;
                    h.seq += 1;
                    h.file = num;
                    h.hash = hexHash(line);
                }
                if (bad) {
                    try notes.append(l.a, try std.fmt.allocPrint(l.a, "the records after byte {d} of log {d} do not fit the chain", .{ from + at, num }));
                    num += 1;
                    h.file = num;
                    continue;
                } else if (at < tail.len) {
                    _ = c.ftruncate(l.log_fd, @intCast(from + at));
                    try notes.append(l.a, try std.fmt.allocPrint(l.a, "cut a partial record of {d} bytes at the end of log {d}", .{ tail.len - at, num }));
                }
            }
            // A crash after the first line of a new file leaves the header
            // on the old file.
            const next = l.path("", num + 1) catch break;
            if (c.access(next.ptr, 0) != 0) break;
            num += 1;
        }
        if (!l.writeHeader(h.*)) return error.NoIndex;
        for (notes.items) |n| {
            var w: Line = .{ .a = l.a };
            defer w.buf.deinit(l.a);
            try w.raw("{");
            try w.key("text");
            try w.str(n, 4096);
            try w.raw("}");
            _ = try l.appendLocked(h, "note", "app", w.buf.items, l.session, null, null, l.clock());
        }
    }

    /// Adds one record. `data` is the JSON object of the kind.
    pub fn append(l: *Log, kind: []const u8, source: []const u8, data: []const u8, session: []const u8, turn: ?[]const u8, call: ?[]const u8, time: i64) !u64 {
        if (indexOf(&kinds, kind) == null) return error.BadKind;
        if (indexOf(&sources, source) == null) return error.BadSource;
        if (c.flock(l.index_fd, c.LOCK.EX) != 0) return error.NoLock;
        defer _ = c.flock(l.index_fd, c.LOCK.UN);
        var h = l.readHeader();
        try l.repair(&h);
        return l.appendLocked(&h, kind, source, data, session, turn, call, time);
    }

    fn appendLocked(l: *Log, h: *Header, kind: []const u8, source: []const u8, data: []const u8, session: []const u8, turn: ?[]const u8, call: ?[]const u8, time: i64) !u64 {
        const seq = h.seq + 1;
        var w: Line = .{ .a = l.a };
        defer w.buf.deinit(l.a);
        try w.print("{{\"v\":{d},\"seq\":{d},\"time\":{d},\"kind\":\"{s}\",\"session\":", .{ version, seq, time, kind });
        try w.str(session, 256);
        try w.raw(",\"turn\":");
        if (turn) |t| try w.str(t, 256) else try w.raw("null");
        try w.raw(",\"call\":");
        if (call) |t| try w.str(t, 256) else try w.raw("null");
        try w.print(",\"source\":\"{s}\",\"data\":", .{source});
        try w.raw(data);
        try w.print(",\"prev\":\"{s}\"}}", .{h.hash});
        const line = w.buf.items;
        if (line.len > max_line) return error.LineTooLong;
        if (!l.useLog(h.file)) return error.NoLog;
        var size = l.logSize();
        if (size > 0 and size + line.len + 1 > max_file) {
            h.file += 1;
            if (!l.useLog(h.file)) return error.NoLog;
            size = l.logSize();
        }
        try w.raw("\n");
        const all = w.buf.items;
        if (c.write(l.log_fd, all.ptr, all.len) != @as(isize, @intCast(all.len))) return error.NoLog;
        const e: Entry = .{
            .seq = seq,
            .time = time,
            .off = @intCast(size),
            .len = @intCast(line.len),
            .session = idHash(session),
            .turn = idHash(turn),
            .call = idHash(call),
            .file = @intCast(h.file),
            .kind = indexOf(&kinds, kind).?,
            .source = indexOf(&sources, source).?,
        };
        if (!l.writeEntry(e)) return error.NoIndex;
        h.seq = seq;
        h.hash = hexHash(line);
        if (!l.writeHeader(h.*)) return error.NoIndex;
        return seq;
    }

    /// Reads the new entries of the index into `entries`.
    fn refresh(l: *Log) !void {
        const n = l.indexCount();
        const have = l.entries.items.len;
        if (n <= have) return;
        try l.entries.resize(l.a, @intCast(n));
        const bytes = std.mem.sliceAsBytes(l.entries.items[have..]);
        const off: i64 = @intCast(header_size + have * @sizeOf(Entry));
        const got = c.pread(l.index_fd, bytes.ptr, bytes.len, off);
        if (got != @as(isize, @intCast(bytes.len))) {
            const whole: usize = if (got > 0) @as(usize, @intCast(got)) / @sizeOf(Entry) else 0;
            l.entries.shrinkRetainingCapacity(have + whole);
        }
    }

    /// The line of an entry, from the map of its log file.
    fn lineOf(l: *Log, e: Entry) ?[]const u8 {
        const end = @as(u64, e.off) + e.len;
        while (l.maps.items.len < e.file) l.maps.append(l.a, &.{}) catch return null;
        const m = &l.maps.items[e.file - 1];
        if (m.len < end) {
            if (m.len > 0) unmap(m.*);
            m.* = &.{};
            const p = l.path("", e.file) catch return null;
            m.* = map(p) orelse return null;
            if (m.len < end) return null;
        }
        return m.*[e.off..end];
    }

    fn readLine(l: *Log, e: Entry) ![]u8 {
        const b = try l.a.alloc(u8, e.len);
        const p = try l.path("", e.file);
        const fd = c.open(p.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c.mode_t, 0));
        if (fd < 0) return error.NoLog;
        defer _ = c.close(fd);
        if (c.pread(fd, b.ptr, b.len, e.off) != @as(isize, @intCast(b.len))) return error.NoLog;
        return b;
    }

    pub const Filter = struct {
        kinds: u16 = 0xffff,
        sources: u8 = 0xff,
        session: ?[]const u8 = null,
        turn: ?[]const u8 = null,
        call: ?[]const u8 = null,
        since: i64 = std.math.minInt(i64),
        until: i64 = std.math.maxInt(i64),
        after: u64 = 0,
        before: u64 = std.math.maxInt(u64),
        text: []const u8 = "",
    };

    /// The lines of the records that match `f`: the first `limit`, or with
    /// `last` the last `limit`.
    pub fn query(l: *Log, a: std.mem.Allocator, f: Filter, limit: usize, last: bool) ![]const []const u8 {
        try l.refresh();
        const sh = if (f.session) |s| idHash(s) else 0;
        const th = if (f.turn) |s| idHash(s) else 0;
        const ch = if (f.call) |s| idHash(s) else 0;
        var out: std.ArrayList([]const u8) = .empty;
        const all = l.entries.items;
        const lo: usize = @intCast(@min(f.after, all.len));
        const hi: usize = @intCast(@min(f.before -| 1, all.len));
        if (lo >= hi) return out.toOwnedSlice(a);
        var i: usize = if (last) hi else lo;
        while (out.items.len < limit) {
            if (last) {
                if (i == lo) break;
                i -= 1;
            } else if (i >= hi) break;
            const e = all[i];
            if (!last) i += 1;
            if (e.time < f.since or e.time > f.until) continue;
            if (f.kinds & (@as(u16, 1) << @intCast(e.kind)) == 0) continue;
            if (f.sources & (@as(u8, 1) << @intCast(e.source)) == 0) continue;
            if (f.session != null and e.session != sh) continue;
            if (f.turn != null and e.turn != th) continue;
            if (f.call != null and e.call != ch) continue;
            const text = l.lineOf(e) orelse continue;
            if (f.session) |s| if (!fieldIs(text, "session", s)) continue;
            if (f.turn) |s| if (!fieldIs(text, "turn", s)) continue;
            if (f.call) |s| if (!fieldIs(text, "call", s)) continue;
            if (f.text.len > 0 and std.ascii.findIgnoreCase(text, f.text) == null) continue;
            try out.append(a, text);
        }
        if (last) std.mem.reverse([]const u8, out.items);
        return out.toOwnedSlice(a);
    }

    pub fn lastSeq(l: *Log) u64 {
        return l.readHeader().seq;
    }

    pub const Check = struct {
        ok: bool,
        records: u64,
        last: [64]u8,
        /// The seq of the first bad record, with ok false.
        bad: u64 = 0,
        reason: []const u8 = "",
    };

    /// Reads each log file in order and checks the seq numbers and the
    /// chain, and the hash of the header. With `out`, writes each line.
    pub fn verify(l: *Log, out: ?*std.ArrayList(u8)) !Check {
        const h = l.readHeader();
        var prev: [64]u8 = zero_hash;
        var seq: u64 = 0;
        var num: u32 = 1;
        while (true) : (num += 1) {
            const p = try l.path("", num);
            const m = map(p) orelse break;
            defer if (m.len > 0) unmap(m);
            var at: usize = 0;
            while (std.mem.indexOfScalarPos(u8, m, at, '\n')) |end| : (at = end + 1) {
                const text = m[at..end];
                if (parseEntry(l.a, text, seq + 1, &prev) == null)
                    return .{ .ok = false, .records = seq, .last = prev, .bad = seq + 1, .reason = "the record does not fit the chain" };
                seq += 1;
                prev = hexHash(text);
                if (out) |o| {
                    try o.appendSlice(l.a, text);
                    try o.append(l.a, '\n');
                }
            }
            if (at < m.len) return .{ .ok = false, .records = seq, .last = prev, .bad = seq + 1, .reason = "a partial record" };
        }
        if (seq != h.seq or !std.mem.eql(u8, &prev, &h.hash))
            return .{ .ok = false, .records = seq, .last = prev, .bad = seq, .reason = "the last record is not the record of the index" };
        return .{ .ok = true, .records = seq, .last = prev };
    }
};

fn wallMs() i64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divFloor(@as(i64, ts.nsec), 1_000_000);
}

fn map(p: [:0]const u8) ?[]const u8 {
    if (comptime on_win) return null;
    const fd = c.open(p.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c.mode_t, 0));
    if (fd < 0) return null;
    defer _ = c.close(fd);
    const end = c.lseek(fd, 0, c.SEEK.END);
    if (end <= 0) return &.{};
    const len: usize = @intCast(end);
    const r = c.mmap(null, len, .{ .READ = true }, .{ .TYPE = .SHARED }, fd, 0);
    if (@intFromPtr(r) == std.math.maxInt(usize)) return null;
    return @as([*]const u8, @ptrCast(r))[0..len];
}

fn unmap(m: []const u8) void {
    _ = c.munmap(@alignCast(@ptrCast(m.ptr)), m.len);
}

fn hexHash(text: []const u8) [64]u8 {
    var d: [32]u8 = undefined;
    Sha256.hash(text, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
}

/// True when the envelope field `name` of `text` is the string `id`. The
/// envelope fields come before `data`, so the first match is the field.
fn fieldIs(text: []const u8, name: []const u8, id: []const u8) bool {
    var keybuf: [16]u8 = undefined;
    const key = std.fmt.bufPrint(&keybuf, ",\"{s}\":", .{name}) catch return false;
    const at = std.mem.indexOf(u8, text, key) orelse return false;
    var w: Line = .{ .a = std.heap.page_allocator };
    defer w.buf.deinit(w.a);
    w.str(id, 256) catch return false;
    return std.mem.startsWith(u8, text[at + key.len ..], w.buf.items);
}

/// The entry of a line, when it is a record of this schema with the
/// seq `seq` and the prev `prev`. The offsets and the file are for the
/// caller to set.
fn parseEntry(a: std.mem.Allocator, text: []const u8, seq: u64, prev: *const [64]u8) ?Entry {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), text, .{}) catch return null;
    if (v != .object) return null;
    const o = v.object;
    const s = o.get("seq") orelse return null;
    if (s != .integer or s.integer != seq) return null;
    const p = o.get("prev") orelse return null;
    if (p != .string or !std.mem.eql(u8, p.string, prev)) return null;
    const t = o.get("time") orelse return null;
    if (t != .integer) return null;
    const k = o.get("kind") orelse return null;
    if (k != .string) return null;
    const src = o.get("source") orelse return null;
    if (src != .string) return null;
    const id = struct {
        fn get(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
            const x = obj.get(name) orelse return null;
            return if (x == .string) x.string else null;
        }
    };
    return .{
        .seq = seq,
        .time = t.integer,
        .off = 0,
        .len = 0,
        .session = idHash(id.get(o, "session")),
        .turn = idHash(id.get(o, "turn")),
        .call = idHash(id.get(o, "call")),
        .file = 0,
        .kind = indexOf(&kinds, k.string) orelse return null,
        .source = indexOf(&sources, src.string) orelse return null,
    };
}

/// A JSON writer for one line.
const Line = struct {
    a: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,

    fn raw(w: *Line, s: []const u8) !void {
        try w.buf.appendSlice(w.a, s);
    }

    fn print(w: *Line, comptime fmt: []const u8, args: anytype) !void {
        try w.buf.print(w.a, fmt, args);
    }

    fn key(w: *Line, k: []const u8) !void {
        const last = if (w.buf.items.len > 0) w.buf.items[w.buf.items.len - 1] else '{';
        if (last != '{' and last != '[') try w.raw(",");
        try w.str(k, 256);
        try w.raw(":");
    }

    /// A JSON string of the first `max` bytes of `s`, cut at the start of
    /// a UTF-8 sequence. A byte that is not valid UTF-8 becomes U+FFFD.
    fn str(w: *Line, s0: []const u8, max: usize) !void {
        var s = s0;
        if (s.len > max) {
            var n = max;
            while (n > 0 and s[n] & 0xc0 == 0x80) n -= 1;
            s = s[0..n];
        }
        try w.raw("\"");
        var i: usize = 0;
        while (i < s.len) {
            const ch = s[i];
            switch (ch) {
                '"' => try w.raw("\\\""),
                '\\' => try w.raw("\\\\"),
                '\n' => try w.raw("\\n"),
                '\r' => try w.raw("\\r"),
                '\t' => try w.raw("\\t"),
                0...8, 11, 12, 14...31, 127 => try w.print("\\u{x:0>4}", .{ch}),
                else => {
                    if (ch < 0x80) {
                        try w.buf.append(w.a, ch);
                    } else {
                        const n = std.unicode.utf8ByteSequenceLength(ch) catch 0;
                        if (n == 0 or i + n > s.len or !std.unicode.utf8ValidateSlice(s[i .. i + n])) {
                            try w.raw("\u{fffd}");
                        } else {
                            try w.raw(s[i .. i + n]);
                            i += n;
                            continue;
                        }
                    }
                },
            }
            i += 1;
        }
        try w.raw("\"");
    }
};

/// The JSON type of each field of `data` that is not a string.
const FieldType = enum { str, int, bool, strs, sdict, nstr, json };

fn fieldType(name: []const u8) FieldType {
    const map_ = .{
        .{ "pid", .int },      .{ "ppid", .int },    .{ "code", .int },  .{ "ms", .int },
        .{ "port", .int },     .{ "up", .int },      .{ "down", .int },  .{ "exit", .int },
        .{ "size", .int },     .{ "sandbox", .bool }, .{ "ok", .bool },  .{ "argv", .strs },
        .{ "targets", .strs }, .{ "answers", .strs }, .{ "input", .sdict }, .{ "before", .nstr },
        .{ "after", .nstr },   .{ "diff", .nstr },   .{ "output", .json }, .{ "files", .json },
        .{ "response", .json },
    };
    inline for (map_) |m| if (std.mem.eql(u8, name, m[0])) return m[1];
    return .str;
}

/// The byte limit of a string field.
fn fieldMax(name: []const u8) usize {
    if (std.mem.eql(u8, name, "prompt")) return 2000;
    return 64 * 1024;
}

/// The `data` object of a Tcl dict, with the types of `fieldType`.
fn dataOfDict(it: *ztcl.Interp, w: *Line, d: ztcl.Value) ztcl.Error!void {
    const items = try it.list(d);
    if (items.len % 2 != 0) return it.fail("audit: the data is not a dict", .{});
    w.raw("{") catch return error.OutOfMemory;
    var i: usize = 0;
    while (i < items.len) : (i += 2) {
        const k = try it.str(items[i]);
        const v = items[i + 1];
        w.key(k) catch return error.OutOfMemory;
        (switch (fieldType(k)) {
            .str => w.str(try it.str(v), fieldMax(k)),
            .nstr => if ((try it.str(v)).len == 0) w.raw("null") else w.str(try it.str(v), fieldMax(k)),
            .int => blk: {
                const n = v.asInt() orelse std.fmt.parseInt(i64, try it.str(v), 10) catch
                    return it.fail("audit: {s} is not an integer", .{k});
                break :blk w.print("{d}", .{n});
            },
            .bool => blk: {
                const s = try it.str(v);
                const t = std.mem.eql(u8, s, "1") or std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "yes");
                if (!t and !std.mem.eql(u8, s, "0") and !std.mem.eql(u8, s, "false") and !std.mem.eql(u8, s, "no"))
                    return it.fail("audit: {s} is not a boolean", .{k});
                break :blk w.raw(if (t) "true" else "false");
            },
            .strs => blk: {
                w.raw("[") catch return error.OutOfMemory;
                for (try it.list(v), 0..) |e, n| {
                    if (n > 0) w.raw(",") catch return error.OutOfMemory;
                    w.str(try it.str(e), 4096) catch return error.OutOfMemory;
                }
                break :blk w.raw("]");
            },
            .sdict => blk: {
                const sub = try it.list(v);
                if (sub.len % 2 != 0) return it.fail("audit: {s} is not a dict", .{k});
                w.raw("{") catch return error.OutOfMemory;
                var j: usize = 0;
                while (j < sub.len) : (j += 2) {
                    w.key(try it.str(sub[j])) catch return error.OutOfMemory;
                    w.str(try it.str(sub[j + 1]), 2000) catch return error.OutOfMemory;
                }
                break :blk w.raw("}");
            },
            .json => blk: {
                const s = try it.str(v);
                if (!validJson(it.alloc(), s)) return it.fail("audit: {s} is not JSON", .{k});
                break :blk w.raw(s);
            },
        }) catch return error.OutOfMemory;
    }
    w.raw("}") catch return error.OutOfMemory;
}

fn validJson(a: std.mem.Allocator, s: []const u8) bool {
    if (std.mem.indexOfAny(u8, s, "\r\n") != null) return false;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    _ = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), s, .{}) catch return false;
    return true;
}

/// A Tcl value of a JSON value: an object is a dict, an array a list,
/// null the empty string, and a boolean `true` or `false`.
fn tclOf(a: std.mem.Allocator, v: std.json.Value) !ztcl.Value {
    return switch (v) {
        .null => .empty,
        .bool => |b| .{ .str = if (b) "true" else "false" },
        .integer => |n| .{ .int = n },
        .float => |f| .{ .double = f },
        .number_string, .string => |s| .{ .str = try a.dupe(u8, s) },
        .array => |arr| blk: {
            const items = try a.alloc(ztcl.Value, arr.items.len);
            for (arr.items, 0..) |e, i| items[i] = try tclOf(a, e);
            break :blk ztcl.value.newList(a, items);
        },
        .object => |o| blk: {
            const items = try a.alloc(ztcl.Value, o.count() * 2);
            var i: usize = 0;
            var iter = o.iterator();
            while (iter.next()) |kv| : (i += 2) {
                items[i] = .{ .str = try a.dupe(u8, kv.key_ptr.*) };
                items[i + 1] = try tclOf(a, kv.value_ptr.*);
            }
            break :blk ztcl.value.newList(a, items);
        },
    };
}

var the_log: ?Log = null;
var session_count: u32 = 0;
var the_dir: [:0]const u8 = "";

/// Closes the log of `register`, for the next test.
pub fn reset() void {
    if (the_log) |*l| l.close();
    the_log = null;
}

/// Sets the folder of the log. The files open at the first use.
pub fn register(it: *ztcl.Interp, dir: [:0]const u8) !void {
    the_dir = dir;
    try it.register("dockyard::audit", cmdAudit);
}

fn getLog(it: *ztcl.Interp) ztcl.Error!*Log {
    if (the_log == null) the_log = Log.open(std.heap.page_allocator, the_dir) catch
        return it.fail("audit: no log in {s}", .{the_dir});
    return &the_log.?;
}

fn cmdAudit(it: *ztcl.Interp, argv: []const ztcl.Value, _: ?*ztcl.interp.Cmd) ztcl.Error!ztcl.Value {
    const usage = "dockyard::audit log|json|session|context|query|count|last|verify|path ?arg ...?";
    if (argv.len < 2) return it.wrongArgs(usage);
    const sub = try it.str(argv[1]);
    const a = it.alloc();
    if (std.mem.eql(u8, sub, "path")) return .{ .str = the_dir };
    const l = try getLog(it);
    if (std.mem.eql(u8, sub, "log") or std.mem.eql(u8, sub, "json")) {
        if (argv.len < 4 or argv.len % 2 != 0) return it.wrongArgs("dockyard::audit log kind data ?-session id? ?-turn id? ?-call id? ?-source name? ?-time ms?");
        const kind = try it.str(argv[2]);
        if (indexOf(&kinds, kind) == null) return it.fail("audit: bad kind \"{s}\"", .{kind});
        var session: []const u8 = l.session;
        var turn: ?[]const u8 = l.turn;
        var call: ?[]const u8 = null;
        var source: []const u8 = "app";
        var time: i64 = l.clock();
        var i: usize = 4;
        while (i < argv.len) : (i += 2) {
            const o = try it.str(argv[i]);
            const v = try it.str(argv[i + 1]);
            if (std.mem.eql(u8, o, "-session")) session = v else if (std.mem.eql(u8, o, "-turn")) {
                turn = if (v.len == 0) null else v;
            } else if (std.mem.eql(u8, o, "-call")) {
                call = if (v.len == 0) null else v;
            } else if (std.mem.eql(u8, o, "-source")) {
                if (indexOf(&sources, v) == null) return it.fail("audit: bad source \"{s}\"", .{v});
                source = v;
            } else if (std.mem.eql(u8, o, "-time")) {
                time = try it.int(argv[i + 1]);
            } else return it.fail("audit: bad option \"{s}\"", .{o});
        }
        var w: Line = .{ .a = a };
        if (sub[0] == 'l') {
            try dataOfDict(it, &w, argv[3]);
        } else {
            const s = try it.str(argv[3]);
            if (!validJson(a, s) or s.len == 0 or s[0] != '{') return it.fail("audit: the data is not a JSON object: {s}", .{s});
            w.raw(s) catch return error.OutOfMemory;
        }
        const seq = l.append(kind, source, w.buf.items, session, turn, call, time) catch |e|
            return it.fail("audit: no write to {s}: {s}", .{ the_dir, @errorName(e) });
        return .{ .int = @intCast(seq) };
    }
    if (std.mem.eql(u8, sub, "session")) {
        // A new session id: the time in ms, the process id, and a count,
        // in hex. The next records have it, with no turn.
        session_count += 1;
        l.session = std.fmt.allocPrint(std.heap.page_allocator, "{x}-{x}-{x}", .{ l.clock(), @as(u32, @bitCast(c.getpid())), session_count }) catch return error.OutOfMemory;
        l.turn = null;
        return .{ .str = try a.dupe(u8, l.session) };
    }
    if (std.mem.eql(u8, sub, "context")) {
        var i: usize = 2;
        while (i + 1 < argv.len) : (i += 2) {
            const o = try it.str(argv[i]);
            const v = try it.str(argv[i + 1]);
            if (std.mem.eql(u8, o, "-session")) {
                l.session = try std.heap.page_allocator.dupe(u8, v);
            } else if (std.mem.eql(u8, o, "-turn")) {
                l.turn = if (v.len == 0) null else try std.heap.page_allocator.dupe(u8, v);
            } else return it.fail("audit: bad option \"{s}\"", .{o});
        }
        return ztcl.value.newList(a, &.{ .{ .str = "session" }, .{ .str = try a.dupe(u8, l.session) }, .{ .str = "turn" }, .{ .str = if (l.turn) |t| try a.dupe(u8, t) else "" } });
    }
    if (std.mem.eql(u8, sub, "query") or std.mem.eql(u8, sub, "count")) {
        var f: Log.Filter = .{};
        var limit: usize = std.math.maxInt(usize);
        var last = false;
        var json = false;
        var i: usize = 2;
        if ((argv.len - 2) % 2 != 0) return it.wrongArgs("dockyard::audit query ?-option value ...?");
        while (i < argv.len) : (i += 2) {
            const o = try it.str(argv[i]);
            const v = argv[i + 1];
            if (std.mem.eql(u8, o, "-kind")) {
                f.kinds = 0;
                for (try it.list(v)) |k| {
                    const n = indexOf(&kinds, try it.str(k)) orelse return it.fail("audit: bad kind \"{s}\"", .{try it.str(k)});
                    f.kinds |= @as(u16, 1) << @intCast(n);
                }
            } else if (std.mem.eql(u8, o, "-source")) {
                f.sources = 0;
                for (try it.list(v)) |k| {
                    const n = indexOf(&sources, try it.str(k)) orelse return it.fail("audit: bad source \"{s}\"", .{try it.str(k)});
                    f.sources |= @as(u8, 1) << @intCast(n);
                }
            } else if (std.mem.eql(u8, o, "-session")) f.session = try it.str(v) else if (std.mem.eql(u8, o, "-turn")) {
                f.turn = try it.str(v);
            } else if (std.mem.eql(u8, o, "-call")) f.call = try it.str(v) else if (std.mem.eql(u8, o, "-since")) {
                f.since = try it.int(v);
            } else if (std.mem.eql(u8, o, "-until")) f.until = try it.int(v) else if (std.mem.eql(u8, o, "-after")) {
                f.after = @intCast(@max(0, try it.int(v)));
            } else if (std.mem.eql(u8, o, "-before")) f.before = @intCast(@max(0, try it.int(v))) else if (std.mem.eql(u8, o, "-text")) {
                f.text = try it.str(v);
            } else if (std.mem.eql(u8, o, "-limit") or std.mem.eql(u8, o, "-last")) {
                limit = @intCast(@max(0, try it.int(v)));
                last = o[1] == 'l' and o[2] == 'a';
            } else if (std.mem.eql(u8, o, "-format")) {
                const s = try it.str(v);
                if (std.mem.eql(u8, s, "json")) json = true else if (!std.mem.eql(u8, s, "dict")) return it.fail("audit: -format is dict or json", .{});
            } else return it.fail("audit: bad option \"{s}\"", .{o});
        }
        const found = l.query(a, f, limit, last) catch return error.OutOfMemory;
        if (sub[0] == 'c') return .{ .int = @intCast(found.len) };
        const items = try a.alloc(ztcl.Value, found.len);
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        for (found, 0..) |text, n| {
            if (json) {
                items[n] = .{ .str = try a.dupe(u8, text) };
                continue;
            }
            const v = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), text, .{}) catch {
                items[n] = .empty;
                continue;
            };
            items[n] = try tclOf(a, v);
        }
        return ztcl.value.newList(a, items);
    }
    if (std.mem.eql(u8, sub, "last")) return .{ .int = @intCast(l.lastSeq()) };
    if (std.mem.eql(u8, sub, "verify")) {
        const r = l.verify(null) catch return error.OutOfMemory;
        return ztcl.value.newList(a, &.{
            .{ .str = "ok" },      .{ .int = @intFromBool(r.ok) },
            .{ .str = "records" }, .{ .int = @intCast(r.records) },
            .{ .str = "last" },    .{ .str = try a.dupe(u8, &r.last) },
            .{ .str = "bad" },     .{ .int = @intCast(r.bad) },
            .{ .str = "reason" },  .{ .str = r.reason },
        });
    }
    return it.fail("bad option \"{s}\": must be log, json, session, context, query, count, last, verify, or path", .{sub});
}

/// `dockyard --audit-export PROJECT`: the records as JSON lines on fd
/// 1, then a note with the result of the chain check. Gives false when
/// the chain is broken.
pub fn exportTo(a: std.mem.Allocator, dir: [:0]const u8, fd: c.fd_t) !bool {
    var l = try Log.open(a, dir);
    defer l.close();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const r = try l.verify(&out);
    var w: Line = .{ .a = a };
    defer w.buf.deinit(a);
    if (r.ok) {
        try w.print("{{\"kind\":\"note\",\"data\":{{\"text\":\"chain ok\",\"records\":{d},\"last\":\"{s}\"}}}}\n", .{ r.records, r.last });
    } else {
        try w.print("{{\"kind\":\"note\",\"data\":{{\"text\":\"chain broken\",\"records\":{d},\"bad\":{d},\"reason\":\"{s}\"}}}}\n", .{ r.records, r.bad, r.reason });
    }
    try out.appendSlice(a, w.buf.items);
    var at: usize = 0;
    while (at < out.items.len) {
        const n = c.write(fd, out.items[at..].ptr, out.items.len - at);
        if (n <= 0) return error.WriteFailed;
        at += @intCast(n);
    }
    return r.ok;
}

var test_now: i64 = 1000;
fn testClock() i64 {
    test_now += 1;
    return test_now;
}

fn testDir(buf: []u8, name: []const u8) ![:0]const u8 {
    const t = std.c.getenv("TMPDIR");
    const base = if (t) |p| std.mem.sliceTo(p, 0) else "/tmp";
    const d = try std.fmt.bufPrintSentinel(buf, "{s}/dockyard-test-audit-{s}-{d}", .{ base, name, c.getpid() }, 0);
    rmDir(d);
    return d;
}

/// Removes the files of a test log and its folder.
fn rmDir(d: [:0]const u8) void {
    var p: [600]u8 = undefined;
    _ = c.unlink((std.fmt.bufPrintSentinel(&p, "{s}/index", .{d}, 0) catch return).ptr);
    var n: u32 = 1;
    while (n < 20) : (n += 1) _ = c.unlink((std.fmt.bufPrintSentinel(&p, "{s}/log-{d:0>6}.jsonl", .{ d, n }, 0) catch return).ptr);
    _ = c.rmdir(d.ptr);
}

test "the audit log chains, indexes, and filters the records" {
    if (comptime on_win) return error.SkipZigTest;
    reset();
    var it: ztcl.Interp = undefined;
    try it.init(std.heap.page_allocator);
    defer it.deinit();
    var buf: [512]u8 = undefined;
    const dir = try testDir(&buf, "tcl");
    defer rmDir(dir);
    try register(&it, dir);
    defer {
        the_log.?.close();
        the_log = null;
    }
    (try getLog(&it)).clock = testClock;
    _ = try it.eval("dockyard::audit context -session s1");
    _ = try it.eval("dockyard::audit log session {op start sandbox 1 argv {claude --x} project /p}");
    _ = try it.eval("dockyard::audit log turn {op start prompt {make it \"blue\"}} -source hook -turn s1.1");
    _ = try it.eval("dockyard::audit context -turn s1.1");
    _ = try it.eval("dockyard::audit log tool {op start tool Bash input {command {ls -l}}} -source hook -call c1");
    _ = try it.eval("dockyard::audit log exec {pid 7 ppid 1 argv {/bin/ls -l} cwd /work} -source helper");
    _ = it.eval("dockyard::audit json net {{\"host\":\"evil.example\",\"port\":443,\"result\":\"blocked\"}} -source proxy") catch |e| {
        std.debug.print("{s}\n", .{try it.str(it.result)});
        return e;
    };
    _ = try it.eval("dockyard::audit log file {op write path /work/a.tcl before {} after ab12} -source watch -session s2");
    try std.testing.expectError(error.TclError, it.eval("dockyard::audit log exec {pid seven}"));
    try std.testing.expectError(error.TclError, it.eval("dockyard::audit log bogus {}"));
    try std.testing.expectError(error.TclError, it.eval("dockyard::audit json note {not json}"));
    const T = struct {
        fn s(i: *ztcl.Interp, script: []const u8) ![]const u8 {
            return i.str(try i.eval(script));
        }
    };
    try std.testing.expectEqualStrings("6", try T.s(&it, "dockyard::audit last"));
    try std.testing.expectEqualStrings("6", try T.s(&it, "dockyard::audit count"));
    try std.testing.expectEqualStrings("5", try T.s(&it, "dockyard::audit count -turn s1.1"));
    try std.testing.expectEqualStrings("1", try T.s(&it, "dockyard::audit count -session s2"));
    try std.testing.expectEqualStrings("2", try T.s(&it, "dockyard::audit count -kind {exec net}"));
    try std.testing.expectEqualStrings("1", try T.s(&it, "dockyard::audit count -text EVIL"));
    try std.testing.expectEqualStrings("1", try T.s(&it, "dockyard::audit count -call c1"));
    try std.testing.expectEqualStrings("2", try T.s(&it, "dockyard::audit count -source hook"));
    try std.testing.expectEqualStrings("4 5 6", try T.s(&it, "lmap r [dockyard::audit query -after 3] {dict get $r seq}"));
    try std.testing.expectEqualStrings("5 6", try T.s(&it, "lmap r [dockyard::audit query -last 2] {dict get $r seq}"));
    try std.testing.expectEqualStrings("1 2", try T.s(&it, "lmap r [dockyard::audit query -limit 2] {dict get $r seq}"));
    try std.testing.expectEqualStrings("3", try T.s(&it, "lmap r [dockyard::audit query -since 1003 -until 1003] {dict get $r seq}"));
    // The types of the data fields.
    try std.testing.expectEqualStrings("true {claude --x} 7 {ls -l} {make it \"blue\"} {}", try T.s(&it,
        \\set q [dockyard::audit query]
        \\list [dict get [lindex $q 0] data sandbox] [dict get [lindex $q 0] data argv] [dict get [lindex $q 3] data pid] \
        \\    [dict get [lindex $q 2] data input command] [dict get [lindex $q 1] data prompt] [dict get [lindex $q 5] data before]
    ));
    const line = try T.s(&it, "lindex [dockyard::audit query -kind exec -format json] 0");
    try std.testing.expect(std.mem.indexOf(u8, line, "\"pid\":7,\"ppid\":1,\"argv\":[\"/bin/ls\",\"-l\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"session\":\"s1\",\"turn\":\"s1.1\",\"call\":null,\"source\":\"helper\"") != null);
    try std.testing.expectEqualStrings("1 6", try T.s(&it, "set v [dockyard::audit verify]; list [dict get $v ok] [dict get $v records]"));
    // audit.tcl makes the records of the events of the window, and the
    // terminal view of monitor.tcl gives each record a line.
    try it.allow(@backingInt(ztcl.interp.Capability.event) | @backingInt(ztcl.interp.Capability.clock));
    it.event_host = .{ .now = testTicks, .sleep = testSleep };
    _ = try it.eval("set ::dockyard::project /p; set ::dockyard::tui 1");
    _ = try it.eval(@embedFile("audit.tcl"));
    _ = it.eval(
        \\::dockyard::audit::start 1 {claude}
        \\::dockyard::audit::guest hook {event UserPromptSubmit time 5000 prompt {add a button} session abc}
        \\::dockyard::audit::guest hook {event PreToolUse time 5001 tool Edit path /work/a.tcl}
        \\::dockyard::audit::guest exec {time 5002 pid 9 ppid 1 argv {/bin/ls}}
        \\::dockyard::audit::net {time 5003 host evil.example port 443 result blocked up 0 down 0 ms 0}
        \\::dockyard::audit::change {modified /a.tcl}
        \\::dockyard::audit::guest hook {event Stop time 5004}
        \\::dockyard::audit::end 0
    ) catch |e| {
        std.debug.print("{s}\n", .{try it.str(it.result)});
        return e;
    };
    try std.testing.expectEqualStrings("session turn tool exec net blocked file turn session", try T.s(&it, "lmap r [dockyard::audit query -after 6] {dict get $r kind}"));
    try std.testing.expectEqualStrings("7", try T.s(&it, "dockyard::audit count -after 6 -turn [dict get [dockyard::audit context] session].1"));
    _ = try it.eval(@embedFile("monitor.tcl"));
    const r = try T.s(&it,
        \\set q [dockyard::audit query -after 6]
        \\list [lindex [::dockyard::monitor::describe [lindex $q 4]] 1] [string match "*tool  start Edit  /work/a.tcl" [lindex [::dockyard::monitor::describe [lindex $q 2]] 0]] \
        \\    [string match "*exec  9  /bin/ls" [lindex [::dockyard::monitor::describe [lindex $q 3]] 0]] [string match "*file  write /a.tcl" [lindex [::dockyard::monitor::describe [lindex $q 6]] 0]]
    );
    try std.testing.expectEqualStrings("blocked 1 1 1", r);
}

fn testTicks(_: ?*anyopaque) i64 {
    return 0;
}

fn testSleep(_: ?*anyopaque, _: i64) void {}

test "the audit log finds a change of a record and repairs a crash" {
    if (comptime on_win) return error.SkipZigTest;
    const a = std.testing.allocator;
    var buf: [512]u8 = undefined;
    const dir = try testDir(&buf, "chain");
    defer rmDir(dir);
    const saved = max_file;
    defer max_file = saved;
    max_file = 600;
    var l = try Log.open(a, dir);
    defer {
        a.free(l.dir);
        l.close();
    }
    var i: u64 = 0;
    while (i < 6) : (i += 1) _ = try l.append("note", "app", "{\"text\":\"a note of about one hundred bytes, so the log has more than one file\"}", "s", null, null, @intCast(i));
    // Two records fit in a file of 600 bytes.
    var p2: [600]u8 = undefined;
    const f2 = try std.fmt.bufPrintSentinel(&p2, "{s}/log-000002.jsonl", .{dir}, 0);
    try std.testing.expectEqual(@as(c_int, 0), c.access(f2.ptr, 0));
    var r = try l.verify(null);
    if (!r.ok) {
        std.debug.print("bad {d}: {s}\n", .{ r.bad, r.reason });
        var pn: u32 = 1;
        while (pn < 4) : (pn += 1) {
            const pp = try l.path("", pn);
            if (map(pp)) |m| std.debug.print("--- {d}\n{s}\n", .{ pn, m });
        }
    }
    try std.testing.expect(r.ok);
    try std.testing.expectEqual(@as(u64, 6), r.records);
    // A crash after the line and before the entry: the next append
    // indexes the line.
    const h = l.readHeader();
    try std.testing.expectEqual(@as(u32, 3), h.file);
    var p3: [600]u8 = undefined;
    const f3 = try std.fmt.bufPrintSentinel(&p3, "{s}/log-000003.jsonl", .{dir}, 0);
    const fd = c.open(f3.ptr, .{ .ACCMODE = .WRONLY, .APPEND = true }, @as(c.mode_t, 0));
    var w: Line = .{ .a = a };
    defer w.buf.deinit(a);
    try w.print("{{\"v\":1,\"seq\":7,\"time\":9,\"kind\":\"note\",\"session\":\"s\",\"turn\":null,\"call\":null,\"source\":\"app\",\"data\":{{}},\"prev\":\"{s}\"}}\n{{\"v\":1,\"se", .{h.hash});
    _ = c.write(fd, w.buf.items.ptr, w.buf.items.len);
    _ = c.close(fd);
    _ = try l.append("note", "app", "{}", "s", null, null, 10);
    r = try l.verify(null);
    if (!r.ok) std.debug.print("bad {d}: {s}\n", .{ r.bad, r.reason });
    try std.testing.expect(r.ok);
    // 6 records, the record of the crash, the note of the cut, and the new record.
    try std.testing.expectEqual(@as(u64, 9), r.records);
    const found = try l.query(a, .{ .text = "partial record" }, 10, false);
    defer a.free(found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    // A change of one byte of an old record breaks the chain.
    var p1: [600]u8 = undefined;
    const f1 = try std.fmt.bufPrintSentinel(&p1, "{s}/log-000001.jsonl", .{dir}, 0);
    const fd1 = c.open(f1.ptr, .{ .ACCMODE = .WRONLY }, @as(c.mode_t, 0));
    _ = c.pwrite(fd1, "2", 1, 20);
    _ = c.close(fd1);
    r = try l.verify(null);
    try std.testing.expect(!r.ok);
    try std.testing.expectEqual(@as(u64, 1), r.bad);
}
