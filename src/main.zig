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

        const cmd = parse_input(line) catch |erro| {
            std.debug.print("{}: could not parse input\n", .{erro});
            continue;
        };
        try out.writer().print("{any} {any}\n", .{ cmd.action, cmd.pos });
        const idx = try grid.pos_to_idx(&cmd.pos);

        const do_explode = grid.uncover(idx, true);

        if (do_explode) {
            try grid.display_clear(out.writer());
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
                const neighbors = self.neighbors_idx(idx);
                for (neighbors) |neighbor| {
                    self.cells.items[(neighbor orelse continue)].content.increment_count();
                }
            }
        }
    }

    fn pos_to_idx(self: *const Grid, pos: *const Position) !Idx {
        std.debug.assert(pos.x <= self.width);
        std.debug.assert(pos.y <= self.height);

        return (pos.y - 1) * self.width + (pos.x - 1);
    }

    fn neighbors_idx(self: *Grid, idx: Idx) [8]?Idx {
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
            if (idx != 0 and idx % self.width == 0) {
                try writer.print("\n", .{});
            }
            try writer.print("{c} ", .{cell.display()});
        }
        try writer.print("\n", .{});
    }

    fn display_clear(self: *const Grid, writer: anytype) !void {
        for (self.cells.items, 0..) |cell, idx| {
            if (idx != 0 and idx % self.width == 0) {
                try writer.print("\n", .{});
            }
            try writer.print("{c} ", .{cell.display_content()});
        }
        try writer.print("\n", .{});
    }

    fn uncover(self: *Grid, idx: Idx, from_user: bool) bool {
        var cell = &self.cells.items[idx];

        if (cell.state == .flagged) return false;
        const oldState = cell.state;
        cell.state = .revealed;

        switch (cell.content) {
            .bomb => return true,
            .count => |n| {
                const next = self.neighbors_idx(idx);
                if (oldState == .covered and n == 0) {
                    var exploded = false;
                    for (next) |ne| {
                        exploded = exploded or self.uncover(ne orelse continue, false);
                    }
                    return exploded;
                } else if (oldState == .revealed and n != 0 and from_user) {
                    // uncover if n == neighbors.flags.len
                    @panic("todo");
                }

                return false;
            },
        }
    }
};

const Cell = struct {
    state: CellState = .covered,
    content: CellContent = .{ .count = 0 },

    fn display(self: *const Cell) u8 {
        return switch (self.state) {
            .flagged => '~',
            .covered => '_',
            .revealed => self.display_content(),
        };
    }

    fn display_content(self: *const Cell) u8 {
        return switch (self.content) {
            .count => |num| num + @as(u8, 48),
            .bomb => @as(u8, '*'),
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

    fn increment_count(self: *CellContent) void {
        switch (self.*) {
            .count => |n| {
                self.* = .{ .count = n + 1 };
            },
            .bomb => {},
        }
    }
};

fn parse_input(line: []u8) !struct { action: enum { uncover, flag }, pos: Position } {
    var parts = std.mem.splitScalar(u8, line, ' ');
    const x_str = parts.next() orelse return error.ParseError;
    const y_str = parts.next() orelse return error.ParseError;
    // unsure only two parts were present
    if (parts.next()) |_| return error.ParseError;
    const x = try std.fmt.parseInt(u32, x_str, 10);
    const y = try std.fmt.parseInt(u32, y_str, 10);
    return .{ .action = .uncover, .pos = .{ .x = x, .y = y } };
}

const err = error{ParseError};
