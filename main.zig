const std = @import("std");
const filter = @import("filter.zig");
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;
const max_packet = 65520;

/// null is a flush packet; EndOfStream is allowed only between complete requests.
fn readPacket(reader: *Reader) !?[]const u8 {
    var header: [4]u8 = undefined;
    const n = try reader.readSliceShort(&header);
    if (n == 0) return error.EndOfStream;
    if (n != header.len) return error.TruncatedPacket;
    for (header) |c| if (!std.ascii.isHex(c)) return error.InvalidPacket;
    const length = try std.fmt.parseInt(u16, &header, 16);
    if (length == 0) return null;
    if (length < 4 or length > max_packet) return error.InvalidPacket;
    return reader.take(length - 4) catch |err| switch (err) {
        error.EndOfStream => error.TruncatedPacket,
        else => err,
    };
}

fn send(writer: *Writer, data: []const u8) !void {
    var remaining = data;
    while (remaining.len != 0) {
        const length = @min(remaining.len, max_packet - 4);
        try writer.print("{x:0>4}", .{length + 4});
        try writer.writeAll(remaining[0..length]);
        remaining = remaining[length..];
    }
}

const Capabilities = struct { clean: bool = false, smudge: bool = false };

fn handshake(reader: *Reader, writer: *Writer) !Capabilities {
    const greeting = try readPacket(reader) orelse return error.InvalidHandshake;
    if (!std.mem.eql(u8, greeting, "git-filter-client\n")) return error.InvalidHandshake;
    var version_two = false;
    while (try readPacket(reader)) |line| {
        if (std.mem.eql(u8, line, "version=2\n")) version_two = true;
    }
    if (!version_two) return error.UnsupportedVersion;
    try send(writer, "git-filter-server\n");
    try send(writer, "version=2\n");
    try writer.writeAll("0000");
    try writer.flush();

    var capabilities: Capabilities = .{};
    while (try readPacket(reader)) |line| {
        if (std.mem.eql(u8, line, "capability=clean\n")) capabilities.clean = true;
        if (std.mem.eql(u8, line, "capability=smudge\n")) capabilities.smudge = true;
    }
    if (!capabilities.clean and !capabilities.smudge) return error.UnsupportedCapabilities;
    if (capabilities.clean) try send(writer, "capability=clean\n");
    if (capabilities.smudge) try send(writer, "capability=smudge\n");
    try writer.writeAll("0000");
    try writer.flush();
    return capabilities;
}

fn serve(allocator: Allocator, mode: filter.Mode, reader: *Reader, writer: *Writer) !void {
    const capabilities = try handshake(reader, writer);
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    while (true) {
        var packet = readPacket(reader) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        var command: ?enum { clean, smudge } = null;
        while (packet) |data| {
            const line = if (std.mem.endsWith(u8, data, "\n")) data[0 .. data.len - 1] else data;
            if (std.mem.startsWith(u8, line, "command=")) {
                if (command != null) return error.InvalidRequest;
                const value = line["command=".len..];
                if (std.mem.eql(u8, value, "clean") and capabilities.clean) {
                    command = .clean;
                } else if (std.mem.eql(u8, value, "smudge") and capabilities.smudge) {
                    command = .smudge;
                } else return error.UnsupportedCommand;
            }
            packet = try readPacket(reader);
        }
        const operation = command orelse return error.InvalidRequest;
        input.clearRetainingCapacity();
        while (try readPacket(reader)) |data| try input.appendSlice(allocator, data);

        const result = if (operation == .clean) result: {
            try filter.clean(allocator, mode, input.items, &output);
            break :result output.items;
        } else input.items;
        try send(writer, "status=success\n");
        try writer.writeAll("0000");
        try send(writer, result);
        // Content terminator followed by an empty final status list.
        try writer.writeAll("00000000");
        try writer.flush();
    }
}

fn parseMode(args: []const [:0]const u8) !filter.Mode {
    if (args.len != 2) return error.InvalidMode;
    return std.meta.stringToEnum(filter.Mode, args[1]) orelse error.InvalidMode;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const mode = try parseMode(args);
    var read_buffer: [max_packet]u8 = undefined;
    var write_buffer: [max_packet]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(init.io, &read_buffer);
    var writer = std.Io.File.stdout().writerStreaming(init.io, &write_buffer);
    try serve(init.gpa, mode, &reader.interface, &writer.interface);
}

