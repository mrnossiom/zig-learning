const std = @import("std");

pub fn Queue(
    comptime T: type,
    comptime size: usize,
) type {
    return struct {
        buf: [size]T = undefined,

        len: usize = 0,
        tail_idx: usize = 0,

        mutex: std.Thread.Mutex = .{},
        not_full: std.Thread.Condition = .{},
        not_empty: std.Thread.Condition = .{},

        const Self = @This();

        pub fn init() Self {
            return .{};
        }

        pub fn pushFront(self: *Self, el: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.len == size) {
                self.not_full.wait(&self.mutex);
            }

            if (self.len == 0) {
                self.not_empty.signal();
            }

            self.buf[(self.tail_idx + self.len) % size] = el;
            self.len += 1;
        }

        pub fn popBack(self: *Self) T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.len == 0) {
                self.not_empty.wait(&self.mutex);
            }

            if (self.len == size) {
                self.not_full.signal();
            }

            const el = self.buf[self.tail_idx];
            self.len -= 1;
            self.tail_idx = (self.tail_idx + 1) % size;

            return el;
        }
    };
}

test "queue" {
    var queue = Queue(u8, 2).init();

    queue.pushFront(1);
    queue.pushFront(2);
    const el1 = queue.popBack();
    std.debug.assert(el1 == 1);
    queue.pushFront(3);
}
