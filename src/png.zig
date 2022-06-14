const std = @import("std");
const util = @import("util.zig");

pub const signature: [8]u8 = .{ 137, 80, 78, 71, 13, 10, 26, 10 };

pub fn CheckReaderForPngSignatureResult(comptime ErrorSet: type) type {
    return union(enum) {
        ok,
        invalid_bytes: InvalidBytes,
        insufficient_bytes: InsufficientBytes,
        read_failure: ReadFailure,

        pub const InvalidBytes = [signature.len]u8;
        pub const InsufficientBytes = std.BoundedArray(u8, signature.len - 1);
        pub const ReadFailure = struct { bytes: InsufficientBytes, err: ErrorSet };

        pub fn unwrap(self: @This()) error{ InvalidBytes, InsufficientBytes, ReadFailure }!void {
            return switch (self) {
                .ok => {},
                .invalid_bytes => error.InvalidBytes,
                .insufficient_bytes => error.InsufficientBytes,
                .read_failure => error.ReadFailure,
            };
        }
    };
}
pub fn checkReaderForPngSignature(reader: anytype) CheckReaderForPngSignatureResult(util.MemoizeErrorSet(@TypeOf(reader).Error)) {
    const Result = CheckReaderForPngSignatureResult(util.MemoizeErrorSet(@TypeOf(reader).Error));

    switch (util.readBoundedArrayExtra(reader, signature.len)) {
        .ok => |bytes| switch (bytes.len) {
            signature.len => {
                if (!std.mem.eql(u8, bytes.constSlice(), &signature)) {
                    std.debug.assert(bytes.len == bytes.capacity());
                    return Result{ .invalid_bytes = bytes.buffer };
                }
                return .ok;
            },
            0...(signature.len - 1) => return Result{
                .insufficient_bytes = Result.InsufficientBytes.fromSlice(bytes.constSlice()) catch unreachable,
            },
            else => unreachable,
        },
        .fail => |fail| switch (fail.bytes.len) {
            signature.len => unreachable,
            0...(signature.len - 1) => return Result{ .read_failure = Result.ReadFailure{
                .bytes = fail.bytes,
                .err = fail.err,
            } },
            else => unreachable,
        },
    }

    return .ok;
}

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

    // Non-Standard Chunk Types
    _,

    /// Reads bytes as a big endian integer.
    pub fn from(bytes: *const [4]u8) ChunkType {
        return @intToEnum(ChunkType, std.mem.readIntBig(u32, bytes));
    }

    pub fn str(self: ChunkType) [4]u8 {
        return std.mem.toBytes(self.int());
    }

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

    const ParseReaderResultTag = enum {
        /// success
        ok,
        /// encountered error while trying to read type
        no_type_err,
        /// encountered end of stream while trying to read type
        no_type_eos,
        /// the bytes read formed an invalid length value
        invalid_length,
        /// encountered error while trying to read length
        no_length_err,
        /// encountered end of stream while trying to read length
        no_length_eos,
    };
    pub fn ParseReaderResult(comptime ReaderError: type) type {
        return union(ParseReaderResultTag) {
            const Self = @This();
            ok: ChunkHeader,
            no_type_err: NoTypeErr,
            no_type_eos: NoTypeEos,
            invalid_length: InvalidLength,
            no_length_err: NoLengthErr,
            no_length_eos: NoLengthEos,

            pub const ReadError = ReaderError;
            pub const NoTypeErr = struct { length: u31, err: ReadError };
            pub const NoTypeEos = struct { length: u31 };
            pub const InvalidLength = struct { invalid_value: u32 };
            pub const NoLengthErr = struct { err: ReadError };
            pub const NoLengthEos = void;
        };
    }
    pub fn parseReader(reader: anytype) ParseReaderResult(@TypeOf(reader).Error) {
        const Result = ParseReaderResult(@TypeOf(reader).Error);

        const length: u31 = length: {
            const length_bytes: [4]u8 = switch (util.readBoundedArrayExtra(reader, 4)) {
                .ok => |bytes| blk: {
                    if (bytes.len < 4) return .no_length_eos;
                    break :blk bytes.slice()[0..4].*;
                },
                .fail => |fail| return Result{ .no_length_err = Result.NoLengthErr{ .err = fail.err } },
            };

            const naive_value = std.mem.readIntBig(u32, &length_bytes);
            if (std.math.cast(u31, naive_value)) |casted| break :length casted;
            return Result{ .invalid_length = Result.InvalidLength{ .value = naive_value } };
        };

        const @"type": ChunkType = @"type": {
            const type_bytes: [4]u8 = switch (util.readBoundedArrayExtra(reader, 4)) {
                .ok => |bytes| blk: {
                    if (bytes.len < 4) {
                        return Result{ .no_type_eos = Result.NoTypeEos{ .length = length } };
                    }
                    break :blk bytes.slice()[0..4].*;
                },
                .fail => |fail| return Result{ .no_type_err = Result.NoTypeErr{
                    .length = length,
                    .err = fail.err,
                } },
            };

            break :@"type" ChunkType.from(&type_bytes);
        };

        return Result{ .ok = ChunkHeader{
            .length = length,
            .type = @"type",
        } };
    }
};

pub const ChunkMetadata = struct {
    header: ChunkHeader,
    crc: u32,
};
