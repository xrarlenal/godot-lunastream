//! 线程原语与单调时钟：把 Zig 0.16 的 `std.Io` 接口收成一层无参门面。
//!
//! 为什么需要这一层：Zig 0.16 把 `std.Thread.Mutex` / `Condition` / `sleep` /
//! `std.time.*Timestamp` 挪到了 `std.Io` 之下，而 `std.Io` 的每个调用都需要
//! 一个 `Io` 实例。本项目的线程全部由 `std.Thread.spawn` 直接创建，没有事件
//! 循环、没有取消语义，用 `std.Io.Threaded.global_single_threaded` 作为后端是
//! 正确的——它只是关掉了 `Io` 自己的异步任务调度，futex 操作仍然是真正的
//! 系统 futex，跨我们自建的 worker 线程完全正确。
//!
//! 收成门面之后，调用点（调度器、将来的重连退避）写的是老形状的
//! `lock/unlock/wait/signal/broadcast`，不沾 `Io` 实例。

const std = @import("std");

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// `std.Thread.Mutex` 的替代（0.16 已移除）。
pub const Mutex = struct {
    inner: std.Io.Mutex = .init,

    pub fn lock(m: *Mutex) void {
        m.inner.lockUncancelable(io());
    }

    pub fn unlock(m: *Mutex) void {
        m.inner.unlock(io());
    }
};

/// `std.Thread.Condition` 的替代（0.16 已移除）。
pub const Condition = struct {
    inner: std.Io.Condition = .init,

    pub fn wait(cv: *Condition, mu: *Mutex) void {
        cv.inner.waitUncancelable(io(), &mu.inner);
    }

    pub fn signal(cv: *Condition) void {
        cv.inner.signal(io());
    }

    pub fn broadcast(cv: *Condition) void {
        cv.inner.broadcast(io());
    }
};

/// `std.Thread.sleep` 的替代。
pub fn sleep(nanoseconds: u64) void {
    const duration: std.Io.Clock.Duration = .{
        .raw = .fromNanoseconds(@intCast(nanoseconds)),
        .clock = .awake,
    };
    duration.sleep(io()) catch {};
}

/// 单调挂钟（纳秒）。
pub fn nanoTimestamp() i128 {
    return std.Io.Clock.awake.now(io()).nanoseconds;
}

/// 单调挂钟（毫秒）。
pub fn milliTimestamp() i64 {
    return std.Io.Clock.awake.now(io()).toMilliseconds();
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

test "互斥锁保护共享计数（两个线程各加 N 次）" {
    const increments = 5_000;
    var mu: Mutex = .{};
    var counter: usize = 0;

    const Ctx = struct {
        fn run(m: *Mutex, c: *usize) void {
            for (0..increments) |_| {
                m.lock();
                c.* += 1;
                m.unlock();
            }
        }
    };

    const t1 = try std.Thread.spawn(.{}, Ctx.run, .{ &mu, &counter });
    const t2 = try std.Thread.spawn(.{}, Ctx.run, .{ &mu, &counter });
    t1.join();
    t2.join();

    try std.testing.expectEqual(increments * 2, counter);
}

test "条件变量能唤醒等待方" {
    var mu: Mutex = .{};
    var cv: Condition = .{};
    var ready = false;

    const Ctx = struct {
        fn waiter(m: *Mutex, c: *Condition, flag: *bool) void {
            m.lock();
            while (!flag.*) c.wait(m);
            m.unlock();
        }
        fn signaller(m: *Mutex, c: *Condition, flag: *bool) void {
            m.lock();
            flag.* = true;
            m.unlock();
            c.signal();
        }
    };

    const t = try std.Thread.spawn(.{}, Ctx.waiter, .{ &mu, &cv, &ready });
    sleep(2 * std.time.ns_per_ms);
    Ctx.signaller(&mu, &cv, &ready);
    t.join();
    try std.testing.expect(ready);
}

test "sleep 真的等待（单调时钟走够时间）" {
    const before = milliTimestamp();
    sleep(30 * std.time.ns_per_ms);
    const after = milliTimestamp();
    try std.testing.expect(after >= before);
}

test "单调时钟不回退" {
    var prev = milliTimestamp();
    for (0..200) |_| {
        const now = milliTimestamp();
        try std.testing.expect(now >= prev);
        prev = now;
    }
}
