const std = @import("std");
const posix = std.posix;

const root = @import("root");
const tty = root.tty;
const queue = root.queue;

const SigHandler = struct {
    ctx: *anyopaque,
    handlerFn: *const fn (ctx: *anyopaque) void,
};

pub const Loop = struct {
    queue: queue.Queue(Event, 16) = .init(),

    tty: *root.tty.Tty,
    thread: ?std.Thread = null,
    should_stop: std.atomic.Value(bool) = .init(false),

    const Self = @This();

    pub fn init(term: *tty.Tty) !Self {
        return .{ .tty = term };
    }

    pub fn start(self: *Self) !void {
        self.registerWinSizeChange();
        self.thread = try std.Thread.spawn(.{}, Self.run, .{self});
    }

    pub fn stop(self: *Self) void {
        self.should_stop.store(true, .release);
        // deinit memmory on foreign thread
    }

    var handler: ?SigHandler = null;

    pub fn registerWinSizeChange(self: *Self) void {
        handler = .{ .ctx = self, .handlerFn = Self.handleWinSizeChange };

        // setup signal handler for window size change
        const action = posix.Sigaction{
            .handler = .{ .handler = Self.handleWinSizeSig },
            .mask = posix.empty_sigset,
            .flags = 0,
        };
        posix.sigaction(posix.SIG.WINCH, &action, null);
    }

    fn handleWinSizeSig(_: c_int) callconv(.c) void {
        if (handler) |hdl| hdl.handlerFn(hdl.ctx);
    }

    fn handleWinSizeChange(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const win_size = self.tty.getWinsize() catch unreachable;
        self.queue.push_front(.{ .win_size = win_size });
    }

    fn parseEvent(buf: []const u8) !?Event {
        switch (buf.len) {
            0 => unreachable,
            1 => {
                // single key press
                return .{ .key_press = .{ .codepoint = buf[0] } };
            },
            6 => {
                if (std.mem.eql(u8, buf[0..3], "\x1b[M")) {
                    // csi code
                    return .{ .mouse = .{ .button = @enumFromInt(buf[3] & 0b11), .x = buf[4] - 32, .y = buf[5] - 32 } };
                } else {
                    // not handled, discard
                    std.debug.print("{any}\r\n", .{buf});
                    return null;
                }
            },
            else => {
                std.debug.print("{any}\r\n", .{buf});
                return null;
            },
        }
    }

    fn run(self: *Self) !void {
        while (true) {
            var buf: [10]u8 = undefined;
            // just pray for the read to be fast enough
            const len = try self.tty.anyReader().read(&buf);

            const ev = try Self.parseEvent(buf[0..len]) orelse continue;
            self.queue.push_front(ev);
        }
    }

    pub fn nextEvent(self: *Self) !Event {
        return self.queue.pop_back();
    }
};

pub const Event = union(enum) {
    key_press: Key,
    win_size: WinSize,
    mouse: Mouse,
};

pub const Key = struct { codepoint: u8 };
pub const WinSize = struct { row: u16, col: u16 };
pub const Mouse = struct { button: MouseButton, x: u16, y: u16 };
pub const MouseButton = enum(u2) { left = 0, middle = 1, right = 2, release = 3 };
