const std = @import("std");
const helpers = @import("helpers.zig");
const log = @import("log.zig");
const user_agent = @import("user_agent.zig");

pub const ProgressFnType = fn (handle: ?*DebuginfodContext, current: c_long, total: c_long) callconv(.c) c_int;

// Default negative-cache TTL (seconds), matching elfutils' cache_miss_default_s.
const cache_miss_default_s: u64 = 600;

pub const DebuginfodEnvs = struct {
    // required
    urls: [][]const u8 = &.{},
    cache_path: []const u8 = &.{},
    user_agent: []const u8 = &.{},

    // optional
    fetch_timeout: ?usize = 90,
    fetch_maxsize: ?usize = null,
    fetch_maxtime: ?usize = null,
    fetch_retry_limit: usize = 2,
    fetch_progress_to_stderr: bool = false,
    fetch_headers: ?[]const std.http.Header = null,

    // Resolved http(s) proxy URLs from the standard env vars (precedence
    // handled once here so `fetch` doesn't re-scan the environment).
    http_proxy: ?[]const u8 = null,
    https_proxy: ?[]const u8 = null,

    // Negative-cache TTL in seconds: a not-found result is remembered (as an
    // empty marker file) for this long before the server is queried again.
    // Mirrors elfutils' cache_miss_s; read from `$cache/cache_miss_s` if present.
    cache_miss_s: u64 = cache_miss_default_s,

    fn init(self: *DebuginfodEnvs, allocator: std.mem.Allocator, io: std.Io, penvs: std.process.Environ.Map) !void {
        self.urls = try getUrls(allocator, penvs);
        self.cache_path = try getCachePath(allocator, penvs);
        self.user_agent = try user_agent.getUserAgent(allocator, io);
        self.fetch_headers = try getHeadersFromFile(allocator, io, penvs);
        self.http_proxy = try getProxy(allocator, penvs, &.{ "http_proxy", "HTTP_PROXY", "all_proxy", "ALL_PROXY" });
        self.https_proxy = try getProxy(allocator, penvs, &.{ "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY" });
        self.cache_miss_s = getCacheMissS(allocator, io, self.cache_path);

        if (penvs.get("DEBUGINFOD_TIMEOUT")) |val| {
            const d = try std.fmt.parseInt(isize, val, 10);
            self.fetch_timeout = if (d <= 0) null else @intCast(d);
        }
        if (penvs.get("DEBUGINFOD_MAXTIME")) |val| {
            const d = try std.fmt.parseInt(usize, val, 10);
            self.fetch_maxtime = if (d == 0) null else d;
        }
        if (penvs.get("DEBUGINFOD_MAXSIZE")) |val| {
            const d = try std.fmt.parseInt(usize, val, 10);
            self.fetch_maxsize = if (d == 0) null else d;
        }
        if (penvs.get("DEBUGINFOD_RETRY_LIMIT")) |val| {
            self.fetch_retry_limit = try std.fmt.parseInt(usize, val, 10);
        }
        if (penvs.get("DEBUGINFOD_PROGRESS") != null) {
            self.fetch_progress_to_stderr = true;
        }
    }

    pub fn deinit(self: *DebuginfodEnvs, allocator: std.mem.Allocator) void {
        for (self.urls) |url| {
            allocator.free(url);
        }
        allocator.free(self.urls);
        allocator.free(self.cache_path);
        allocator.free(self.user_agent);
        if (self.fetch_headers) |items| {
            for (items) |item| {
                allocator.free(item.name);
                allocator.free(item.value);
            }
            allocator.free(items);
        }
        if (self.http_proxy) |val| allocator.free(val);
        if (self.https_proxy) |val| allocator.free(val);
        self.* = undefined;
    }

    fn getProxy(allocator: std.mem.Allocator, penvs: std.process.Environ.Map, env_var_names: []const []const u8) !?[]const u8 {
        for (env_var_names) |name| {
            const val = penvs.get(name) orelse continue;
            if (val.len == 0) continue;
            return try allocator.dupe(u8, val);
        }
        return null;
    }

    // Read `$cache/cache_miss_s` if present (so users can tune it like elfutils),
    // otherwise fall back to the default. Never fails: any error -> default.
    // Unlike elfutils we do not auto-create the file.
    fn getCacheMissS(allocator: std.mem.Allocator, io: std.Io, cache_path: []const u8) u64 {
        const path = std.fs.path.join(allocator, &.{ cache_path, "cache_miss_s" }) catch return cache_miss_default_s;
        defer allocator.free(path);
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64)) catch return cache_miss_default_s;
        defer allocator.free(data);
        return std.fmt.parseInt(u64, std.mem.trim(u8, data, " \t\r\n"), 10) catch cache_miss_default_s;
    }

    fn getHeadersFromFile(allocator: std.mem.Allocator, io: std.Io, penvs: std.process.Environ.Map) !?[]const std.http.Header {
        const headers_file = penvs.get("DEBUGINFOD_HEADERS_FILE") orelse {
            return null;
        };
        var file = std.Io.Dir.cwd().openFile(io, headers_file, .{}) catch |err| {
            log.warn("getHeadersFromFile openFile,err: {}", .{err});
            return null;
        };
        defer file.close(io);

        var buf: [8192]u8 = undefined;
        var reader = file.reader(io, &buf);
        var list = try std.ArrayList(std.http.Header).initCapacity(allocator, 0);

        while (true) {
            const line = reader.interface.takeDelimiter('\n') catch |err| {
                log.warn("getHeadersFromFile takeDelimiter,err: {}", .{err});
                break;
            } orelse {
                break;
            };

            const header_trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (header_trimmed.len == 0) continue;

            const colon_idx = std.mem.indexOf(u8, header_trimmed, ": ") orelse {
                log.warn("getHeadersFromFile invalid header: '{s}'", .{header_trimmed});
                continue;
            };

            const header = std.http.Header{
                .name = try allocator.dupe(u8, header_trimmed[0..colon_idx]),
                .value = try allocator.dupe(u8, header_trimmed[colon_idx + 2 ..]),
            };
            try list.append(allocator, header);
        }
        return try list.toOwnedSlice(allocator);
    }

    // fn getImaCert(allocator: std.mem.Allocator, penvs: std.process.Environ.Map) !void {
    //     _ = allocator;
    //     // const env8 = penvs.get("DEBUGINFOD_IMA_CERT_PATH");
    //     // TODO: implement
    // }

    fn getUrls(allocator: std.mem.Allocator, penvs: std.process.Environ.Map) ![][]const u8 {
        var list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
        if (penvs.get("DEBUGINFOD_URLS")) |val| {
            // Split by spaces
            var it = std.mem.tokenizeAny(u8, val, " ");
            while (it.next()) |url| {
                if (url.len == 0) continue;

                // allow only http:// and https:// urls
                if (!(std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://"))) {
                    continue;
                }

                try list.append(allocator, try allocator.dupe(u8, url));
            }
        }
        return try list.toOwnedSlice(allocator);
    }

    fn getCachePath(allocator: std.mem.Allocator, penvs: std.process.Environ.Map) ![]const u8 {
        if (penvs.get("DEBUGINFOD_CACHE_PATH")) |cache_path| {
            return try std.fs.path.join(allocator, &.{cache_path});
        }
        if (penvs.get("XDG_CACHE_HOME")) |cache_path| {
            return try std.fs.path.join(allocator, &.{ cache_path, "debuginfod_client" });
        }
        if (penvs.get("HOME")) |cache_path| {
            return try std.fs.path.join(allocator, &.{ cache_path, ".cache", "debuginfod_client" });
        }

        log.warn("getCachePath erro, envs DEBUGINFOD_CACHE_PATH,XDG_CACHE_HOME,HOME any of them must be not empty", .{});
        return error.EmptyCachePathEnv;
    }
};

