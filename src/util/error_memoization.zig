const std = @import("std");

/// Returns an error set comprised of the provided error value.
/// E.g. `ErrorSetFromValue(error.Foo)` => `error{Foo}`.
pub fn ErrorSetFromValue(comptime err: anyerror) type {
    const Type = std.builtin.Type;
    return @Type(Type{
        .ErrorSet = &[_]Type.Error{.{ .name = @errorName(err) }},
    });
}

/// Returns an error set comprised of the provided error values.
/// E.g. `ErrorSetFromValues(&.{ Foo, Bar })` => `error{ Foo, Bar }`.
/// NOTE: result is memoized to the values given, in the order they are given,
/// so the following assertions can be made:
/// ```
/// const a = error.A;
/// const b = error.B;
/// std.debug.assert(ErrorSetFromValues(&.{ a, b }) == ErrorSetFromValues(&.{ a, b }));
/// std.debug.assert(ErrorSetFromValues(&.{ a, b }) != ErrorSetFromValues(&.{ b, a }));
/// ```
pub fn ErrorSetFromValues(comptime errors: []const anyerror) type {
    return ErrorSetFromValuesImpl(errors.len, errors[0..errors.len].*);
}
fn ErrorSetFromValuesImpl(
    comptime error_count: comptime_int,
    comptime error_values: [error_count]anyerror,
) type {
    var ErrorSet = error{};
    for (error_values) |val| ErrorSet = ErrorSet || ErrorSetFromValue(val);
    return ErrorSet;
}

/// Returns an error set comprised of the error values pertaining to the
/// provided error set, with the effect of returning a memoized type value;
/// that is to say, the following assertions can be made:
/// ```
/// std.debug.assert(MemoizeErrorSet(error{ A, B }) == MemoizeErrorSet(error{ A, B }));
/// std.debug.assert(MemoizeErrorSet(error{ A, B }) == MemoizeErrorSet(error{ B, A }));
/// ```
pub fn MemoizeErrorSet(comptime ErrorSet: anytype) type {
    const info = @typeInfo(ErrorSet).ErrorSet orelse return anyerror;
    if (info.len == 0) return error{};

    var errors: [info.len]anyerror = .{undefined} ** info.len;
    for (info) |err, i| errors[i] = @field(ErrorSet, err.name);
    std.sort.sort(anyerror, &errors, void{}, struct {
        fn lessThan(ctx: void, lhs: anyerror, rhs: anyerror) bool {
            ctx;
            return std.mem.lessThan(u8, @errorName(lhs), @errorName(rhs));
        }
    }.lessThan);

    return ErrorSetFromValues(&errors);
}
