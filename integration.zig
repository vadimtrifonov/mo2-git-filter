const std = @import("std");
const io = std.testing.io;
const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;
const rules = "*.ini text eol=crlf\n/ModOrganizer.ini filter=mo2-config\n/mods/*/meta.ini filter=mo2-meta\n";

fn run(allocator: Allocator, cwd: []const u8, argv: []const []const u8) ![]const u8 {
    const result = try std.process.run(allocator, io, .{ .argv = argv, .cwd = .{ .path = cwd } });
    if (!result.term.success()) {
        std.debug.print("{s}: {s}\n", .{ argv[0], result.stderr });
        return error.CommandFailed;
    }
    return std.mem.trimEnd(u8, result.stdout, "\r\n");
}

fn put(root: []const u8, name: []const u8, content: []const u8) !void {
    var dir = try Dir.cwd().openDir(io, root, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = name, .data = content });
}

fn expectHash(allocator: Allocator, root: []const u8, path: []const u8, expected: []const u8) !void {
    try put(root, "expected", expected);
    const want = try run(allocator, root, &.{ "git", "hash-object", "--no-filters", "expected" });
    const actual = try run(allocator, root, &.{ "git", "hash-object", path });
    try std.testing.expectEqualStrings(want, actual);
}

test "registered drivers filter through Git and fail without the executable" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const temporary_path = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    const root = try std.fs.path.join(allocator, &.{ temporary_path, "main checkout" });
    const moved = try std.fs.path.join(allocator, &.{ temporary_path, "relocated checkout" });
    const executable = try std.testing.environ.getAlloc(allocator, "MO2_FILTER_EXE");
    const installed = try std.fs.path.join(allocator, &.{ root, "tools/mo2-git-filter/mo2-git-filter.exe" });

    _ = try run(allocator, temporary_path, &.{ "git", "init", "--quiet", root });
    try Dir.cwd().copyFile(executable, Dir.cwd(), installed, io, .{ .make_path = true });
    for ([_][]const u8{ "config", "meta" }) |mode| {
        const process = try std.fmt.allocPrint(allocator, "filter.mo2-{s}.process", .{mode});
        const required = try std.fmt.allocPrint(allocator, "filter.mo2-{s}.required", .{mode});
        const command = try std.fmt.allocPrint(allocator, "tools/mo2-git-filter/mo2-git-filter.exe {s}", .{mode});
        _ = try run(allocator, root, &.{ "git", "config", "--local", process, command });
        _ = try run(allocator, root, &.{ "git", "config", "--local", required, "true" });
    }
    _ = try run(allocator, root, &.{ "git", "config", "--local", "core.ignorecase", "true" });
    try Dir.cwd().createDirPath(io, try std.fs.path.join(allocator, &.{ root, "mods/Filter Test" }));
    try Dir.cwd().createDirPath(io, try std.fs.path.join(allocator, &.{ root, "subdirectory" }));
    try put(root, ".gitattributes", rules);
    try put(root, "ModOrganizer.ini", "[General]\nfixture=1\n");
    try put(root, "mods/Filter Test/meta.ini", "[General]\nversion=1\n");
    _ = try run(allocator, root, &.{ "git", "add", "--", ".gitattributes", "ModOrganizer.ini", "mods" });
    _ = try run(allocator, root, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--quiet", "-m", "fixture" });

    const metadata = "[General]\r\nlastNexusQuery=old\r\nlastNexusUpdate=old\r\nversion=1\r\n";
    try put(root, "mods/Filter Test/Meta.ini", metadata);
    try expectHash(allocator, root, "mods/Filter Test/Meta.ini", "[General]\nversion=1\n");
    _ = try run(allocator, root, &.{ "git", "diff", "--exit-code", "--", "mods" });
    try put(root, "mods/Filter Test/Meta.ini", "[General]\r\nversion=2\r\n");
    const changed = try std.process.run(allocator, io, .{
        .argv = &.{ "git", "diff", "--quiet", "--", "mods" },
        .cwd = .{ .path = root },
    });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, changed.term);
    try put(root, "mods/Filter Test/Meta.ini", metadata);
    try put(root, "ModOrganizer.ini", "[General]\r\nx=1\r\n[Widgets]\r\ny=2\r\n");
    try expectHash(allocator, root, "modorganizer.ini", "[General]\nx=1\n");
    const subdirectory = try std.fs.path.join(allocator, &.{ root, "subdirectory" });
    try expectHash(allocator, subdirectory, "../ModOrganizer.ini", "[General]\nx=1\n");
    try expectHash(allocator, subdirectory, "../mods/Filter Test/Meta.ini", "[General]\nversion=1\n");

    try put(root, "unfiltered", metadata);
    const raw = try run(allocator, root, &.{ "git", "hash-object", "--no-filters", "-w", "unfiltered" });
    const smudged = try run(allocator, root, &.{ "git", "cat-file", "--filters", "--path=mods/Filter Test/Meta.ini", raw });
    try std.testing.expectEqualStrings(std.mem.trimEnd(u8, metadata, "\r\n"), smudged);
    const unchanged = try run(allocator, root, &.{ "git", "hash-object", "--no-filters", "mods/Filter Test/Meta.ini" });
    try std.testing.expectEqualStrings(raw, unchanged);
    _ = try run(allocator, root, &.{ "git", "--no-optional-locks", "status", "--porcelain" });

    try Dir.renameAbsolute(root, moved, io);
    try expectHash(allocator, moved, "mods/Filter Test/Meta.ini", "[General]\nversion=1\n");
    _ = try run(allocator, moved, &.{ "git", "--no-optional-locks", "status", "--porcelain" });
    var moved_dir = try Dir.cwd().openDir(io, moved, .{});
    defer moved_dir.close(io);
    try moved_dir.deleteFile(io, "tools/mo2-git-filter/mo2-git-filter.exe");
    const missing = try std.process.run(allocator, io, .{
        .argv = &.{ "git", "hash-object", "mods/Filter Test/Meta.ini" },
        .cwd = .{ .path = moved },
    });
    try std.testing.expect(!missing.term.success());
}