test "DebuginfodEnvs" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var penvs = try helpers.getEnvMap(allocator);
    defer penvs.deinit();

    try penvs.put("DEBUGINFOD_URLS", "invalidfoo https://test1.com http://test2.com invalidbar");

    var denvs = DebuginfodEnvs{};
    try denvs.init(allocator, io, penvs);
    defer denvs.deinit(allocator);

    try std.testing.expect(denvs.urls.len == 2);
    try std.testing.expectEqualStrings("https://test1.com", denvs.urls[0]);
    try std.testing.expectEqualStrings("http://test2.com", denvs.urls[1]);
}

pub const DebuginfodResponeHeaders = struct {
    size: ?usize = null,
    archive: ?[]const u8 = null,
    file: ?[]const u8 = null,
    imasignature: ?[]const u8 = null,

    allocator: ?std.mem.Allocator = null,
    _buffer: ?[:0]u8 = null,

    fn parseHeaders(it: *std.http.HeaderIterator) !DebuginfodResponeHeaders {
        var out: DebuginfodResponeHeaders = .{};
        while (it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "x-debuginfod-size")) {
                out.size = try std.fmt.parseInt(usize, header.value, 10);
            } else if (std.ascii.eqlIgnoreCase(header.name, "x-debuginfod-archive")) {
                out.archive = header.value;
            } else if (std.ascii.eqlIgnoreCase(header.name, "x-debuginfod-file")) {
                out.file = header.value;
            } else if (std.ascii.eqlIgnoreCase(header.name, "x-debuginfod-imasignature")) {
                out.imasignature = header.value;
            }
        }
        return out;
    }

    pub fn deinit(self: *DebuginfodResponeHeaders) void {
        const allocator = self.allocator orelse return;
        if (self._buffer) |buf| {
            allocator.free(buf);
        }
        self._buffer = null;
    }

    pub fn toBinding(self: *DebuginfodResponeHeaders) ![:0]u8 {
        const allocator = self.allocator orelse return error.AllocatorIsNotAssigned;
        if (self._buffer) |buf| {
            return buf;
        }

        var list = try std.ArrayList(u8).initCapacity(allocator, 0);
        if (self.size) |val| {
            try list.print(allocator, "x-debuginfod-size: {d}\n", .{val});
        }
        if (self.archive) |val| {
            try list.print(allocator, "x-debuginfod-archive: {s}\n", .{val});
        }
        if (self.file) |val| {
            try list.print(allocator, "x-debuginfod-file: {s}\n", .{val});
        }
        if (self.imasignature) |val| {
            try list.print(allocator, "x-debuginfod-imasignature: {s}\n", .{val});
        }
        if (list.items.len == 0) {
            return error.NoHeaders;
        }
        const output = try list.toOwnedSliceSentinel(allocator, 0);
        self._buffer = output;
        return output;
    }
};