fn clientHandshake(writer: *Writer) !void {
    try send(writer, "git-filter-client\n");
    try send(writer, "version=2\n");
    try writer.writeAll("0000");
    try send(writer, "capability=clean\n");
    try send(writer, "capability=smudge\n");
    try send(writer, "capability=delay\n");
    try writer.writeAll("0000");
}

fn request(writer: *Writer, command: []const u8, content: []const u8) !void {
    var header: [64]u8 = undefined;
    try send(writer, try std.fmt.bufPrint(&header, "command={s}\n", .{command}));
    try send(writer, "pathname=file.ini\n");
    try writer.writeAll("0000");
    try send(writer, content);
    try writer.writeAll("0000");
}

test "each mode serves successive clean, smudge, empty and multi-packet requests" {
    const allocator = std.testing.allocator;
    const content = "[General]\nlastNexusQuery=old\nversion=2\n[Widgets]\nx=1\n";
    for ([_]filter.Mode{ .config, .meta }) |mode| {
        var client: Writer.Allocating = .init(allocator);
        defer client.deinit();
        try clientHandshake(&client.writer);
        try request(&client.writer, "clean", content);
        try request(&client.writer, "smudge", "[Widgets]\nkeep=1\x00");
        try request(&client.writer, "clean", "");
        const large = try allocator.alloc(u8, 180000);
        defer allocator.free(large);
        @memset(large, 'x');
        large[large.len - 1] = '\n';
        try request(&client.writer, "clean", large);

        var reader: Reader = .fixed(client.written());
        var response: Writer.Allocating = .init(allocator);
        defer response.deinit();
        try serve(allocator, mode, &reader, &response.writer);

        var expected: Writer.Allocating = .init(allocator);
        defer expected.deinit();
        try send(&expected.writer, "git-filter-server\n");
        try send(&expected.writer, "version=2\n");
        try expected.writer.writeAll("0000");
        try send(&expected.writer, "capability=clean\n");
        try send(&expected.writer, "capability=smudge\n");
        try expected.writer.writeAll("0000");
        const cleaned = switch (mode) {
            .config => "[General]\nlastNexusQuery=old\nversion=2\n",
            .meta => "[General]\nversion=2\n[Widgets]\nx=1\n",
        };
        const empty = if (mode == .config) "\n" else "";
        for ([_][]const u8{ cleaned, "[Widgets]\nkeep=1\x00", empty, large }) |body| {
            try send(&expected.writer, "status=success\n");
            try expected.writer.writeAll("0000");
            try send(&expected.writer, body);
            try expected.writer.writeAll("00000000");
        }
        try std.testing.expectEqualStrings(expected.written(), response.written());
    }
}

test "startup requires exactly one valid mode" {
    try std.testing.expectEqual(.config, try parseMode(&.{ "filter", "config" }));
    try std.testing.expectEqual(.meta, try parseMode(&.{ "filter", "meta" }));
    for ([_][]const [:0]const u8{ &.{"filter"}, &.{ "filter", "unknown" }, &.{ "filter", "meta", "extra" } }) |args|
        try std.testing.expectError(error.InvalidMode, parseMode(args));
}

test "invalid and truncated packets fail instead of returning partial content" {
    for ([_][]const u8{ "0001", "fff1", "zzzz" }) |data| {
        var reader: Reader = .fixed(data);
        try std.testing.expectError(error.InvalidPacket, readPacket(&reader));
    }
    for ([_][]const u8{ "00", "0009hi" }) |data| {
        var reader: Reader = .fixed(data);
        try std.testing.expectError(error.TruncatedPacket, readPacket(&reader));
    }
}

test "incomplete request and unsupported operation fail closed" {
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |unsupported| {
        var client: Writer.Allocating = .init(allocator);
        defer client.deinit();
        try clientHandshake(&client.writer);
        if (unsupported) {
            try request(&client.writer, "unknown", "ignored");
        } else {
            try send(&client.writer, "command=clean\n");
        }
        var reader: Reader = .fixed(client.written());
        var response: Writer.Allocating = .init(allocator);
        defer response.deinit();
        try std.testing.expectError(
            if (unsupported) error.UnsupportedCommand else error.EndOfStream,
            serve(allocator, .config, &reader, &response.writer),
        );
    }
}
