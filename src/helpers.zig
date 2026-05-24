const std = @import("std");

// todo: MAX_BUILD_ID_BYTES 64
pub fn build_id_to_hex(allocator: std.mem.Allocator, build_id: [*c]const u8, build_id_len: c_int) ![]u8 {
    if (build_id_len == 0) {
        // build_id is hex lowercase already
        return try allocator.dupe(u8, std.mem.span(build_id));
    } else {
        // build_id is raw bytes
        const build_id_bytes = build_id[0..@as(usize, @intCast(build_id_len))];
        const buf = try allocator.alloc(u8, build_id_bytes.len * 2);
        _ = try std.fmt.bufPrint(buf, "{x}", .{build_id_bytes});
        return buf;
    }
}

test "build_id_to_hex works for hex string input" {
    const allocator = std.testing.allocator;

    const hex_str = "4a7c2";
    const out = try build_id_to_hex(allocator, &hex_str[0], 0);

    std.debug.print("Hex string output: {s}\n", .{out});
    defer allocator.free(out);

    try std.testing.expect(std.mem.eql(u8, out, "4a7c2"));
}

test "build_id_to_hex works for raw bytes input" {
    const allocator = std.testing.allocator;

    const raw_bytes = [_]u8{ 0x4a, 0x7c, 0x2f };
    const out = try build_id_to_hex(allocator, &raw_bytes[0], raw_bytes.len);

    std.debug.print("Raw bytes to hex output: {s}\n", .{out});
    defer allocator.free(out);

    try std.testing.expect(std.mem.eql(u8, out, "4a7c2f"));
}

pub fn toCString(allocator: std.mem.Allocator, s: []const u8) ![:0]u8 {
    const dup = try allocator.allocSentinel(u8, s.len, 0);
    @memcpy(dup, s);
    return dup;
}

pub fn escapeFilename(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    const prefix_size = "deadbeef-".len;
    var dest_len = src.len + prefix_size;
    const max_dest_len = std.fs.max_name_bytes / 2;
    if (dest_len > max_dest_len)
        dest_len = max_dest_len;

    var dest = try allocator.alloc(u8, dest_len);

    if (src.len > 0) {
        var wi: usize = dest_len - 1;
        var ri: usize = src.len - 1;

        while (true) {
            dest[wi] = switch (src[ri]) {
                'A'...'Z', 'a'...'z', '0'...'9', '.', '-', '_' => src[ri],
                else => '#',
            };
            if (ri == 0 or wi == 0) {
                break;
            }
            wi -= 1;
            ri -= 1;
        }
    }

    // hash djb2 (DJBX33A)
    var hash: u32 = 5381;
    for (src) |ch| {
        hash = ((hash << 5) +% hash) +% ch;
    }

    _ = try std.fmt.bufPrint(dest[0..8], "{x:0<8}", .{hash});
    dest[8] = '-';
    return dest;
}

test "escape" {
    const allocator = std.testing.allocator;

    const out_empty = try escapeFilename(allocator, "");
    defer allocator.free(out_empty);
    try std.testing.expectEqualStrings("15050000-", out_empty);

    const out = try escapeFilename(allocator, "/root/foo.c");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("7d1e797c-#root#foo.c", out);

    const out3 = try escapeFilename(allocator, "/usr/src/debug/bash-5.3.0-2.fc43.aarch64/shell.c");
    defer allocator.free(out3);
    try std.testing.expectEqualStrings("8612e4f5-#usr#src#debug#bash-5.3.0-2.fc43.aarch64#shell.c", out3);

    const out2 = try escapeFilename(allocator, "/root/too-long-name-aaaa-bbbb-cccc-dddd-eeee-ffff-gggg-hhhh-iiii-jjjj/kkkk/llll-mmmm-nnnn-oooo-pppp-qqqq-rrrr-ssss-tttt-wwww-uuuu-vvvv-xxxx-zzzz-0000-1111-2222-3333-4444-5555-6666-7777-8888.c");
    defer allocator.free(out2);
    try std.testing.expectEqualStrings("8b26663b-k#llll-mmmm-nnnn-oooo-pppp-qqqq-rrrr-ssss-tttt-wwww-uuuu-vvvv-xxxx-zzzz-0000-1111-2222-3333-4444-5555-6666-7777-8888.c", out2);
}

pub fn urlencodePart(allocator: std.mem.Allocator, part: []const u8) ![]u8 {
    var aw = try std.Io.Writer.Allocating.initCapacity(allocator, part.len);
    defer aw.deinit();

    const f = std.Uri.Component{ .raw = part };
    try f.formatUser(&aw.writer);

    return try aw.toOwnedSlice();
}

test "urlencode" {
    const allocator = std.testing.allocator;

    const out = try urlencodePart(allocator, "/root/foo.c");
    defer allocator.free(out);

    try std.testing.expectEqualStrings("%2Froot%2Ffoo.c", out);
}

// Capture the current process environment into a Map. `std.process.getEnvMap`
// was removed; the environment is now a capability normally passed to `main`.
// Since this is a libc-linked shared library (no Zig start), read the global
// libc `environ` directly.
pub fn getEnvMap(allocator: std.mem.Allocator) !std.process.Environ.Map {
    const c_environ = std.c.environ;
    var count: usize = 0;
    while (c_environ[count] != null) : (count += 1) {}
    const block: std.process.Environ.PosixBlock = .{ .slice = @ptrCast(c_environ[0..count :null]) };
    return std.process.Environ.createMap(.{ .block = block }, allocator);
}