pub const DebuginfodContext = struct {
    allocator: std.mem.Allocator,
    // Owned, long-lived Io for this context. Its address must be stable, which
    // it is because the context is heap-allocated.
    threaded: std.Io.Threaded,
    current_request_headers: std.array_list.Aligned(std.http.Header, null),

    envs: DebuginfodEnvs = .{},
    progress_fn: ?*ProgressFnType = null,

    // start variables safe accessable only in `onFetchProgress`
    current_userdata: ?*anyopaque = null,
    current_url: ?[:0]const u8 = null,
    current_response_headers: ?*DebuginfodResponeHeaders = null,
    // end variables safe accessable only in `onFetchProgress`

    pub fn getIo(self: *DebuginfodContext) std.Io {
        return self.threaded.io();
    }

    pub fn init(allocator: std.mem.Allocator, penvs: std.process.Environ.Map) !*DebuginfodContext {
        const ctx = try allocator.create(DebuginfodContext);
        errdefer allocator.destroy(ctx);

        ctx.* = .{
            .allocator = allocator,
            .threaded = .init(allocator, .{}),
            .current_request_headers = try std.ArrayList(std.http.Header).initCapacity(allocator, 0),
        };
        errdefer ctx.threaded.deinit();

        try ctx.envs.init(allocator, ctx.getIo(), penvs);

        if (ctx.envs.fetch_headers) |headers| {
            for (headers) |header| {
                try ctx.addRequestHeader(header);
            }
        }
        return ctx;
    }

    pub fn deinit(self: *DebuginfodContext) void {
        const allocator = self.allocator;
        self.envs.deinit(allocator);

        for (self.current_request_headers.items) |item| {
            allocator.free(item.name);
            allocator.free(item.value);
        }
        self.current_request_headers.deinit(allocator);

        self.threaded.deinit();
        allocator.destroy(self);
    }

    pub fn addRequestHeader(self: *DebuginfodContext, header: std.http.Header) !void {
        const name = try self.allocator.dupe(u8, header.name);
        errdefer self.allocator.free(name);
        const value = try self.allocator.dupe(u8, header.value);
        errdefer self.allocator.free(value);

        try self.current_request_headers.append(self.allocator, .{
            .name = name,
            .value = value,
        });
    }

    const CacheState = enum { hit, miss };

    // A 0-byte marker still suppresses queries while younger than cache_miss_s.
    // mtime may be in the future on clock skew -> negative age -> treated fresh.
    fn isFreshNegative(self: *DebuginfodContext, mtime: std.Io.Timestamp) bool {
        const now = std.Io.Clock.now(.real, self.getIo());
        const age_ns = mtime.durationTo(now).nanoseconds;
        return age_ns <= @as(i96, self.envs.cache_miss_s) * std.time.ns_per_s;
    }

    // True if `path` is a fresh 0-byte negative marker. Read-only (does not
    // delete stale markers, unlike `checkCache`).
    fn freshNegativeMarkerAt(self: *DebuginfodContext, path: []const u8) bool {
        const st = std.Io.Dir.cwd().statFile(self.getIo(), path, .{}) catch return false;
        return st.kind == .file and st.size == 0 and self.isFreshNegative(st.mtime);
    }

    // Inspect the cache entry for `local_path`:
    //   - non-empty file        -> .hit (use it)
    //   - empty marker, fresh    -> error.FetchStatusNotFound (negative-cache hit, no network)
    //   - empty marker, stale    -> delete it, .miss (re-query)
    //   - missing                -> .miss (query)
    // Mirrors elfutils' size==0 negative-cache scheme.
    fn checkCache(self: *DebuginfodContext, local_path: []const u8) !CacheState {
        const io = self.getIo();
        const st = std.Io.Dir.cwd().statFile(io, local_path, .{}) catch return .miss;
        if (st.kind != .file) return .miss;
        if (st.size != 0) return .hit;
        if (self.isFreshNegative(st.mtime)) return error.FetchStatusNotFound;
        std.Io.Dir.deleteFileAbsolute(io, local_path) catch {};
        return .miss;
    }

    pub fn findDebuginfo(self: *DebuginfodContext, build_id: []const u8) ![]u8 {
        log.info("findDebuginfo {s}", .{build_id});

        const local_path = try std.fs.path.join(self.allocator, &.{ self.envs.cache_path, build_id, "debuginfo" });
        errdefer self.allocator.free(local_path); // caller must free

        switch (try self.checkCache(local_path)) {
            .hit => return local_path,
            .miss => {},
        }

        const url_path = try std.fmt.allocPrint(self.allocator, "/buildid/{s}/debuginfo", .{build_id});
        defer self.allocator.free(url_path);

        try self.fetchFullOptions(url_path, local_path);
        return local_path;
    }

    pub fn findExecutable(self: *DebuginfodContext, build_id: []const u8) ![]u8 {
        log.info("findExecutable {s}", .{build_id});

        const local_path = try std.fs.path.join(self.allocator, &.{ self.envs.cache_path, build_id, "executable" });
        errdefer self.allocator.free(local_path); // caller must free

        switch (try self.checkCache(local_path)) {
            .hit => return local_path,
            .miss => {},
        }

        const url_path = try std.fmt.allocPrint(self.allocator, "/buildid/{s}/executable", .{build_id});
        defer self.allocator.free(url_path);

        try self.fetchFullOptions(url_path, local_path);
        return local_path;
    }

    pub fn findSource(self: *DebuginfodContext, build_id: []const u8, source_path: []const u8) ![]u8 {
        log.info("findSource {s} {s}", .{ build_id, source_path });

        const source_path_encoded = try helpers.urlencodePart(self.allocator, source_path);
        defer self.allocator.free(source_path_encoded);

        const source_path_escaped = try helpers.escapeFilename(self.allocator, source_path);
        defer self.allocator.free(source_path_escaped);

        const cache_part = try std.mem.concat(self.allocator, u8, &.{ "source-", source_path_escaped });
        defer self.allocator.free(cache_part);

        const local_path = try std.fs.path.join(self.allocator, &.{ self.envs.cache_path, build_id, cache_part });
        errdefer self.allocator.free(local_path); // caller must free

        switch (try self.checkCache(local_path)) {
            .hit => return local_path,
            .miss => {},
        }

        // build_id-level short-circuit (no per-file network): source can only
        // exist if debuginfo does, and a prior 501 means the whole build_id has
        // no source. Either marker (fresh) => skip the query entirely.
        if (self.sourceUnavailableForBuildId(build_id)) {
            return error.FetchStatusNotFound;
        }

        const url_path = try std.fmt.allocPrint(self.allocator, "/buildid/{s}/source/{s}", .{ build_id, source_path_encoded });
        defer self.allocator.free(url_path);

        self.fetchFullOptions(url_path, local_path) catch |err| {
            // 501 => this build_id doesn't serve source at all; remember that so
            // subsequent source files for it skip the network.
            if (err == error.FetchStatusNotImplemented) {
                self.markSourceUnsupported(build_id) catch {};
            }
            return err;
        };
        return local_path;
    }

    // Path of the build_id-level "source not supported" marker (set on a 501).
    fn sourceUnsupportedMarkerPath(self: *DebuginfodContext, build_id: []const u8) ![]u8 {
        return std.fs.path.join(self.allocator, &.{ self.envs.cache_path, build_id, "source-unsupported" });
    }

    // True if source is known-unavailable for this build_id: either debuginfo is
    // negatively cached (no debuginfo => no source) or a 501 marked source
    // unsupported. Read-only.
    fn sourceUnavailableForBuildId(self: *DebuginfodContext, build_id: []const u8) bool {
        const debuginfo_path = std.fs.path.join(self.allocator, &.{ self.envs.cache_path, build_id, "debuginfo" }) catch return false;
        defer self.allocator.free(debuginfo_path);
        if (self.freshNegativeMarkerAt(debuginfo_path)) return true;

        const su_path = self.sourceUnsupportedMarkerPath(build_id) catch return false;
        defer self.allocator.free(su_path);
        return self.freshNegativeMarkerAt(su_path);
    }

    // Write/refresh the build_id-level source-unsupported marker. Truncating
    // (not O_EXCL) so a stale marker's mtime is refreshed; safe because nothing
    // ever stores a real artifact at this path.
    fn markSourceUnsupported(self: *DebuginfodContext, build_id: []const u8) !void {
        const su_path = try self.sourceUnsupportedMarkerPath(build_id);
        defer self.allocator.free(su_path);

        const io = self.getIo();
        const dir = std.fs.path.dirname(su_path) orelse return error.InvalidLocalPath;
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        var file = try std.Io.Dir.createFileAbsolute(io, su_path, .{ .truncate = true });
        file.close(io);
    }

    pub fn findSection(self: *DebuginfodContext, build_id: []const u8, section: []const u8) ![]u8 {
        log.info("findSection {s} {s}", .{ build_id, section });

        const section_escaped = try helpers.escapeFilename(self.allocator, section);
        defer self.allocator.free(section_escaped);

        const cache_part = try std.mem.concat(self.allocator, u8, &.{ "section-", section_escaped });
        defer self.allocator.free(cache_part);

        const local_path = try std.fs.path.join(self.allocator, &.{ self.envs.cache_path, build_id, cache_part });
        errdefer self.allocator.free(local_path); // caller must free

        switch (try self.checkCache(local_path)) {
            .hit => return local_path,
            .miss => {},
        }

        const url_path = try std.fmt.allocPrint(self.allocator, "/buildid/{s}/section/{s}", .{ build_id, section });
        defer self.allocator.free(url_path);

        try self.fetchFullOptions(url_path, local_path);
        return local_path;
    }

    pub fn findSectionWithFallback(self: *DebuginfodContext, build_id: []const u8, section: []const u8) ![]u8 {
        // TODO: fallback to "findExecutable" + extract from elf, if server don't implement section?
        return try self.findSection(build_id, section);
    }

    fn getTempFilepath(allocator: std.mem.Allocator, local_path: []const u8) ![]u8 {
        const local_dirname = std.fs.path.dirname(local_path) orelse return error.InvalidLocalPath;
        // todo: security? random filename?
        const tmp_basename = try std.mem.concat(allocator, u8, &.{ ".tmp.", std.fs.path.basename(local_path) });
        defer allocator.free(tmp_basename);

        return try std.fs.path.join(allocator, &.{ local_dirname, tmp_basename });
    }

    fn fetchFullOptions(self: *DebuginfodContext, url_path: []const u8, local_path: []const u8) !void {
        var lastErr: anyerror = error.ErrorNotFound;

        for (self.envs.urls) |url| {
            const full_url = try std.mem.concatWithSentinel(self.allocator, u8, &.{ std.mem.cutSuffix(u8, url, "/") orelse url, url_path }, 0);
            defer self.allocator.free(full_url);

            self.fetchAsFile(full_url, local_path) catch |err| {
                lastErr = err;
                continue;
            };
            return;
        }

        // A clean 404 or 501 from the servers is cached as a per-file negative
        // marker so we don't re-query for the next `cache_miss_s` seconds.
        // 501 is surfaced as-is so findSource can additionally cache it at the
        // build_id level.
        if (lastErr == error.FetchStatusNotFound or lastErr == error.FetchStatusNotImplemented) {
            self.writeNegativeMarker(local_path) catch {};
        }

        return lastErr;
    }

    // Create the empty (0-byte) negative-cache marker file at `local_path`.
    // O_EXCL: if a concurrent task already created it (or a real download
    // landed), the error is ignored by the caller.
    fn writeNegativeMarker(self: *DebuginfodContext, local_path: []const u8) !void {
        const io = self.getIo();
        const local_dirname = std.fs.path.dirname(local_path) orelse return error.InvalidLocalPath;
        std.Io.Dir.cwd().createDirPath(io, local_dirname) catch {};
        var file = try std.Io.Dir.createFileAbsolute(io, local_path, .{ .exclusive = true });
        file.close(io);
    }

    fn fetchAsFile(self: *DebuginfodContext, url: [:0]const u8, local_path: []const u8) !void {
        self.current_url = url;
        defer self.current_url = null;

        const io = self.getIo();

        const local_dirname = std.fs.path.dirname(local_path) orelse return error.InvalidLocalPath;
        const local_path_tmp = try getTempFilepath(self.allocator, local_path);
        defer self.allocator.free(local_path_tmp);

        try std.Io.Dir.cwd().createDirPath(io, local_dirname);

        errdefer std.Io.Dir.deleteFileAbsolute(io, local_path_tmp) catch {};
        {
            var file = try std.Io.Dir.createFileAbsolute(io, local_path_tmp, .{
                .truncate = true,
            });
            defer file.close(io);

            var buffer: [64 * 1024]u8 = undefined;
            var writer = file.writer(io, &buffer);

            var writed_bytes: std.atomic.Value(usize) = .init(0);
            var total_bytes: std.atomic.Value(usize) = .init(0);
            var fetch_finished: std.atomic.Value(bool) = .init(false);

            var ffetch = try io.concurrent(DebuginfodContext.fetch, .{ self, io, url, &writer.interface, &writed_bytes, &total_bytes, &fetch_finished });
            defer ffetch.cancel(io) catch {};

            try self.loopProgress(io, url, &writed_bytes, &total_bytes, &fetch_finished);
            try ffetch.await(io);
        }

        try std.Io.Dir.renameAbsolute(local_path_tmp, local_path, io);
    }

    fn loopProgress(self: *DebuginfodContext, io: std.Io, url: [:0]const u8, writed_bytes: *std.atomic.Value(usize), total_bytes: *std.atomic.Value(usize), fetch_finished: *std.atomic.Value(bool)) anyerror!void {
        const show_progress_stderr = self.progress_fn == null and self.envs.fetch_progress_to_stderr;
        const fetch_start_at = std.Io.Clock.now(.awake, io);

        var progress: std.Progress.Node = undefined;
        var progress_count_one = false;
        if (show_progress_stderr) {
            progress = std.Progress.start(io, .{
                .root_name = url,
            });
        }
        defer if (show_progress_stderr) progress.end();

        while (!fetch_finished.load(.acquire)) {
            const current_writed_bytes = writed_bytes.load(.acquire);
            const current_total_bytes = total_bytes.load(.acquire);
            const loop_at = std.Io.Clock.now(.awake, io);
            const diff: u64 = @intCast(@divFloor(fetch_start_at.durationTo(loop_at).nanoseconds, std.time.ns_per_s));

            if (self.envs.fetch_timeout != null and current_writed_bytes < 100_000 and diff > self.envs.fetch_timeout.?) {
                return error.DownloadTimeoutExceed;
            }
            if (self.envs.fetch_maxsize != null and self.envs.fetch_maxsize.? < current_writed_bytes) {
                return error.DownloadMaxSizeExceed;
            }
            if (self.envs.fetch_maxtime != null and diff > self.envs.fetch_maxtime.?) {
                return error.DownloadMaxTimeExceed;
            }

            if (show_progress_stderr) {
                if (current_total_bytes > 0 and !progress_count_one) {
                    progress_count_one = true;
                    progress.increaseEstimatedTotalItems(current_total_bytes);
                }
                progress.setCompletedItems(current_writed_bytes);
            } else {
                try self.onFetchProgress(current_writed_bytes, current_total_bytes);
            }

            try io.sleep(.fromMilliseconds(100), .awake);
        }
    }

    fn fetch(self: *DebuginfodContext, io: std.Io, url: [:0]const u8, response_writer: *std.Io.Writer, writed_bytes: *std.atomic.Value(usize), total_bytes: *std.atomic.Value(usize), fetch_finished: *std.atomic.Value(bool)) anyerror!void {
        defer fetch_finished.store(true, .release);
        defer response_writer.flush() catch {};

        log.info("fetch {s}", .{url});

        var client = std.http.Client{
            .allocator = self.allocator,
            .io = io,
        };
        defer client.deinit();

        // Honor the standard http_proxy / https_proxy env vars (resolved once
        // in DebuginfodEnvs.init). no_proxy is not handled (std has no support
        // for it). The arena backs the parsed Proxy structs plus the small env
        // map that `initDefaultProxies` consumes; both only live for this request.
        if (self.envs.http_proxy != null or self.envs.https_proxy != null) {
            var proxy_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer proxy_arena.deinit();
            const arena = proxy_arena.allocator();

            var proxy_env = std.process.Environ.Map.init(arena);
            if (self.envs.http_proxy) |val| try proxy_env.put("http_proxy", val);
            if (self.envs.https_proxy) |val| try proxy_env.put("https_proxy", val);
            try client.initDefaultProxies(arena, &proxy_env);
        }

        const redirect_buffer: []u8 = try client.allocator.alloc(u8, 8 * 1024);
        defer client.allocator.free(redirect_buffer);

        var req = try client.request(.GET, try std.Uri.parse(url), .{
            .redirect_behavior = @enumFromInt(3),
            .keep_alive = true,
            .headers = .{
                .user_agent = .{
                    .override = self.envs.user_agent,
                },
            },
            .extra_headers = self.current_request_headers.items,
            .privileged_headers = &.{},
        });
        defer req.deinit();

        try req.sendBodiless();
        var response = try req.receiveHead(redirect_buffer);

        if (response.head.status == .not_found) {
            return error.FetchStatusNotFound;
        }
        // 501: server doesn't implement this artifact kind (e.g. no source). A
        // distinct error so `findSource` can cache it at the build_id level.
        if (response.head.status == .not_implemented) {
            return error.FetchStatusNotImplemented;
        }
        if (response.head.status != .ok) {
            return error.FetchStatusNotOk;
        }

        var it = response.head.iterateHeaders();
        var response_headers = try DebuginfodResponeHeaders.parseHeaders(&it);
        response_headers.allocator = self.allocator;
        defer response_headers.deinit();

        self.current_response_headers = &response_headers;
        defer self.current_response_headers = null;

        var file_size: usize = 0;
        if (response_headers.size) |size| {
            file_size = size;
        } else if (response.head.content_encoding == .identity and response.head.content_length != null) {
            file_size = @truncate(response.head.content_length.?);
        }
        total_bytes.store(file_size, .release);

        if (self.envs.fetch_maxsize != null and file_size > 0 and self.envs.fetch_maxsize.? < file_size) {
            return error.DownloadMaxSizeExceed;
        }

        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => try client.allocator.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try client.allocator.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };
        defer client.allocator.free(decompress_buffer);

        var transfer_buffer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

        while (true) {
            const current_writed_bytes = reader.stream(response_writer, .unlimited) catch |err| switch (err) {
                error.EndOfStream => break,
                else => |e| return e,
            };
            _ = writed_bytes.fetchAdd(current_writed_bytes, .release);
        }
    }

    fn onFetchProgress(self: *DebuginfodContext, current: usize, total: usize) !void {
        if (self.progress_fn) |callback| {
            const download_was_canceled = callback(self, @intCast(current), @intCast(total)) != 0;
            if (download_was_canceled) {
                return error.DownloadInterrupted;
            }
        }
    }
};

