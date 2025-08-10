const std = @import("std");

const vaxis = @import("vaxis");

pub const ctrlseq = @import("./ctrlseq.zig");
pub const tty = @import("./tty.zig");
pub const queue = @import("./queue.zig");
pub const loop = @import("./loop.zig");

pub fn main() !void {
    const alloc = std.heap.page_allocator;

    const out = std.io.getStdOut();
    try out.writer().print(ctrlseq.color.colorStr("Welcome to Minesweeper!\n", ctrlseq.color.red), .{});

    var term = try tty.Tty.init();
    defer term.deinit();

    var lp = try loop.Loop.init(&term);

    try lp.start();
    defer lp.stop();

    var grid = try Grid.init(alloc, 20, 10, 40);
    defer grid.deinit();

    grid.reset();

    try term.anyWriter().print(ctrlseq.alt_screen_enter ++ ctrlseq.cursor_hide ++ ctrlseq.mouse_enable, .{});
    defer term.anyWriter().print(ctrlseq.alt_screen_exit ++ ctrlseq.cursor_show ++ ctrlseq.mouse_disable, .{}) catch {};

    while (true) {
        const event = lp.nextEvent() catch {
            term.anyWriter().print("event error\r\n", .{});
        };

        switch (event) {
            .key_press => |kp| {
                if (kp.codepoint == 'q') break;
                try term.anyWriter().print("{any}\r\n", .{kp});
            },
            .win_size => |ws| {
                if ((ws.col < grid.width) || (ws.row < grid.height)) {
                    try term.anyWriter().print(ctrlseq.erase_display ++ "The terminal is not large enough", .{});
                }
            },
            .mouse => |mouse| {
                try term.anyWriter().print("{any}\r\n", .{mouse});
            },
        }
    }

    // try grid.display(out.writer());

    // var buffer: [100]u8 = undefined;

    // while (true) {
    //     const line = try in.reader().readUntilDelimiterOrEof(
    //         &buffer,
    //         '\n',
    //     ) orelse continue;

    //     // trim annoying windows-only carriage return character
    //     if (@import("builtin").os.tag == .windows) {
    //         line = std.mem.trimRight(u8, line, "\r");
    //     }

    //     const cmd = parseInput(line) catch {
    //         std.debug.print("could not parse input\n", .{});
    //         continue;
    //     };
    //     try out.writer().print("{any} {any}\n", .{ cmd.action, cmd.pos });
    //     const idx = grid.posToIdx(&cmd.pos) catch {
    //         std.debug.print("selected position out of bounds\n", .{});
    //         continue;
    //     };

    //     switch (cmd.action) {
    //         .uncover => {
    //             _ = grid.uncover_cell(idx, true);
    //         },
    //         .flag => {
    //             grid.toggle_flag(idx);
    //         },
    //     }

    //     if (grid.exploded) {
    //         try grid.displayClear(out.writer());
    //         try out.writer().print("You lose!\n", .{});
    //         break;
    //     }

    //     try grid.display(out.writer());
    // }
}

const Position = struct { x: u32, y: u32 };

