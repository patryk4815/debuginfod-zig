const std = @import("std");

pub fn readBuildIdHex(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);

    const header = try std.elf.Header.read(&reader.interface);

    var sh_it = header.iterateSectionHeaders(&reader);
    while (try sh_it.next()) |shdr| {
        if (shdr.sh_type != std.elf.SHT_NOTE) continue;
        if (try findInNoteRange(allocator, &reader, header.endian, shdr.sh_offset, shdr.sh_size)) |hex| {
            return hex;
        }
    }

    var ph_it = header.iterateProgramHeaders(&reader);
    while (try ph_it.next()) |phdr| {
        if (phdr.p_type != std.elf.PT_NOTE) continue;
        if (try findInNoteRange(allocator, &reader, header.endian, phdr.p_offset, phdr.p_filesz)) |hex| {
            return hex;
        }
    }

    return error.BuildIdNotFound;
}

// Notes are tiny; refuse to slurp anything absurd (guards against a corrupt
// header pointing at gigabytes).
const max_note_range = 1024 * 1024;

fn findInNoteRange(allocator: std.mem.Allocator, reader: *std.Io.File.Reader, endian: std.builtin.Endian, offset: u64, size: u64) !?[]u8 {
    if (size == 0 or size > max_note_range) return null;

    const blob = try allocator.alloc(u8, @intCast(size));
    defer allocator.free(blob);

    reader.seekTo(offset) catch return null;
    reader.interface.readSliceAll(blob) catch return null;

    return try findBuildIdInNotes(allocator, blob, endian);
}

// Walk a sequence of ELF notes (Nhdr + name + desc, each 4-byte aligned) and
// return the hex-encoded desc of the first NT_GNU_BUILD_ID note owned by "GNU".
// Malformed/truncated trailing data just ends the walk (returns null).
pub fn findBuildIdInNotes(allocator: std.mem.Allocator, blob: []const u8, endian: std.builtin.Endian) !?[]u8 {
    var r = std.Io.Reader.fixed(blob);
    while (true) {
        const nhdr = r.takeStruct(std.elf.Elf64_Nhdr, endian) catch return null;

        // Bounds-check against what is left *before* handing sizes to the
        // reader: `Reader.fill` computes `seek + n` in usize, which overflows
        // (panics) on 32-bit targets for a garbage n_namesz like 0xffffffff.
        // Bounded sizes also keep `padding` (alignForward) overflow-free.
        if (nhdr.n_namesz > r.buffered().len) return null;
        const name = r.take(nhdr.n_namesz) catch return null;
        if (padding(nhdr.n_namesz) > r.buffered().len) return null;
        r.discardAll(padding(nhdr.n_namesz)) catch return null;

        if (nhdr.n_descsz > r.buffered().len) return null;
        const desc = r.take(nhdr.n_descsz) catch return null;
        // The last note's desc padding may be absent; tolerate that.
        r.discardAll(@min(padding(nhdr.n_descsz), r.buffered().len)) catch return null;

        if (nhdr.n_type != std.elf.NT_GNU_BUILD_ID) continue;
        if (!std.mem.eql(u8, std.mem.sliceTo(name, 0), "GNU")) continue;
        if (desc.len == 0) continue;

        return try std.fmt.allocPrint(allocator, "{x}", .{desc});
    }
}

fn padding(len: u32) usize {
    return std.mem.alignForward(usize, len, 4) - len;
}

