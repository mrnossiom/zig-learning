const std = @import("std");
const fs = std.fs;
const posix = std.posix;

const root = @import("root");
const loop = root.loop;
const queue = root.queue;
const ctrlseq = root.ctrlseq;

pub const Tty = if (@import("builtin").os.tag == .linux) PosixTty else @compileError("os not supported");

/// Manages a posix tty. Making it easy to manipulate raw features.
pub const PosixTty = struct {
    fd: posix.fd_t,

    initial_termios: posix.termios,

    pub fn init() !PosixTty {
        // get the current terminal
        const fd = try posix.open("/dev/tty", .{ .ACCMODE = .RDWR }, 0);
        const initial_termios = try makeRaw(fd);

        return .{ .fd = fd, .initial_termios = initial_termios };
    }

    pub fn deinit(self: *PosixTty) void {
        // reset terminal properties
        posix.tcsetattr(self.fd, .FLUSH, self.initial_termios) catch {};
        // close the tty handle
        posix.close(self.fd);
        // remove the sigaction handler
        posix.sigaction(posix.SIG.WINCH, null, null);
    }

    fn makeRaw(fd: posix.fd_t) !posix.termios {
        const initial = try posix.tcgetattr(fd);

        var next = initial;
        // see termios(3)
        next.iflag.BRKINT = false;
        next.iflag.ICRNL = false;
        next.iflag.IGNBRK = false;
        next.iflag.IGNCR = false;
        next.iflag.INLCR = false;
        next.iflag.ISTRIP = false;
        next.iflag.IXON = false;
        next.iflag.PARMRK = false;

        // don't post-process output
        next.oflag.OPOST = false;

        next.lflag.ECHO = false;
        next.lflag.ECHONL = false;
        next.lflag.ICANON = false;
        next.lflag.IEXTEN = false;
        next.lflag.ISIG = false;

        next.cflag.CSIZE = .CS8;
        next.cflag.PARENB = false;
        try posix.tcsetattr(fd, .FLUSH, next);

        return initial;
    }

    pub fn getWinsize(self: *const PosixTty) !loop.WinSize {
        var winsize = posix.winsize{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };

        // see tiocgwincz(2const)
        const err = posix.system.ioctl(self.fd, posix.T.IOCGWINSZ, @intFromPtr(&winsize));
        if (posix.errno(err) != .SUCCESS) return error.IoError;
        return .{ .row = winsize.row, .col = winsize.col };
    }

    fn readOpaque(ctx: *const anyopaque, buf: []u8) !usize {
        const self: *const PosixTty = @ptrCast(@alignCast(ctx));
        return try posix.read(self.fd, buf);
    }

    fn writeOpaque(ctx: *const anyopaque, bytes: []const u8) !usize {
        const self: *const PosixTty = @ptrCast(@alignCast(ctx));
        return try posix.write(self.fd, bytes);
    }

    pub fn anyReader(self: *const PosixTty) std.io.AnyReader {
        return std.io.AnyReader{ .context = self, .readFn = PosixTty.readOpaque };
    }

    pub fn anyWriter(self: *const PosixTty) std.io.AnyWriter {
        return std.io.AnyWriter{ .context = self, .writeFn = PosixTty.writeOpaque };
    }

    pub fn enterGameScreen(self: *PosixTty) !void {
        try self.anyWriter().print(ctrlseq.alt_screen_enter ++ ctrlseq.cursor_hide ++ ctrlseq.mouse_enable, .{});
    }
    pub fn exitGameScreen(self: *PosixTty) !void {
        try self.anyWriter().print(ctrlseq.alt_screen_exit ++ ctrlseq.cursor_show ++ ctrlseq.mouse_disable, .{});
    }
};
