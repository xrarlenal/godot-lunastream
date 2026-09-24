test "engine object survives a temporary Ref taken by an engine call" {
    const resource = Resource.init();
    try testing.expectEqual(@as(i32, 1), resource.getReferenceCount());

    // ResourceSaver.getRecognizedExtensions takes its `Resource` argument by
    // `const Ref<Resource> &` on the engine side. Godot constructs a temporary
    // Ref<Resource> around our raw pointer for the duration of this call, and
    // releases it before returning. If init() left the object's "pending"
    // ref uninitialized, this temporary Ref is treated as the first-ever
    // wrap, and releasing it drops the refcount to zero and frees the object
    // out from under us.
    var extensions = ResourceSaver.getRecognizedExtensions(resource);
    defer extensions.deinit();

    try testing.expectEqual(@as(i32, 1), resource.getReferenceCount());

    try testing.expect(resource.unreference());
    resource.destroy();
}

test "variant reference counting" {
    const object = RefCounted.init();
    try testing.expectEqual(@as(i32, 1), object.getReferenceCount());

    const variant = Variant.init(*RefCounted, object);
    try testing.expectEqual(@as(i32, 2), object.getReferenceCount());

    for (0..10) |_| {
        general.print(variant, .{ object, variant });
    }

    try testing.expectEqual(@as(i32, 2), object.getReferenceCount());
    variant.deinit();
    try testing.expectEqual(@as(i32, 1), object.getReferenceCount());
    try testing.expect(object.unreference());
    object.destroy();
}

test "varcall adopts a builtin return value" {
    const Returner = struct {
        payload: *RefCounted,

        /// Builds a fresh `Array` holding one reference to `payload` and hands
        /// ownership of it to the caller, the way `ptrcall` already expects.
        pub fn makeArray(self: *@This()) Array {
            var array = Array.init();
            const boxed = Variant.init(*RefCounted, self.payload);
            defer boxed.deinit();
            array.append(boxed);
            return array;
        }
    };

    const object = RefCounted.init();
    try testing.expectEqual(@as(i32, 1), object.getReferenceCount());

    var returner: Returner = .{ .payload = object };
    const config = gdzig.extension.testing.MethodConfig(Returner).fromName("make_array", "makeArray", .{});

    const no_args: []const *const Variant = &.{};
    const variant = try config.call.?(&returner, no_args);

    // The Array now inside the Variant holds the only reference to `object`
    // besides our own.
    try testing.expectEqual(@as(i32, 2), object.getReferenceCount());

    // Destroying the Variant has to destroy that Array, which it can only do if
    // `call` released the callee's own handle after boxing it. `Variant.init`
    // copies rather than moves, so without that release the Array outlives the
    // Variant and keeps `object` referenced forever.
    variant.deinit();
    try testing.expectEqual(@as(i32, 1), object.getReferenceCount());

    try testing.expect(object.unreference());
    object.destroy();
}

const std = @import("std");
const testing = std.testing;

const gdzig = @import("gdzig");
const general = gdzig.general;
const Array = gdzig.builtin.Array;
const RefCounted = gdzig.class.RefCounted;
const Resource = gdzig.class.Resource;
const ResourceSaver = gdzig.class.ResourceSaver;
const Variant = gdzig.builtin.Variant;
