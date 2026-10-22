//! Short critical sections for Live voice queues (never held across I/O or
//! audio callbacks), in the repo's `std.atomic.Mutex` spin-lock style.

const std = @import("std");

pub const Mutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    pub fn lock(self: *Mutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *Mutex) void {
        self.inner.unlock();
    }
};
