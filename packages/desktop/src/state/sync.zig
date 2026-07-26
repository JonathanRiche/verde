//! Small synchronization wrappers shared by state substates.

const std = @import("std");

pub const Mutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    pub fn tryLock(self: *Mutex) bool {
        return self.inner.tryLock();
    }

    pub fn lock(self: *Mutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *Mutex) void {
        self.inner.unlock();
    }
};

pub const Condition = struct {
    pub fn wait(_: *Condition, mutex: *Mutex) void {
        mutex.unlock();
        std.atomic.spinLoopHint();
        mutex.lock();
    }

    pub fn broadcast(_: *Condition) void {}
};