pub fn testStartServer(io: std.Io, file_blob: []const u8, queue: *std.Io.Queue(u16)) !void {
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var socket = try address.listen(io, .{});
    errdefer socket.deinit(io);
    try queue.putOne(io, socket.socket.address.getPort());

    defer socket.deinit(io);

    // handle only single conn
    while (true) {
        std.debug.print("wating in loop\n", .{});

        const conn = socket.accept(io) catch |err| {
            std.debug.print("Test HTTP Server accept error: {}\n", .{err});
            break;
        };
        std.debug.print("accepted in loop\n", .{});

        testHandleConnection(io, conn, file_blob) catch |err| switch (err) {
            error.HttpConnectionClosing => break,
            else => |e| return e,
        };
    }

    std.debug.print("exit http loop\n", .{});
}

fn testHandleConnection(io: std.Io, stream: std.Io.net.Stream, file_blob: []const u8) !void {
    defer stream.close(io);

    var req_buf: [2048]u8 = undefined;
    var conn_reader = stream.reader(io, &req_buf);
    var conn_writer = stream.writer(io, &req_buf);

    var http_server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);
    while (true) {
        std.debug.print("receiveHead start\n", .{});
        var req = http_server.receiveHead() catch |err| {
            std.debug.print("Test HTTP Server error: {}\n", .{err});
            return err;
        };
        std.debug.print("receiveHead end\n", .{});
        testHandleRequest(&req, file_blob) catch |err| {
            std.debug.print("test http error '{s}': {}\n", .{ req.head.target, err });
            req.respond("server error", .{ .status = .internal_server_error }) catch {};
            return err;
        };
    }
}

