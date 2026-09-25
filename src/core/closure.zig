//! 类型擦除的回调。
//!
//! Zig 没有捕获闭包，所以"回调"在这里就是一对值：上下文指针 + 函数指针。
//! 空值（`func == null`）表示"没有回调"，`call()` 会安全地忽略它——这让调用方
//! 不必到处写 `if (hook != null)`。
//!
//! 之所以要把它单独成一个模块：帧的释放钩子（`release_hook`）与解码后端的
//! 接口都要用它，谁先实现都不该把定义拴在自己身上。

const std = @import("std");

pub const VoidClosure = struct {
    ctx: ?*anyopaque = null,
    func: ?*const fn (?*anyopaque) void = null,

    pub fn call(self: VoidClosure) void {
        if (self.func) |f| f(self.ctx);
    }

    /// 语义化的空判断。直接写 `slot.func != null` 也能编译，但读代码的人
    /// 需要先知道内部字段的含义；方法名把意图讲清楚。
    pub fn isEmpty(self: VoidClosure) bool {
        return self.func == null;
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

test "空闭包的 call 是安全空操作" {
    const empty: VoidClosure = .{};
    try std.testing.expect(empty.isEmpty());
    empty.call(); // 不崩即为通过
}

test "闭包携带上下文并被调用" {
    var hits: i32 = 0;
    const Ctx = struct {
        fn bump(p: ?*anyopaque) void {
            const counter: *i32 = @ptrCast(@alignCast(p.?));
            counter.* += 1;
        }
    };

    const hook: VoidClosure = .{ .ctx = &hits, .func = Ctx.bump };
    try std.testing.expect(!hook.isEmpty());
    hook.call();
    hook.call();
    try std.testing.expectEqual(@as(i32, 2), hits);
}

test "只给函数不给上下文时，回调仍被调用并收到 null" {
    const Probe = struct {
        var called_with_null: bool = false;

        fn mark(p: ?*anyopaque) void {
            called_with_null = (p == null);
        }
    };
    Probe.called_with_null = false;

    const hook: VoidClosure = .{ .ctx = null, .func = Probe.mark };
    try std.testing.expect(!hook.isEmpty());
    hook.call();
    try std.testing.expect(Probe.called_with_null);
}
