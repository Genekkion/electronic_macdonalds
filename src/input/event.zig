pub const Modifiers = packed struct {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    command: bool = false,
};

pub const KeyCode = enum {
    character,
    backspace,
    enter,
    tab,
    escape,
    left,
    right,
    up,
    down,
    delete,
    home,
    end,
    page_up,
    page_down,
};

pub const KeyEvent = struct {
    code: KeyCode,
    mods: Modifiers = .{},
    char: ?u8 = null,
};
