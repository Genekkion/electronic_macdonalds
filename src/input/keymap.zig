const std = @import("std");
const event = @import("event.zig");
pub const Modifiers = event.Modifiers;
pub const KeyCode = event.KeyCode;
pub const KeyEvent = event.KeyEvent;

pub const KeyCombo = struct {
    code: KeyCode,
    mods: Modifiers = .{},
    char: ?u8 = null,

    pub fn parse(combo_str: []const u8) ?KeyCombo {
        if (combo_str.len == 0) return null;

        // Simple single-char key: "a", "1", "/"
        if (combo_str.len == 1 and combo_str[0] != '<') {
            return .{
                .code = .character,
                .mods = .{},
                .char = combo_str[0],
            };
        }

        // Bracketed combo: "<C-f>", "<Return>"
        if (combo_str[0] == '<' and combo_str[combo_str.len - 1] == '>') {
            const inner = combo_str[1 .. combo_str.len - 1];
            var mods = Modifiers{};

            var iter = std.mem.splitScalar(u8, inner, '-');
            var last_token: []const u8 = "";

            while (iter.next()) |token| {
                if (iter.peek() != null) {
                    if (std.mem.eql(u8, token, "C") or std.mem.eql(u8, token, "Ctrl")) {
                        mods.control = true;
                    } else if (std.mem.eql(u8, token, "M") or std.mem.eql(u8, token, "Alt")) {
                        mods.alt = true;
                    } else if (std.mem.eql(u8, token, "S") or std.mem.eql(u8, token, "Shift")) {
                        mods.shift = true;
                    } else if (std.mem.eql(u8, token, "Cmd") or std.mem.eql(u8, token, "Super")) {
                        mods.command = true;
                    }
                } else {
                    last_token = token;
                }
            }

            if (last_token.len == 1) {
                return .{
                    .code = .character,
                    .mods = mods,
                    .char = last_token[0],
                };
            }

            const code: ?KeyCode = if (std.mem.eql(u8, last_token, "Return") or std.mem.eql(u8, last_token, "Enter"))
                .enter
            else if (std.mem.eql(u8, last_token, "Backspace"))
                .backspace
            else if (std.mem.eql(u8, last_token, "Tab"))
                .tab
            else if (std.mem.eql(u8, last_token, "Escape") or std.mem.eql(u8, last_token, "Esc"))
                .escape
            else if (std.mem.eql(u8, last_token, "Left"))
                .left
            else if (std.mem.eql(u8, last_token, "Right"))
                .right
            else if (std.mem.eql(u8, last_token, "Up"))
                .up
            else if (std.mem.eql(u8, last_token, "Down"))
                .down
            else
                null;

            if (code) |c| {
                return .{
                    .code = c,
                    .mods = mods,
                    .char = null,
                };
            }
        }

        return null;
    }

    pub fn matches(self: KeyCombo, ev: KeyEvent) bool {
        if (self.code != ev.code) return false;
        if (self.mods.control != ev.mods.control) return false;
        if (self.mods.alt != ev.mods.alt) return false;
        if (self.mods.shift != ev.mods.shift) return false;
        if (self.mods.command != ev.mods.command) return false;
        if (self.code == .character) {
            return self.char == ev.char;
        }
        return true;
    }
};

const testing = std.testing;

test "test_parse_single_character_key" {
    const combo = KeyCombo.parse("a").?;
    try testing.expectEqual(KeyCode.character, combo.code);
    try testing.expectEqual(@as(?u8, 'a'), combo.char);
    try testing.expectEqual(false, combo.mods.control);
    try testing.expectEqual(false, combo.mods.alt);
}

test "test_parse_modifier_combos" {
    const cf = KeyCombo.parse("<C-f>").?;
    try testing.expectEqual(KeyCode.character, cf.code);
    try testing.expectEqual(@as(?u8, 'f'), cf.char);
    try testing.expectEqual(true, cf.mods.control);
    try testing.expectEqual(false, cf.mods.alt);

    const mx = KeyCombo.parse("<M-x>").?;
    try testing.expectEqual(KeyCode.character, mx.code);
    try testing.expectEqual(@as(?u8, 'x'), mx.char);
    try testing.expectEqual(false, mx.mods.control);
    try testing.expectEqual(true, mx.mods.alt);

    const csa = KeyCombo.parse("<C-S-a>").?;
    try testing.expectEqual(true, csa.mods.control);
    try testing.expectEqual(true, csa.mods.shift);
    try testing.expectEqual(@as(?u8, 'a'), csa.char);
}

test "test_parse_special_keys" {
    const ret = KeyCombo.parse("<Return>").?;
    try testing.expectEqual(KeyCode.enter, ret.code);

    const bs = KeyCombo.parse("<Backspace>").?;
    try testing.expectEqual(KeyCode.backspace, bs.code);

    const left = KeyCombo.parse("<Left>").?;
    try testing.expectEqual(KeyCode.left, left.code);
}