// Sentinel blob that makes the test server reply 501 (kind not implemented).
const test_blob_not_implemented = "\x00NOTIMPL\x00";

fn testHandleRequest(req: *std.http.Server.Request, file_blob: []const u8) !void {
    // An empty blob simulates a server that does not have the artifact (404).
    if (file_blob.len == 0) {
        try req.respond("not found", .{ .status = .not_found });
        return;
    }
    // The sentinel blob simulates a server that does not implement the kind (501).
    if (std.mem.eql(u8, file_blob, test_blob_not_implemented)) {
        try req.respond("not implemented", .{ .status = .not_implemented });
        return;
    }

    var send_buffer: [4096]u8 = undefined;
    var res = try req.respondStreaming(&send_buffer, .{
        .content_length = file_blob.len,
        .respond_options = .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/octet-stream" },
            },
        },
    });
    try res.writer.writeAll(file_blob);
    try res.writer.flush();
    try res.end();
}

test "DebuginfodContext no exists servers" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var ctx: *DebuginfodContext = undefined;
    {
        var penvs = try helpers.getEnvMap(allocator);
        defer penvs.deinit();
        try penvs.put("DEBUGINFOD_URLS", "invalidfoo https://test1-notexist http://test2-notexist invalidbar");

        var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp_path = tmp_path_buf[0..try tmp_dir.dir.realPath(std.testing.io, &tmp_path_buf)];
        try penvs.put("DEBUGINFOD_CACHE_PATH", tmp_path);

        ctx = try DebuginfodContext.init(allocator, penvs);
    }
    defer ctx.deinit();

    try std.testing.expectEqual(2, ctx.envs.urls.len);
    try std.testing.expectEqualStrings("https://test1-notexist", ctx.envs.urls[0]);
    try std.testing.expectEqualStrings("http://test2-notexist", ctx.envs.urls[1]);

    _ = ctx.findDebuginfo("ffffff11851246b7766f0a7b3042a8988faad435") catch |err| switch (err) {
        error.NameServerFailure => |e| try std.testing.expectEqual(error.NameServerFailure, e),
        error.UnknownHostName => |e| try std.testing.expectEqual(error.UnknownHostName, e),
        else => |e| try std.testing.expectEqual(error.UnknownHostName, e),
    };
}