const Grid = struct {
    const Idx = usize;

    width: u32,
    height: u32,
    nb_of_bombs: u32,

    exploded: bool = false,

    cells: std.ArrayList(Cell),
    prng: std.Random.DefaultPrng,

    fn init(alloc: std.mem.Allocator, width: u32, height: u32, nb_of_bombs: u32) !Grid {
        var cells = std.ArrayList(Cell).init(alloc);

        const prng = std.Random.DefaultPrng.init(0);

        // make all cells default
        const grid_len = width * height;
        try cells.ensureTotalCapacity(grid_len);
        for (0..grid_len) |_| {
            try cells.append(.{});
        }

        return .{ .cells = cells, .width = width, .height = height, .nb_of_bombs = nb_of_bombs, .prng = prng };
    }

    fn deinit(self: *Grid) void {
        self.cells.deinit();
    }

    fn reset(self: *Grid) void {
        var nb_of_bombs = self.nb_of_bombs;

        while (nb_of_bombs != 0) {
            const rpos = self.prng.random().intRangeAtMost(usize, 0, self.cells.items.len - 1);
            const cell = &self.cells.items[rpos];

            switch (cell.content) {
                .count => |_| {
                    nb_of_bombs -= 1;
                    cell.content = .bomb;
                },
                .bomb => continue,
            }
        }

        for (self.cells.items, 0..) |cell, idx| {
            if (cell.content == .bomb) {
                const neighbors = self.neighborsIdx(idx);
                for (neighbors) |neighbor| {
                    self.cells.items[(neighbor orelse continue)].content.incrementCount();
                }
            }
        }
    }

    fn posToIdx(self: *const Grid, pos: *const Position) !Idx {
        std.debug.assert(pos.x <= self.width);
        std.debug.assert(pos.y <= self.height);

        return (pos.y - 1) * self.width + (pos.x - 1);
    }

    fn neighborsIdx(self: *Grid, idx: Idx) [8]?Idx {
        const first_col = idx % self.width == 0;
        const last_col = idx % self.width == (self.width - 1);
        const first_row = idx < self.width;
        const last_row = idx >= self.width * (self.height - 1);

        return .{
            if (!first_col) idx - 1 else null,
            if (!last_col) idx + 1 else null,
            if (!first_row) idx - self.width else null,
            if (!last_row) idx + self.width else null,
            if (!first_col and !first_row) idx - 1 - self.width else null,
            if (!first_col and !last_row) idx - 1 + self.width else null,
            if (!last_col and !first_row) idx + 1 - self.width else null,
            if (!last_col and !last_row) idx + 1 + self.width else null,
        };
    }

    fn display(self: *const Grid, writer: anytype) !void {
        for (self.cells.items, 0..) |cell, idx| {
            try cell.display(writer);
            if (idx % self.width == self.width - 1) try writer.print("\r\n", .{});
        }
    }

    fn displayClear(self: *const Grid, writer: anytype) !void {
        for (self.cells.items, 0..) |cell, idx| {
            if (idx != 0 and idx % self.width == 0) {
                try writer.print("\n", .{});
            }
            try cell.displayContent(writer);
            try writer.print(" ", .{});
        }
        try writer.print("\n", .{});
    }

    fn uncover_cell(self: *Grid, idx: Idx, from_user: bool) void {
        var cell = &self.cells.items[idx];

        if (cell.state == .flagged) return;
        const oldState = cell.state;
        cell.state = .revealed;

        switch (cell.content) {
            .bomb => {
                self.exploded = true;
                return;
            },
            .count => |n| {
                const neighbors = self.neighborsIdx(idx);
                if (oldState == .covered and n == 0) {
                    for (neighbors) |neighbor| self.uncover_cell(neighbor orelse continue, false);
                } else if (oldState == .revealed and n != 0 and from_user) {
                    var count_flags: u32 = 0;
                    for (neighbors) |neighbor| if (self.cells.items[neighbor orelse continue].state == .flagged) {
                        count_flags += 1;
                    };
                    if (count_flags != self.cells.items[idx].content.count) return;
                    for (neighbors) |neighbor| if (self.cells.items[neighbor orelse continue].state == .covered) {
                        self.uncover_cell(neighbor orelse continue, false);
                    };
                }
            },
        }
    }

    fn toggle_flag(self: *Grid, idx: Idx) void {
        const cell = &self.cells.items[idx];

        cell.state = switch (cell.state) {
            .flagged => .covered,
            .covered => .flagged,
            .revealed => .revealed,
        };
    }
};

const Cell = struct {
    state: CellState = .covered,
    content: CellContent = .{ .count = 0 },

    fn display(self: *const Cell, writer: anytype) !void {
        return switch (self.state) {
            .flagged => try writer.print(ctrlseq.color.colorStr("{c}", ctrlseq.color.orange), .{}),
            .covered => try writer.print("-", .{}),
            .revealed => self.displayContent(writer),
        };
    }

    fn displayContent(self: *const Cell, writer: anytype) !void {
        return switch (self.content) {
            .count => |num| if (num == 0) {
                try writer.print("0", .{});
            } else {
                try writer.print(ctrlseq.color.colorStr("{c}", ctrlseq.color.blue), .{num + @as(u8, 48)});
            },
            .bomb => try writer.print(ctrlseq.color.colorStr("*", ctrlseq.color.red), .{}),
        };
    }
};

const CellState = enum {
    flagged,
    covered,
    revealed,
};

const CellContent = union(enum) {
    count: u8,
    bomb,

    fn incrementCount(self: *CellContent) void {
        switch (self.*) {
            .count => |n| {
                self.* = .{ .count = n + 1 };
            },
            .bomb => {},
        }
    }
};

const Action = enum { uncover, flag };

const MinesweeperError = error{ParseError};