test "findBuildIdInNotes: GNU build-id note" {
    const allocator = std.testing.allocator;
    const endian = @import("builtin").cpu.arch.endian();

    var blob = std.Io.Writer.Allocating.init(allocator);
    defer blob.deinit();

    // An unrelated note first (NT_GNU_ABI_TAG, owner "GNU", 16-byte desc).
    const abi_desc: [16]u8 = @splat(0);
    try appendNote(&blob.writer, endian, "GNU\x00", 1, &abi_desc);
    // Then the build-id note.
    const id = [_]u8{ 0x5c, 0x9d, 0x8b, 0x11, 0x85, 0x12, 0x46, 0xb7, 0x76, 0x6f, 0x0a, 0x7b, 0x30, 0x42, 0xa8, 0x98, 0x8f, 0xaa, 0xd4, 0x35 };
    try appendNote(&blob.writer, endian, "GNU\x00", std.elf.NT_GNU_BUILD_ID, &id);

    const hex = (try findBuildIdInNotes(allocator, blob.written(), endian)) orelse return error.TestUnexpectedResult;
    defer allocator.free(hex);
    try std.testing.expectEqualStrings("5c9d8b11851246b7766f0a7b3042a8988faad435", hex);
}

test "findBuildIdInNotes: wrong owner / no note / garbage" {
    const allocator = std.testing.allocator;
    const endian = @import("builtin").cpu.arch.endian();

    var blob = std.Io.Writer.Allocating.init(allocator);
    defer blob.deinit();
    try appendNote(&blob.writer, endian, "XYZ\x00", std.elf.NT_GNU_BUILD_ID, &[_]u8{ 1, 2, 3 });
    try std.testing.expectEqual(null, try findBuildIdInNotes(allocator, blob.written(), endian));

    try std.testing.expectEqual(null, try findBuildIdInNotes(allocator, "", endian));
    // n_namesz/n_descsz = 0xffffffff: must bail out, not overflow (32-bit usize).
    try std.testing.expectEqual(null, try findBuildIdInNotes(allocator, "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff", endian));
    // Truncated: header claims more name/desc bytes than the blob holds.
    var trunc = std.Io.Writer.Allocating.init(allocator);
    defer trunc.deinit();
    try trunc.writer.writeStruct(std.elf.Elf64_Nhdr{ .n_namesz = 4, .n_descsz = 0xfffffff0, .n_type = std.elf.NT_GNU_BUILD_ID }, endian);
    try trunc.writer.writeAll("GNU\x00\x01\x02");
    try std.testing.expectEqual(null, try findBuildIdInNotes(allocator, trunc.written(), endian));
}

test "readBuildIdHex: synthetic ELF64 with .note.gnu.build-id section" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const endian = @import("builtin").cpu.arch.endian();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const id = [_]u8{ 0xde, 0xad, 0xbe, 0xef, 0x01, 0x02, 0x03, 0x04 };
    const elf_bytes = try buildSyntheticElf64(allocator, endian, &id, .section);
    defer allocator.free(elf_bytes);
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "a.out", .data = elf_bytes });

    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = tmp_path_buf[0..try tmp_dir.dir.realPath(io, &tmp_path_buf)];
    const path = try std.fs.path.join(allocator, &.{ tmp_path, "a.out" });
    defer allocator.free(path);

    const hex = try readBuildIdHex(allocator, io, path);
    defer allocator.free(hex);
    try std.testing.expectEqualStrings("deadbeef01020304", hex);

    // Section headers stripped: only a PT_NOTE segment points at the note.
    const seg_bytes = try buildSyntheticElf64(allocator, endian, &id, .segment);
    defer allocator.free(seg_bytes);
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "stripped.out", .data = seg_bytes });
    const seg_path = try std.fs.path.join(allocator, &.{ tmp_path, "stripped.out" });
    defer allocator.free(seg_path);
    const seg_hex = try readBuildIdHex(allocator, io, seg_path);
    defer allocator.free(seg_hex);
    try std.testing.expectEqualStrings("deadbeef01020304", seg_hex);

    // Not an ELF at all (longer than an ELF header so the magic check is what fails).
    const junk: [128]u8 = @splat('x');
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "plain.txt", .data = &junk });
    const plain = try std.fs.path.join(allocator, &.{ tmp_path, "plain.txt" });
    defer allocator.free(plain);
    try std.testing.expectError(error.InvalidElfMagic, readBuildIdHex(allocator, io, plain));
}