test "DebuginfodContext real server" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var queue_buf: [1]u16 = undefined;
    var queue: std.Io.Queue(u16) = .init(&queue_buf);

    const contentInFile = "debug content";
    var debug_server = try io.concurrent(testStartServer, .{ io, contentInFile, &queue });
    defer debug_server.cancel(io) catch {};

    const port = try queue.getOne(io);

    var ctx: *DebuginfodContext = undefined;
    {
        var penvs = try helpers.getEnvMap(allocator);
        defer penvs.deinit();

        const DEBUGINFOD_URLS = try std.fmt.allocPrint(allocator, "invalidfoo https://test1-notexist http://test2-notexist http://127.0.0.1:{d} invalidbar", .{port});
        defer allocator.free(DEBUGINFOD_URLS);
        try penvs.put("DEBUGINFOD_URLS", DEBUGINFOD_URLS);

        var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp_path = tmp_path_buf[0..try tmp_dir.dir.realPath(std.testing.io, &tmp_path_buf)];
        try penvs.put("DEBUGINFOD_CACHE_PATH", tmp_path);

        ctx = try DebuginfodContext.init(allocator, penvs);
    }
    defer ctx.deinit();

    try std.testing.expectEqual(3, ctx.envs.urls.len);

    const filepath = try ctx.findDebuginfo("5c9d8b11851246b7766f0a7b3042a8988faad435");
    defer allocator.free(filepath);

    const content = try std.Io.Dir.cwd().readFileAlloc(io, filepath, allocator, .unlimited);
    defer allocator.free(content);

    try std.testing.expectEqualStrings(contentInFile, content);
}

test "DebuginfodContext negative cache: 404 creates an empty marker" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var queue_buf: [1]u16 = undefined;
    var queue: std.Io.Queue(u16) = .init(&queue_buf);

    // An empty blob makes the test server answer 404 for every request.
    var debug_server = try io.concurrent(testStartServer, .{ io, "", &queue });
    defer debug_server.cancel(io) catch {};
    const port = try queue.getOne(io);

    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = tmp_path_buf[0..try tmp_dir.dir.realPath(io, &tmp_path_buf)];

    var ctx: *DebuginfodContext = undefined;
    {
        var penvs = try helpers.getEnvMap(allocator);
        defer penvs.deinit();
        const urls = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{port});
        defer allocator.free(urls);
        try penvs.put("DEBUGINFOD_URLS", urls);
        try penvs.put("DEBUGINFOD_CACHE_PATH", tmp_path);
        ctx = try DebuginfodContext.init(allocator, penvs);
    }
    defer ctx.deinit();

    const build_id = "5c9d8b11851246b7766f0a7b3042a8988faad435";
    try std.testing.expectError(error.FetchStatusNotFound, ctx.findDebuginfo(build_id));

    const marker = try std.fs.path.join(allocator, &.{ tmp_path, build_id, "debuginfo" });
    defer allocator.free(marker);
    const st = try std.Io.Dir.cwd().statFile(io, marker, .{});
    try std.testing.expectEqual(@as(u64, 0), st.size);
}

test "DebuginfodContext negative cache: fresh marker short-circuits without network" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = tmp_path_buf[0..try tmp_dir.dir.realPath(io, &tmp_path_buf)];

    const build_id = "5c9d8b11851246b7766f0a7b3042a8988faad435";

    // Pre-create a fresh, empty negative marker at <cache>/<build_id>/debuginfo.
    try tmp_dir.dir.createDirPath(io, build_id);
    const sub = try std.fs.path.join(allocator, &.{ build_id, "debuginfo" });
    defer allocator.free(sub);
    var marker_file = try tmp_dir.dir.createFile(io, sub, .{});
    marker_file.close(io);

    var ctx: *DebuginfodContext = undefined;
    {
        var penvs = try helpers.getEnvMap(allocator);
        defer penvs.deinit();
        // Unreachable port: if the lookup hit the network it would fail with a
        // connection error instead of the negative-cache ENOENT.
        try penvs.put("DEBUGINFOD_URLS", "http://127.0.0.1:1");
        try penvs.put("DEBUGINFOD_CACHE_PATH", tmp_path);
        ctx = try DebuginfodContext.init(allocator, penvs);
    }
    defer ctx.deinit();

    try std.testing.expectError(error.FetchStatusNotFound, ctx.findDebuginfo(build_id));
}

test "findSource short-circuits when debuginfo is negatively cached" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = tmp_path_buf[0..try tmp_dir.dir.realPath(io, &tmp_path_buf)];

    const build_id = "5c9d8b11851246b7766f0a7b3042a8988faad435";

    // Fresh negative debuginfo marker => source can't exist for this build_id.
    try tmp_dir.dir.createDirPath(io, build_id);
    const sub = try std.fs.path.join(allocator, &.{ build_id, "debuginfo" });
    defer allocator.free(sub);
    var marker_file = try tmp_dir.dir.createFile(io, sub, .{});
    marker_file.close(io);

    var ctx: *DebuginfodContext = undefined;
    {
        var penvs = try helpers.getEnvMap(allocator);
        defer penvs.deinit();
        // Unreachable: a network query would fail with a connection error.
        try penvs.put("DEBUGINFOD_URLS", "http://127.0.0.1:1");
        try penvs.put("DEBUGINFOD_CACHE_PATH", tmp_path);
        ctx = try DebuginfodContext.init(allocator, penvs);
    }
    defer ctx.deinit();

    try std.testing.expectError(error.FetchStatusNotFound, ctx.findSource(build_id, "/any/file.c"));
}

