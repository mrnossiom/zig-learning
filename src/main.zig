const std = @import("std");

pub fn main() !void {
    const alloc = std.heap.page_allocator;

    const out = std.io.getStdOut();
    const in = std.io.getStdIn();

    try out.writer().print("Welcome to Minesweeper\n", .{});

    var grid = try Grid.init(alloc, 20, 10, 40);
    defer grid.deinit();

    grid.reset();
    try out.writer().print("Grid initialized\n", .{});

    try grid.display(out.writer());

    var buffer: [100]u8 = undefined;

    while (true) {
        const line = try in.reader().readUntilDelimiterOrEof(
            &buffer,
            '\n',
        ) orelse continue;

        // trim annoying windows-only carriage return character
        if (@import("builtin").os.tag == .windows) {
            line = std.mem.trimRight(u8, line, "\r");
        }

        const cmd = parseInput(line) catch {
            std.debug.print("could not parse input\n", .{});
            continue;
        };
        try out.writer().print("{any} {any}\n", .{ cmd.action, cmd.pos });
        const idx = grid.posToIdx(&cmd.pos) catch {
            std.debug.print("selected position out of bounds\n", .{});
            continue;
        };

        switch (cmd.action) {
            .uncover => {
                _ = grid.uncover_cell(idx, true);
            },
            .flag => {
                grid.toggle_flag(idx);
            },
        }

        if (grid.exploded) {
            try grid.displayClear(out.writer());
            try out.writer().print("You lose!\n", .{});
            break;
        }

        try grid.display(out.writer());
    }
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
        try writer.print("  ", .{});
        for (1..self.width + 1) |i| try writer.print("{: >2}", .{i});
        try writer.print(" x\n", .{});
        for (self.cells.items, 0..) |cell, idx| {
            if (idx % self.width == 0) try writer.print("{: >2} ", .{(idx / self.width) + 1});
            try cell.display(writer);
            try writer.print(" ", .{});
            if (idx % self.width == self.width - 1) try writer.print("{: >2}\n", .{(idx / self.width) + 1});
        }
        try writer.print(" y", .{});
        for (1..self.width + 1) |i| try writer.print("{: >2}", .{i});
        try writer.print("\n", .{});
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
            .flagged => try writer.print("\x1b[35m~\x1b[0m", .{}),
            .covered => try writer.print("-", .{}),
            .revealed => self.displayContent(writer),
        };
    }

    fn displayContent(self: *const Cell, writer: anytype) !void {
        return switch (self.content) {
            .count => |num| if (num == 0) {
                try writer.print("0", .{});
            } else {
                try writer.print(codes.color.colorStr("{c}", codes.color.blue), .{num + @as(u8, 48)});
            },
            .bomb => try writer.print("\x1b[31m*\x1b[0m", .{}),
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

fn parseInput(line: []u8) !struct { action: Action, pos: Position } {
    var parts = std.mem.splitScalar(u8, line, ' ');
    const action_str = parts.next() orelse return error.ParseError;
    const x_str = parts.next() orelse return error.ParseError;
    const y_str = parts.next() orelse return error.ParseError;
    // unsure only two parts were present
    if (parts.next()) |_| return error.ParseError;

    const action: Action = switch (std.meta.stringToEnum(enum { u, f }, action_str) orelse return error.ParseError) {
        .u => .uncover,
        .f => .flag,
    };
    const x = try std.fmt.parseInt(u32, x_str, 10);
    const y = try std.fmt.parseInt(u32, y_str, 10);
    return .{ .action = action, .pos = .{ .x = x, .y = y } };
}

const MinesweeperError = error{ParseError};

const codes = struct {
    fn csi(comptime code: []const u8) []const u8 {
        return "\x1b[" ++ code;
    }

    const color = struct {
        fn colorStr(comptime str: []const u8, comptime clr: []const u8) []const u8 {
            return clr ++ str ++ codes.color.reset;
        }

        const reset = csi("0m");
        const blue = csi("34m");
    };
};