fn appendNote(w: *std.Io.Writer, endian: std.builtin.Endian, name: []const u8, n_type: u32, desc: []const u8) !void {
    const nhdr = std.elf.Elf64_Nhdr{ .n_namesz = @intCast(name.len), .n_descsz = @intCast(desc.len), .n_type = n_type };
    try w.writeStruct(nhdr, endian);
    try w.writeAll(name);
    try w.splatByteAll(0, padding(@intCast(name.len)));
    try w.writeAll(desc);
    try w.splatByteAll(0, padding(@intCast(desc.len)));
}

const NoteVia = enum { section, segment };

// Minimal ELF64: ehdr, a build-id note, and either a 2-entry section header
// table (null + SHT_NOTE) or a 1-entry program header table (PT_NOTE)
// pointing at it. Enough for readBuildIdHex.
fn buildSyntheticElf64(allocator: std.mem.Allocator, endian: std.builtin.Endian, id: []const u8, via: NoteVia) ![]u8 {
    var note = std.Io.Writer.Allocating.init(allocator);
    defer note.deinit();
    try appendNote(&note.writer, endian, "GNU\x00", std.elf.NT_GNU_BUILD_ID, id);
    const note_bytes = note.written();

    const ehdr_size = @sizeOf(std.elf.Elf64_Ehdr);
    const shdr_size = @sizeOf(std.elf.Elf64_Shdr);
    const note_off: u64 = ehdr_size;
    const table_off: u64 = std.mem.alignForward(u64, note_off + note_bytes.len, 8);

    var ident: [std.elf.EI.NIDENT]u8 = @splat(0);
    @memcpy(ident[0..4], std.elf.MAGIC);
    ident[std.elf.EI.CLASS] = std.elf.ELFCLASS64;
    ident[std.elf.EI.DATA] = switch (endian) {
        .little => std.elf.ELFDATA2LSB,
        .big => std.elf.ELFDATA2MSB,
    };
    ident[std.elf.EI.VERSION] = 1;

    const ehdr = std.elf.Elf64_Ehdr{
        .e_ident = ident,
        .e_type = .EXEC,
        .e_machine = .X86_64,
        .e_version = 1,
        .e_entry = 0,
        .e_phoff = if (via == .segment) table_off else 0,
        .e_shoff = if (via == .section) table_off else 0,
        .e_flags = 0,
        .e_ehsize = ehdr_size,
        .e_phentsize = @sizeOf(std.elf.Elf64_Phdr),
        .e_phnum = if (via == .segment) 1 else 0,
        .e_shentsize = shdr_size,
        .e_shnum = if (via == .section) 2 else 0,
        .e_shstrndx = 0,
    };

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeStruct(ehdr, endian);
    try w.writeAll(note_bytes);
    try w.splatByteAll(0, @intCast(table_off - out.written().len));

    if (via == .segment) {
        try w.writeStruct(std.elf.Elf64_Phdr{
            .p_type = std.elf.PT_NOTE,
            .p_flags = 0,
            .p_offset = note_off,
            .p_vaddr = 0,
            .p_paddr = 0,
            .p_filesz = note_bytes.len,
            .p_memsz = note_bytes.len,
            .p_align = 4,
        }, endian);
        return out.toOwnedSlice();
    }

    try w.writeStruct(std.mem.zeroes(std.elf.Elf64_Shdr), endian);
    try w.writeStruct(std.elf.Elf64_Shdr{
        .sh_name = 0,
        .sh_type = std.elf.SHT_NOTE,
        .sh_flags = 0,
        .sh_addr = 0,
        .sh_offset = note_off,
        .sh_size = note_bytes.len,
        .sh_link = 0,
        .sh_info = 0,
        .sh_addralign = 4,
        .sh_entsize = 0,
    }, endian);

    return out.toOwnedSlice();
}