test "findSource caches 501 at build_id level and skips later files" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = tmp_path_buf[0..try tmp_dir.dir.realPath(io, &tmp_path_buf)];

    const build_id = "5c9d8b11851246b7766f0a7b3042a8988faad435";

    // Phase 1: a server that replies 501 for source -> mark build_id unsupported.
    {
        var queue_buf: [1]u16 = undefined;
        var queue: std.Io.Queue(u16) = .init(&queue_buf);
        var server = try io.concurrent(testStartServer, .{ io, test_blob_not_implemented, &queue });
        defer server.cancel(io) catch {};
        const port = try queue.getOne(io);

        var ctx: *DebuginfodContext = undefined;
        {
            var penvs = try helpers.getEnvMap(allocator);
            defer penvs.deinit();
            const urls = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{port});
            defer allocator.free(urls);
            try penvs.put("DEBUGINFOD_URLS", urls);
            try penvs.put("DEBUGINFOD_CACHE_PATH", tmp_path);
            ctx = try DebuginfodContext.init(allocator, penvs);
        }
        defer ctx.deinit();

        try std.testing.expectError(error.FetchStatusNotImplemented, ctx.findSource(build_id, "/a.c"));

        const marker = try std.fs.path.join(allocator, &.{ tmp_path, build_id, "source-unsupported" });
        defer allocator.free(marker);
        const st = try std.Io.Dir.cwd().statFile(io, marker, .{});
        try std.testing.expectEqual(@as(u64, 0), st.size);
    }

    // Phase 2: a fresh context with an unreachable URL but the same cache must
    // short-circuit a *different* source file using the build_id marker (no net).
    {
        var ctx: *DebuginfodContext = undefined;
        {
            var penvs = try helpers.getEnvMap(allocator);
            defer penvs.deinit();
            try penvs.put("DEBUGINFOD_URLS", "http://127.0.0.1:1");
            try penvs.put("DEBUGINFOD_CACHE_PATH", tmp_path);
            ctx = try DebuginfodContext.init(allocator, penvs);
        }
        defer ctx.deinit();

        try std.testing.expectError(error.FetchStatusNotFound, ctx.findSource(build_id, "/b.c"));
    }
}

test "cache_miss_s is read from the cache config file" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = tmp_path_buf[0..try tmp_dir.dir.realPath(io, &tmp_path_buf)];

    try tmp_dir.dir.writeFile(io, .{ .sub_path = "cache_miss_s", .data = "42\n" });

    var ctx: *DebuginfodContext = undefined;
    {
        var penvs = try helpers.getEnvMap(allocator);
        defer penvs.deinit();
        try penvs.put("DEBUGINFOD_CACHE_PATH", tmp_path);
        ctx = try DebuginfodContext.init(allocator, penvs);
    }
    defer ctx.deinit();

    try std.testing.expectEqual(@as(u64, 42), ctx.envs.cache_miss_s);
}

test "stale negative marker is dropped and re-queried (respects cache_miss_s)" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = tmp_path_buf[0..try tmp_dir.dir.realPath(io, &tmp_path_buf)];

    const build_id = "5c9d8b11851246b7766f0a7b3042a8988faad435";

    // Empty debuginfo marker, but with an mtime well older than cache_miss_s
    // (default 600) -> it must be treated as stale, deleted, and re-queried.
    try tmp_dir.dir.createDirPath(io, build_id);
    const sub = try std.fs.path.join(allocator, &.{ build_id, "debuginfo" });
    defer allocator.free(sub);
    {
        var marker_file = try tmp_dir.dir.createFile(io, sub, .{});
        defer marker_file.close(io);
        const now = std.Io.Clock.now(.real, io);
        const old_ts: std.Io.Timestamp = .{ .nanoseconds = now.nanoseconds - 1000 * std.time.ns_per_s };
        try marker_file.setTimestamps(io, .{ .modify_timestamp = .{ .new = old_ts } });
    }

    var ctx: *DebuginfodContext = undefined;
    {
        var penvs = try helpers.getEnvMap(allocator);
        defer penvs.deinit();
        // Unreachable: a re-query fails with a connection error, not the cached
        // ENOENT -> proves the stale marker did not short-circuit.
        try penvs.put("DEBUGINFOD_URLS", "http://127.0.0.1:1");
        try penvs.put("DEBUGINFOD_CACHE_PATH", tmp_path);
        ctx = try DebuginfodContext.init(allocator, penvs);
    }
    defer ctx.deinit();

    if (ctx.findDebuginfo(build_id)) |path| {
        allocator.free(path);
        return error.TestUnexpectedResult; // should not have found anything
    } else |err| {
        try std.testing.expect(err != error.FetchStatusNotFound);
    }

    // The stale marker was deleted by checkCache; the failed re-query (connection
    // error, not 404) left no new marker behind.
    const marker = try std.fs.path.join(allocator, &.{ tmp_path, build_id, "debuginfo" });
    defer allocator.free(marker);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, marker, .{}));
}

// --- Regression test for pwndbg/debuginfod-zig#9 -----------------------------
//
// Two clients (e.g. two GDB threads/processes sharing one cache) fetching the
// same artifact at the same time must not write to the same temp file. With a
// fixed `.tmp.<name>` path, client B's `O_TRUNC` open wipes what client A has
// already written; A then keeps writing at its old offset, leaving a hole of
// zeros at the start of the file it finally renames into place.
//
// The server below makes the interleaving deterministic:
//   conn #1 (A): send first half, wait until conn #2 arrived, send second half
//   conn #2 (B): wait until the test has inspected A's result, send everything
// and the test only starts B once A's progress callback reports that at least
// half of the body has been streamed into A's temp file.

const RaceServerState = struct {
    conn_count: std.atomic.Value(u32) = .init(0),
    // Bytes client A has streamed into its temp file (from its progress callback).
    a_written: std.atomic.Value(usize) = .init(0),
    // Set once connection #2 (client B) has been accepted: unblocks A's second half.
    second_conn_arrived: std.atomic.Value(bool) = .init(false),
    // Set once the test has inspected A's result: unblocks B's body.
    release_second: std.atomic.Value(bool) = .init(false),
};

