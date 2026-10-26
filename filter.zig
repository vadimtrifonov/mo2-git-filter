const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = std.ArrayList(u8);

pub const Mode = enum { config, meta };

const volatile_sections = [_][]const u8{
    "[recentDirectories]",
    "[Widgets]",
    "[Servers]",
    "[Geometry]",
    "[CompletedWindowTutorials]",
};

/// The trimmed header if the line starts a section.
fn sectionHeader(line: []const u8) ?[]const u8 {
    const text = std.mem.trim(u8, line, " \t");
    return if (std.mem.startsWith(u8, text, "[")) text else null;
}

fn volatileSection(header: []const u8) bool {
    for (volatile_sections) |name| {
        if (std.ascii.eqlIgnoreCase(header, name)) return true;
    }
    return false;
}

fn timestamp(line: []const u8) bool {
    const equals = std.mem.indexOfScalar(u8, line, '=') orelse return false;
    const key = std.mem.trim(u8, line[0..equals], " \t");
    return std.ascii.eqlIgnoreCase(key, "lastNexusQuery") or
        std.ascii.eqlIgnoreCase(key, "lastNexusUpdate");
}

/// Retained lines keep their exact bytes.
/// Config output ends with one newline, because a removed final section leaves
/// behind the blank line that separates sections.
pub fn clean(allocator: Allocator, mode: Mode, input: []const u8, output: *Buffer) !void {
    output.clearRetainingCapacity();

    // Whether the current section is one this mode removes lines from.
    var filtered_section = false;
    var start: usize = 0;
    while (start < input.len) {
        const next = if (std.mem.indexOfScalarPos(u8, input, start, '\n')) |end| end + 1 else input.len;
        const raw = input[start..next];
        const line = std.mem.trimEnd(u8, raw, "\r\n");
        if (sectionHeader(line)) |header| filtered_section = switch (mode) {
            .config => volatileSection(header),
            .meta => std.ascii.eqlIgnoreCase(header, "[General]"),
        };
        const skip = filtered_section and (mode == .config or timestamp(line));
        if (!skip) try output.appendSlice(allocator, raw);
        start = next;
    }

    if (mode == .config) {
        output.items.len = std.mem.trimEnd(u8, output.items, "\r\n").len;
        const newline = if (std.mem.indexOf(u8, input, "\r\n") != null) "\r\n" else "\n";
        try output.appendSlice(allocator, newline);
    }
}

fn expectClean(mode: Mode, input: []const u8, expected: []const u8) !void {
    var output: Buffer = .empty;
    defer output.deinit(std.testing.allocator);
    try clean(std.testing.allocator, mode, input, &output);
    try std.testing.expectEqualStrings(expected, output.items);
    var again: Buffer = .empty;
    defer again.deinit(std.testing.allocator);
    try clean(std.testing.allocator, mode, output.items, &again);
    try std.testing.expectEqualStrings(expected, again.items);
}

test "config removes only the five volatile sections and normalizes the ending" {
    for ([_][]const u8{ "\n", "\r\n" }) |nl| {
        const input = try std.mem.join(std.testing.allocator, nl, &.{
            "[General]",
            "notes=текст",
            "lastNexusQuery=keep",
            "[recentDirectories]",
            "a=1",
            "[WIDGETS]",
            "b=2",
            "[Servers]",
            "c=3",
            "[Geometry]",
            "d=4",
            "[CompletedWindowTutorials]",
            "e=5",
            "[WidgetsBackup]",
            "keep=1",
            "",
            "",
        });
        defer std.testing.allocator.free(input);
        const expected = try std.mem.join(std.testing.allocator, nl, &.{
            "[General]",
            "notes=текст",
            "lastNexusQuery=keep",
            "[WidgetsBackup]",
            "keep=1",
            "",
        });
        defer std.testing.allocator.free(expected);
        try expectClean(.config, input, expected);
    }
    try expectClean(.config, "", "\n");
    try expectClean(.config, "[Widgets]\nx=1", "\n");
    try expectClean(.config, "[General]\nx=1", "[General]\nx=1\n");
}

test "meta removes only timestamp keys in General without reformatting" {
    try expectClean(.meta, "[General]\r\nlastNexusQuery=old\r\nlastNexusUpdate=old\r\nversion=1\r\n" ++
        "newestVersion=2\r\nnexusLastModified=keep\r\nnotes=lastNexusQuery=keep\r\n" ++
        "[installedFiles]\r\nlastNexusUpdate=keep\r\n1\\fileid=42", "[General]\r\nversion=1\r\nnewestVersion=2\r\nnexusLastModified=keep\r\n" ++
        "notes=lastNexusQuery=keep\r\n[installedFiles]\r\nlastNexusUpdate=keep\r\n1\\fileid=42");
    try expectClean(.meta, "[general]\n  LASTNEXUSQUERY =old\nlastNexusUpdateExtra=keep\nnotes=\xff\n\n", "[general]\nlastNexusUpdateExtra=keep\nnotes=\xff\n\n");
    try expectClean(.meta, "[General]\nlastNexusUpdate=old", "[General]\n");
    try expectClean(.meta, "", "");
}
