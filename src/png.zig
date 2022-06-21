const std = @import("std");
const builtin = @import("builtin");
const util = @import("util.zig");

pub const signature: [8]u8 = .{ 137, 80, 78, 71, 13, 10, 26, 10 };

pub const CheckForPngSignatureError = error{ InsufficientBytes, InvalidBytes };
pub fn checkForPngSignature(reader: anytype) @TypeOf(reader).Error!CheckForPngSignatureError!void {
    const ReadError = (@TypeOf(reader).Error);
    const Inner = CheckForPngSignatureError!void;

    var actual: [signature.len]u8 = undefined;
    const read_count = try reader.readAll(&actual);
    if (read_count != actual.len) {
        return comptime util.as(Inner, error.InsufficientBytes);
    }
    std.debug.assert(read_count == signature.len);
    if (!std.mem.eql(u8, &signature, &actual)) {
        return comptime util.as(Inner, error.InvalidBytes);
    }

    return util.as(ReadError!Inner, void{});
}

test "checkForPngSignature" {
    var fbs: std.io.FixedBufferStream([]const u8) = undefined;

    fbs = std.io.fixedBufferStream(signature[0..]);
    try std.testing.expectError(error.EndOfStream, blk: {
        var delimited = util.delimitedReader(fbs.reader(), 0);
        break :blk checkForPngSignature(delimited.reader());
    });

    fbs = std.io.fixedBufferStream(signature[0 .. signature.len - 1]);
    try std.testing.expectError(error.InsufficientBytes, checkForPngSignature(fbs.reader()) catch |err| switch (err) {});

    fbs = std.io.fixedBufferStream(signature[0 .. signature.len - 1] ++ [_]u8{signature[signature.len - 1] -% 2});
    try std.testing.expectError(error.InvalidBytes, checkForPngSignature(fbs.reader()) catch |err| switch (err) {});
}

/// PNG Chunk Type code, in Native Endian Byte Order.
pub const ChunkType = enum(u32) {
    pub const Tag = @typeInfo(ChunkType).Enum.tag_type;
    // Standard Critical Chunk Types
    IHDR = std.mem.readIntBig(u32, "IHDR"),
    PLTE = std.mem.readIntBig(u32, "PLTE"),
    IDAT = std.mem.readIntBig(u32, "IDAT"),
    IEND = std.mem.readIntBig(u32, "IEND"),

    // Standard Ancillary Chunk Types
    bKGD = std.mem.readIntBig(u32, "bKGD"),
    cHRM = std.mem.readIntBig(u32, "cHRM"),
    gAMA = std.mem.readIntBig(u32, "gAMA"),
    hIST = std.mem.readIntBig(u32, "hIST"),
    pHYs = std.mem.readIntBig(u32, "pHYs"),
    sBIT = std.mem.readIntBig(u32, "sBIT"),
    tEXt = std.mem.readIntBig(u32, "tEXt"),
    tIME = std.mem.readIntBig(u32, "tIME"),
    tRNS = std.mem.readIntBig(u32, "tRNS"),
    zTXt = std.mem.readIntBig(u32, "zTXt"),

    // Other Chunk Types
    _,

    pub fn fromInt(value: Tag) ChunkType {
        return @intToEnum(ChunkType, value);
    }
    pub fn fromBig(bytes: *const [4]u8) ChunkType {
        return ChunkType.fromInt(std.mem.readIntBig(Tag, bytes));
    }
    pub fn fromLittle(bytes: *const [4]u8) ChunkType {
        return ChunkType.fromInt(std.mem.readIntLittle(Tag, bytes));
    }

    pub fn str(self: ChunkType) [4]u8 {
        return std.mem.toBytes(self.intBig());
    }

    /// Checks that value corresponds to a valid chunk type code (all bytes corresponding to an alphabetic ascii character).
    pub fn isValid(self: ChunkType) bool {
        for (self.str()) |byte| {
            if (!std.ascii.isAlpha(byte)) return false;
        }

        return true;
    }

    pub fn int(self: ChunkType) Tag {
        return @enumToInt(self);
    }
    pub fn intBig(self: ChunkType) Tag {
        return std.mem.nativeToBig(Tag, self.int());
    }
    pub fn intLittle(self: ChunkType) Tag {
        return std.mem.nativeToLittle(Tag, self.int());
    }

    pub fn property(self: ChunkType, byte_index: u2) bool {
        return (self.str()[byte_index] & 32) != 0;
    }
};

pub const ChunkHeader = struct {
    length: u31,
    type: ChunkType,

    /// Returns `null` if the reader supplies insufficient bytes.
    pub const ParseReaderError = error{ InsufficientBytes, InvalidChunkType, InvalidLength };
    pub fn parseReader(reader: anytype) @TypeOf(reader).Error!(ParseReaderError!ChunkHeader) {
        const Inner = ParseReaderError!ChunkHeader;

        var bytes: [8]u8 = undefined;
        const count = try reader.readAll(bytes[0..]);

        if (count < bytes.len) {
            return comptime util.as(Inner, error.InsufficientBytes);
        }
        std.debug.assert(count == bytes.len);

        const result = parseBytes(bytes[0..]) catch |err| return switch (err) {
            error.InvalidChunkType => comptime util.as(Inner, error.InvalidChunkType),
            error.InvalidLength => comptime util.as(Inner, error.InvalidLength),
        };
        return result;
    }

    pub const ParseBytesError = error{ InvalidChunkType, InvalidLength };
    pub fn parseBytes(bytes: *const [8]u8) ParseBytesError!ChunkHeader {
        const length = std.mem.readIntBig(u32, bytes[0..4]);
        const @"type" = ChunkType.fromInt(std.mem.readIntBig(u32, bytes[4..]));
        if (!@"type".isValid()) {
            return error.InvalidChunkType;
        }

        return ChunkHeader{
            .length = std.math.cast(u31, length) orelse return error.InvalidLength,
            .type = @"type",
        };
    }

    pub fn toBytes(self: ChunkHeader) [8]u8 {
        var bytes: [8]u8 = undefined;
        std.mem.writeIntBig(u32, bytes[0..4], self.length);
        std.mem.writeIntBig(u32, bytes[4..], self.type.int());
        return bytes;
    }
};

test "ChunkHeader" {
    const header = ChunkHeader{
        .length = 13,
        .type = .IHDR,
    };
    const bytes = header.toBytes();
    try std.testing.expectEqual(header, try ChunkHeader.parseBytes(&bytes));

    var fbs = std.io.fixedBufferStream(&bytes);
    try std.testing.expectEqual(header, try (ChunkHeader.parseReader(fbs.reader()) catch |err| switch (err) {}));

    fbs = std.io.fixedBufferStream("");
    try std.testing.expectError(error.InsufficientBytes, ChunkHeader.parseReader(fbs.reader()) catch |err| switch (err) {});
}
