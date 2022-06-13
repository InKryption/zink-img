const std = @import("std");
pub const png = @import("png.zig");

const HalfUsize = std.meta.Int(
    .unsigned,
    @divExact(@typeInfo(usize).Int.bits, 2),
);
const FullUsize = std.meta.Int(
    .unsigned,
    @typeInfo(HalfUsize).Int.bits * 2,
);
fn mulHalfUsize(a: HalfUsize, b: HalfUsize) FullUsize {
    return std.math.mulWide(HalfUsize, a, b);
}

pub const Image = struct {
    /// Prefer calling the `bytes` method, as opposed to accessing this field directly.
    p_bytes: [*]u8,
    width: HalfUsize,
    height: HalfUsize,
    channels: u2,

    pub fn initBuffer(buffer: []u8, width: HalfUsize, height: HalfUsize, channels: u2) Image {
        const result = Image{
            .p_bytes = buffer.ptr,
            .width = width,
            .height = height,
            .channels = channels,
        };
        std.debug.assert(result.len() <= buffer.len);
        return result;
    }

    /// Caller owns memory; should call `Image.free` on the return value.
    pub fn dupe(image: Image, allocator: std.mem.Allocator) std.mem.Allocator.Error!Image {
        const duped_bytes = try allocator.dupe(u8, image.bytes());
        errdefer allocator.free(duped_bytes);

        return Image{
            .p_bytes = duped_bytes.ptr,
            .width = image.width,
            .height = image.height,
            .channels = image.channels,
        };
    }

    pub fn free(image: Image, allocator: std.mem.Allocator) void {
        allocator.free(image.bytes());
    }

    pub fn len(image: Image) FullUsize {
        return mulHalfUsize(image.width, image.height);
    }

    pub fn bytes(image: Image) []u8 {
        return image.p_bytes[0..image.len()];
    }

    pub fn scanline(image: Image, y: HalfUsize) []u8 {
        const start_index = xyToScalar(0, y, .{ .w = image.width });
        return image.bytes()[start_index..][0..image.width];
    }

    fn xyToScalar(
        x: HalfUsize,
        y: HalfUsize,
        img: struct {
            w: HalfUsize,
            h: HalfUsize = std.math.maxInt(HalfUsize),
        },
    ) FullUsize {
        std.debug.assert( // Simple Sanity Check
            (x < img.w or (x == img.w and y < img.h)) and
            (y < img.h or (y == img.h and x < img.w)));
        return @as(FullUsize, x) + mulHalfUsize(img.w, y);
    }
};

test {
}
