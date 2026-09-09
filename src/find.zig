// `debuginfod-find`: a small CLI around client.zig, mirroring the command line
// of elfutils' debuginfod-find. Prints the path of the cached artifact on
// stdout and exits 0; on failure prints "Server query failed: ..." on stderr
// and exits 1.
const std = @import("std");
const client = @import("client.zig");
const log = @import("log.zig");
const manifest = @import("manifest.zig");
const elf_build_id = @import("elf_build_id.zig");

const usage =
    \\Usage: debuginfod-find [OPTION...] debuginfo BUILDID
    \\  or:  debuginfod-find [OPTION...] debuginfo PATH
    \\  or:  debuginfod-find [OPTION...] executable BUILDID
    \\  or:  debuginfod-find [OPTION...] executable PATH
    \\  or:  debuginfod-find [OPTION...] source BUILDID /FILENAME
    \\  or:  debuginfod-find [OPTION...] source PATH /FILENAME
    \\  or:  debuginfod-find [OPTION...] section BUILDID SECTION-NAME
    \\  or:  debuginfod-find [OPTION...] section PATH SECTION-NAME
    \\  or:  debuginfod-find [OPTION...] metadata (glob|file|KEY) (GLOB|FILENAME|VALUE)
    \\Request debuginfo-related content from debuginfod servers.
    \\
    \\PATH is an ELF file whose GNU build-id note is used as BUILDID.
    \\Servers are taken from $DEBUGINFOD_URLS (default: https://debuginfod.pwndbg.re when
    \\unset or empty); results land in $DEBUGINFOD_CACHE_PATH.
    \\
    \\  -v, --verbose              Increase verbosity of output
    \\  -h, --help                 Give this help list
    \\  -V, --version              Print program version
    \\
;

// Used when $DEBUGINFOD_URLS is unset or blank. CLI-only: the library itself
// keeps upstream semantics (no URLs => nothing to query).
const default_urls = "https://debuginfod.pwndbg.re";

const Kind = enum { debuginfo, executable, source, section, metadata };

const Cli = struct {
    verbose: bool = false,
    kind: Kind,
    build_id_or_path: []const u8,
    extra: ?[]const u8,
};

const ParseError = error{ Help, Version, Usage };

// `arena` is the process-lifetime arena: positional args are copied into it
// and never freed individually.
fn parseArgs(arena: std.mem.Allocator, args: std.process.Args, err_w: *std.Io.Writer) !Cli {
    var it = try std.process.Args.Iterator.initAllocator(args, arena);
    defer it.deinit();
    _ = it.skip(); // argv[0]

    var verbose = false;
    var positional: [3][]const u8 = undefined;
    var npos: usize = 0;
    var only_positional = false;

    while (it.next()) |arg| {
        if (!only_positional and arg.len > 1 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "--")) {
                only_positional = true;
            } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
                verbose = true;
            } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-?") or std.mem.eql(u8, arg, "--usage")) {
                return error.Help;
            } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
                return error.Version;
            } else {
                try err_w.print("debuginfod-find: unrecognized option '{s}'\n", .{arg});
                return error.Usage;
            }
            continue;
        }
        if (npos == positional.len) {
            try err_w.print("debuginfod-find: too many arguments\n", .{});
            return error.Usage;
        }
        // Copy: the iterator's buffers may not outlive `it` on every platform.
        positional[npos] = try arena.dupe(u8, arg);
        npos += 1;
    }

    if (npos == 0) return error.Usage;

    const kind = std.meta.stringToEnum(Kind, positional[0]) orelse {
        try err_w.print("debuginfod-find: unknown query type '{s}'\n", .{positional[0]});
        return error.Usage;
    };
    const want: usize = switch (kind) {
        .debuginfo, .executable => 2,
        .source, .section, .metadata => 3,
    };
    if (npos != want) {
        try err_w.print("debuginfod-find: '{s}' takes {d} argument(s)\n", .{ positional[0], want - 1 });
        return error.Usage;
    }

    return .{
        .verbose = verbose,
        .kind = kind,
        .build_id_or_path = positional[1],
        .extra = if (npos == 3) positional[2] else null,
    };
}