fn testRaceProgressFn(handle: ?*DebuginfodContext, current: c_long, total: c_long) callconv(.c) c_int {
    _ = total;
    const state: *RaceServerState = @ptrCast(@alignCast(handle.?.current_userdata.?));
    state.a_written.store(@intCast(@max(current, 0)), .release);
    return 0;
}

fn testStartRaceServer(io: std.Io, file_blob: []const u8, queue: *std.Io.Queue(u16), state: *RaceServerState) !void {
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var socket = try address.listen(io, .{});
    defer socket.deinit(io);
    try queue.putOne(io, socket.socket.address.getPort());

    // Unlike testStartServer, connections are served concurrently: the test
    // needs both requests in flight at once.
    var group: std.Io.Group = .init;
    defer group.cancel(io);

    while (true) {
        const conn = socket.accept(io) catch break;
        const conn_no = state.conn_count.fetchAdd(1, .acq_rel) + 1;
        try group.concurrent(io, testHandleRaceConnection, .{ io, conn, file_blob, conn_no, state });
    }
}

// Group.concurrent only accepts Cancelable!void: report any other handler
// error to stderr (the client side of the test will fail loudly anyway).
fn testHandleRaceConnection(io: std.Io, stream: std.Io.net.Stream, file_blob: []const u8, conn_no: u32, state: *RaceServerState) std.Io.Cancelable!void {
    testHandleRaceConnectionInner(io, stream, file_blob, conn_no, state) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => std.debug.print("race test http handler #{d} error: {}\n", .{ conn_no, err }),
    };
}

fn testHandleRaceConnectionInner(io: std.Io, stream: std.Io.net.Stream, file_blob: []const u8, conn_no: u32, state: *RaceServerState) !void {
    defer stream.close(io);

    var req_buf: [2048]u8 = undefined;
    var conn_reader = stream.reader(io, &req_buf);
    var conn_writer = stream.writer(io, &req_buf);
    var http_server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);
    var req = try http_server.receiveHead();

    var send_buffer: [4096]u8 = undefined;
    var res = try req.respondStreaming(&send_buffer, .{
        .content_length = file_blob.len,
        .respond_options = .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/octet-stream" },
            },
        },
    });

    const half = file_blob.len / 2;
    switch (conn_no) {
        1 => {
            try res.writer.writeAll(file_blob[0..half]);
            try res.writer.flush();
            while (!state.second_conn_arrived.load(.acquire)) try io.sleep(.fromMilliseconds(10), .awake);
            try res.writer.writeAll(file_blob[half..]);
        },
        2 => {
            state.second_conn_arrived.store(true, .release);
            while (!state.release_second.load(.acquire)) try io.sleep(.fromMilliseconds(10), .awake);
            try res.writer.writeAll(file_blob);
        },
        else => return error.UnexpectedExtraConnection,
    }
    try res.writer.flush();
    try res.end();
}

// Check that a find* result is a path to a file holding exactly `expected`.
// On mismatch, print how the file is corrupt (a zero-hole is the #9 symptom).
fn testExpectFetchedFile(io: std.Io, allocator: std.mem.Allocator, label: []const u8, result: anyerror![]u8, expected: []const u8) !void {
    const path = result catch |err| {
        std.debug.print("client {s}: fetch failed: {}\n", .{ label, err });
        return err;
    };
    defer allocator.free(path);

    const content = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(content);
    if (std.mem.eql(u8, content, expected)) return;

    var zeros: usize = 0;
    for (content) |c| {
        if (c == 0) zeros += 1;
    }
    std.debug.print("client {s}: fetched file is corrupt: len={d} (want {d}), zero bytes={d}, first mismatch at offset {?d}\n", .{
        label, content.len, expected.len, zeros, std.mem.indexOfDiff(u8, content, expected),
    });
    return error.CorruptedDownload;
}

test "concurrent fetches of the same artifact do not clobber each other's temp file (issue #9)" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Large enough that most of the first half is already flushed to disk
    // (fetchAsFile buffers 64 KiB) when client B truncates the temp file.
    // Every byte is non-zero so a hole of zeros is unmistakable.
    const blob = try allocator.alloc(u8, 512 * 1024);
    defer allocator.free(blob);
    for (blob, 0..) |*b, i| b.* = @intCast(i % 251 + 1);

    var state: RaceServerState = .{};
    var queue_buf: [1]u16 = undefined;
    var queue: std.Io.Queue(u16) = .init(&queue_buf);
    var server = try io.concurrent(testStartRaceServer, .{ io, blob, &queue, &state });
    defer server.cancel(io) catch {};
    const port = try queue.getOne(io);

    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = tmp_path_buf[0..try tmp_dir.dir.realPath(std.testing.io, &tmp_path_buf)];
    const urls = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{port});
    defer allocator.free(urls);

    // Two independent clients sharing one cache directory.
    var ctxs: [2]*DebuginfodContext = undefined;
    for (&ctxs) |*ctx| {
        var penvs = try helpers.getEnvMap(allocator);
        defer penvs.deinit();
        try penvs.put("DEBUGINFOD_URLS", urls);
        try penvs.put("DEBUGINFOD_CACHE_PATH", tmp_path);
        ctx.* = try DebuginfodContext.init(allocator, penvs);
    }
    defer for (ctxs) |ctx| ctx.deinit();
    const ctx_a = ctxs[0];
    const ctx_b = ctxs[1];

    ctx_a.progress_fn = @constCast(&testRaceProgressFn);
    ctx_a.current_userdata = &state;

    const build_id = "5c9d8b11851246b7766f0a7b3042a8988faad435";

    var fut_a = try io.concurrent(DebuginfodContext.findDebuginfo, .{ ctx_a, build_id });
    // Wait until A has streamed at least half of the body into its temp file.
    while (state.a_written.load(.acquire) < blob.len / 2) try io.sleep(.fromMilliseconds(10), .awake);

    // B now opens its temp file and connects; the connection unblocks A's
    // second half, so A finishes (and renames) while B is still waiting.
    var fut_b = try io.concurrent(DebuginfodContext.findDebuginfo, .{ ctx_b, build_id });

    const verdict_a = testExpectFetchedFile(io, allocator, "A", fut_a.await(io), blob);

    // Whatever A looked like, let B run to completion before judging.
    state.release_second.store(true, .release);
    const result_b = fut_b.await(io);

    try verdict_a;
    try testExpectFetchedFile(io, allocator, "B", result_b, blob);
}
