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
pub fn checkReaderForPngSignature(reader: anytype) CheckReaderForPngSignatureResult(@TypeOf(reader).Error) {
    const Result = CheckReaderForPngSignatureResult(@TypeOf(reader).Error);

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
            return Result{ .invalid_length = Result.InvalidLength{ .invalid_value = naive_value } };
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

pub fn chunkDataStream(reader: anytype) ChunkDataStream(@TypeOf(reader)) {
    return ChunkDataStream(@TypeOf(reader)).init(reader);
}
pub fn ChunkDataStream(comptime ReaderType: type) type {
    return struct {
        const Self = @This();
        reader: ReaderType,
        state: State,

        const State = union(enum) {
            begin,
            awaiting_header,
            awaiting_data: ChunkHeader,
            end,
        };

        pub const ReadError = ReaderType.Error;

        pub fn init(reader: ReaderType) Self {
            return Self{
                .reader = reader,
                .state = .begin,
            };
        }

        pub fn start(self: *Self) CheckReaderForPngSignatureResult(ReadError) {
            switch (self.state) {
                .begin => {},
                .awaiting_header => unreachable,
                .awaiting_data => unreachable,
                .end => unreachable,
            }

            const check_result = checkReaderForPngSignature(self.reader);
            self.state = switch (check_result) {
                .ok => .awaiting_header,
                .invalid_bytes => .end,
                .insufficient_bytes => .end,
                .read_failure => .end,
            };
            return check_result;
        }

        pub const NextHeaderResult = union(enum) {
            ok: ChunkHeader,
            no_type_err: ChunkHeader.ParseReaderResult(ReadError).NoTypeErr,
            no_type_eos: ChunkHeader.ParseReaderResult(ReadError).NoTypeEos,
            invalid_length: ChunkHeader.ParseReaderResult(ReadError).InvalidLength,
            no_length_err: ChunkHeader.ParseReaderResult(ReadError).NoLengthErr,

            pub fn unwrap(self: NextHeaderResult) error{ NoTypeErr, NoTypeEos, InvalidLength, NoLengthErr }!ChunkHeader {
                return switch (self) {
                    .ok => |header| header,
                    .no_type_err => error.NoTypeErr,
                    .no_type_eos => error.NoTypeEos,
                    .invalid_length => error.InvalidLength,
                    .no_length_err => error.NoLengthErr,
                };
            }
        };
        pub fn nextHeader(self: *Self) ?NextHeaderResult {
            const Result = NextHeaderResult;
            switch (self.state) {
                .begin => unreachable,
                .awaiting_header => {},
                .awaiting_data => unreachable,
                .end => return null,
            }

            const parse_result = ChunkHeader.parseReader(self.reader);

            self.state = switch (parse_result) {
                .ok => |header| State{ .awaiting_data = header },
                else => .end,
            };
            return switch (parse_result) {
                .ok => |header| Result{ .ok = header },
                .no_type_err => |info| Result{ .no_type_err = info },
                .no_type_eos => |info| Result{ .no_type_eos = info },
                .invalid_length => |info| Result{ .invalid_length = info },
                .no_length_err => |info| Result{ .no_length_err = info },
                .no_length_eos => null,
            };
        }

        pub fn StreamDataResult(comptime WriteError: type) type {
            return union(enum) {
                ok: Ok,

                missing_crc_bytes_eos: MissingCrcBytesEos,
                missing_crc_bytes_err: MissingCrcBytesErr,

                data_write_fail: DataWriteFail,
                data_read_partial: DataReadPartial,
                data_read_partial_write_fail: DataReadPartialWriteFail,
                data_read_fail: DataReadFail,
                data_read_fail_write_fail: DataReadFailWriteFail,

                pub const Ok = struct {
                    crc: u32,
                };
                pub const MissingCrcBytesEos = struct {
                    bytes: util.ReadBoundedArrayExtraResult(WriteError, 4).Fail.Bytes,
                };
                pub const MissingCrcBytesErr = util.ReadBoundedArrayExtraResult(ReadError, 4).Fail;
                pub const DataWriteFail = struct {
                    bytes_read: u31,
                    bytes_written: u31,
                    write_err: WriteError,
                };
                pub const DataReadPartial = struct {
                    bytes_read: u31,
                };
                pub const DataReadPartialWriteFail = struct {
                    bytes_read: u31,
                    bytes_written: u31,
                    write_err: WriteError,
                };
                pub const DataReadFail = struct {
                    bytes_read: u31,
                    read_err: ReadError,
                };
                pub const DataReadFailWriteFail = struct {
                    bytes_read: u31,
                    bytes_written: u31,
                    read_err: ReadError,
                    write_err: WriteError,
                };

                pub const UnwrapError = error{
                    MissingCrcBytesEos,
                    MissingCrcBytesErr,
                    DataWriteFail,
                    DataReadPartial,
                    DataReadPartialWriteFail,
                    DataReadFail,
                    DataReadFailWriteFail,
                };
                /// Returns the CRC or an error corresponding to the union tag.
                pub fn unwrap(self: @This()) UnwrapError!u32 {
                    return switch (self) {
                        .ok => |ok| ok.crc,
                        .missing_crc_bytes_eos => error.MissingCrcBytesEos,
                        .missing_crc_bytes_err => error.MissingCrcBytesErr,
                        .data_write_fail => error.DataWriteFail,
                        .data_read_partial => error.DataReadPartial,
                        .data_read_partial_write_fail => error.DataReadPartialWriteFail,
                        .data_read_fail => error.DataReadFail,
                        .data_read_fail_write_fail => error.DataReadFailWriteFail,
                    };
                }
            };
        }
        pub fn streamDataWithBuffer(
            self: *Self,
            writer: anytype,
            intermediate_buffer: []u8,
        ) StreamDataResult(@TypeOf(writer).Error) {
            const Result = StreamDataResult(@TypeOf(writer).Error);
            const header: ChunkHeader = switch (self.state) {
                .begin => unreachable,
                .awaiting_header => unreachable,
                .awaiting_data => |header| header,
                .end => unreachable,
            };

            self.state = .end;
            return switch (util.readIntoWriterEagerlyWithBuffer(writer, self.reader, header.length, intermediate_buffer)) {
                .ok => switch (util.readBoundedArrayExtra(self.reader, 4)) {
                    .ok => |bytes| switch (bytes.len) {
                        4 => blk: {
                            self.state = .awaiting_header;
                            break :blk Result{ .ok = Result.Ok{
                                .crc = std.mem.readIntBig(u32, bytes.buffer[0..]),
                            } };
                        },
                        0...3 => Result{ .missing_crc_bytes_eos = Result.MissingCrcBytesEos{
                            .bytes = std.BoundedArray(u8, 4 - 1).fromSlice(bytes.constSlice()) catch unreachable,
                        } },
                        else => unreachable,
                    },
                    .fail => |fail| Result{ .missing_crc_bytes_err = fail },
                },
                .write_fail => |write_fail| Result{ .data_write_fail = Result.DataWriteFail{
                    .bytes_read = @intCast(u31, write_fail.bytes_read),
                    .bytes_written = @intCast(u31, write_fail.bytes_written),
                    .write_err = write_fail.write_err,
                } },
                .read_partial => |read_partial| Result{ .data_read_partial = Result.DataReadPartial{
                    .bytes_read = @intCast(u31, read_partial.bytes_read),
                } },
                .read_partial_write_fail => |info| Result{ .data_read_partial_write_fail = Result.DataReadPartialWriteFail{
                    .bytes_read = @intCast(u31, info.bytes_read),
                    .bytes_written = @intCast(u31, info.bytes_written),
                    .write_err = info.write_err,
                } },
                .read_fail => |read_fail| Result{ .data_read_fail = Result.DataReadFail{
                    .bytes_read = @intCast(u31, read_fail.bytes_read),
                    .read_err = read_fail.read_err,
                } },
                .read_fail_write_fail => |info| Result{ .data_read_fail_write_fail = Result.DataReadFailWriteFail{
                    .bytes_read = @intCast(u31, info.bytes_read),
                    .bytes_written = @intCast(u31, info.bytes_written),
                    .read_err = info.read_err,
                    .write_err = info.write_err,
                } },
            };
        }
    };
}

test {
    const data = @embedFile("img1.png");
    var data_stream = std.io.fixedBufferStream(data);

    var chunk_data_stream = chunkDataStream(data_stream.reader());

    var intermediate_buf_cache = std.ArrayList(u8).init(std.testing.allocator);
    defer intermediate_buf_cache.deinit();

    var raw_data_list = std.ArrayList(u8).init(std.testing.allocator);
    defer raw_data_list.deinit();

    try chunk_data_stream.start().unwrap();
    while (chunk_data_stream.nextHeader()) |maybe_header| {
        const header = try maybe_header.unwrap();

        try intermediate_buf_cache.resize(header.length);

        const current_chunk_start = raw_data_list.items.len;
        const crc = try chunk_data_stream.streamDataWithBuffer(raw_data_list.writer(), intermediate_buf_cache.items).unwrap();

        var crc_hasher = std.hash.Crc32.init();
        crc_hasher.update(&std.mem.toBytes(header.type.intBig()));
        crc_hasher.update(raw_data_list.items[current_chunk_start..]);
        try std.testing.expectEqual(crc_hasher.final(), crc);
    }
}