// elfutils semantics: if the argument names a readable file, treat it as an
// ELF and read its build-id; otherwise it is taken to be the hex build-id.
fn resolveBuildId(gpa: std.mem.Allocator, io: std.Io, arg: []const u8, err_w: *std.Io.Writer) ![]u8 {
    std.Io.Dir.cwd().access(io, arg, .{ .read = true }) catch {
        return try gpa.dupe(u8, arg);
    };
    return elf_build_id.readBuildIdHex(gpa, io, arg) catch |err| {
        try err_w.print("Cannot extract build-id from {s}: {t}\n", .{ arg, err });
        return error.BuildIdUnavailable;
    };
}

fn progressFn(handle: ?*client.DebuginfodContext, current: c_long, total: c_long) callconv(.c) c_int {
    _ = handle;
    std.debug.print("Progress {d} / {d}\n", .{ current, total });
    return 0;
}

fn describeError(err: anyerror) []const u8 {
    return switch (err) {
        error.FetchStatusNotFound => "No such file or directory (HTTP 404)",
        error.FetchStatusNotImplemented => "Not implemented by server (HTTP 501)",
        error.FetchStatusNotOk => "Server returned a non-200 status",
        error.ErrorNotFound => "No servers to query (check $DEBUGINFOD_URLS)",
        error.DownloadTimeoutExceed => "Timed out (DEBUGINFOD_TIMEOUT)",
        error.DownloadMaxTimeExceed => "Exceeded DEBUGINFOD_MAXTIME",
        error.DownloadMaxSizeExceed => "Exceeded DEBUGINFOD_MAXSIZE",
        else => @errorName(err),
    };
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var err_buf: [1024]u8 = undefined;
    var stderr_w = std.Io.File.stderr().writerStreaming(io, &err_buf);
    const err_w = &stderr_w.interface;
    defer err_w.flush() catch {};

    var out_buf: [1024]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const out_w = &stdout_w.interface;

    const cli = parseArgs(init.arena.allocator(), init.minimal.args, err_w) catch |err| switch (err) {
        error.Help => {
            try out_w.writeAll(usage);
            try out_w.flush();
            return 0;
        },
        error.Version => {
            try out_w.print("debuginfod-find ({s}) {s}\n", .{ manifest.name, manifest.version });
            try out_w.flush();
            return 0;
        },
        error.Usage => {
            try err_w.writeAll(usage);
            return 1;
        },
        else => return err,
    };
    if (cli.verbose) {
        log.setLogFile(std.Io.File.stderr());
    }

    if (cli.kind == .metadata) {
        try err_w.writeAll("Server query failed: metadata queries are not implemented in debuginfod-zig (debuginfod_find_metadata)\n");
        return 1;
    }

    const build_id = resolveBuildId(gpa, io, cli.build_id_or_path, err_w) catch return 1;
    defer gpa.free(build_id);

    const urls_env = init.environ_map.get("DEBUGINFOD_URLS") orelse "";
    const using_default_urls = std.mem.trim(u8, urls_env, " \t\r\n").len == 0;
    if (using_default_urls) {
        try init.environ_map.put("DEBUGINFOD_URLS", default_urls);
    }

    const ctx = try client.DebuginfodContext.init(gpa, init.environ_map.*);
    defer ctx.deinit();

    if (cli.verbose) {
        ctx.progress_fn = @constCast(&progressFn);
        if (using_default_urls) try err_w.writeAll("$DEBUGINFOD_URLS is empty, using the default server\n");
        for (ctx.envs.urls) |url| try err_w.print("server: {s}\n", .{url});
        try err_w.print("cache: {s}\n", .{ctx.envs.cache_path});
        try err_w.flush();
    }
    if (ctx.envs.urls.len == 0) {
        try err_w.writeAll("warning: no valid http(s):// URLs in $DEBUGINFOD_URLS, only the local cache will be consulted\n");
    }

    const result = switch (cli.kind) {
        .debuginfo => ctx.findDebuginfo(build_id),
        .executable => ctx.findExecutable(build_id),
        .source => ctx.findSource(build_id, cli.extra.?),
        .section => ctx.findSectionWithFallback(build_id, cli.extra.?),
        .metadata => unreachable,
    };
    const path = result catch |err| {
        try err_w.print("Server query failed: {s}\n", .{describeError(err)});
        return 1;
    };
    defer gpa.free(path);

    try out_w.print("{s}\n", .{path});
    try out_w.flush();
    return 0;
}

test {
    _ = elf_build_id;
}
