const csi = "\x1b[";

pub const erase_display_cursor_to_end = csi ++ "0J";
pub const erase_display_start_to_cursor = csi ++ "1J";
pub const erase_display = csi ++ "2J";

pub const cursor_show = csi ++ "?25h";
pub const cursor_hide = csi ++ "?25l";

pub const mouse_enable = csi ++ "?1000h";
pub const mouse_disable = csi ++ "?1000l";

pub const alt_screen_enter = csi ++ "?1049h";
pub const alt_screen_exit = csi ++ "?1049l";

pub const color = struct {
    pub fn colorStr(comptime str: []const u8, comptime clr: []const u8) []const u8 {
        return clr ++ str ++ color.reset;
    }

    pub const reset = csi ++ "0m";
    pub const red = csi ++ "31m";
    pub const blue = csi ++ "34m";
    pub const orange = csi ++ "35m";
};
