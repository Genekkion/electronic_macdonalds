const std = @import("std");
const Io = std.Io;
const c = @import("c.zig").c;
const result = @import("result.zig");

fn default_io() Io {
    return Io.Threaded.global_single_threaded.io();
}

pub fn lua_is_dir(L: ?*c.lua_State) callconv(.c) c_int {
    var len: usize = 0;
    const path_c = c.lua_tolstring(L, 1, &len);
    if (path_c == null or len == 0) {
        c.lua_pushboolean(L, 0);
        return 1;
    }

    const io = default_io();
    const st = Io.Dir.cwd().statFile(io, path_c[0..len], .{}) catch {
        c.lua_pushboolean(L, 0);
        return 1;
    };

    c.lua_pushboolean(L, if (st.kind == .directory) 1 else 0);
    return 1;
}

pub fn lua_read_dir(L: ?*c.lua_State) callconv(.c) c_int {
    var len: usize = 0;
    const path_c = c.lua_tolstring(L, 1, &len);
    if (path_c == null or len == 0) {
        c.lua_newtable(L);
        return 1;
    }

    const io = default_io();
    var dir = Io.Dir.cwd().openDir(io, path_c[0..len], .{ .iterate = true }) catch {
        c.lua_newtable(L);
        return 1;
    };
    defer dir.close(io);

    c.lua_newtable(L);
    var index: c_longlong = 1;

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        const is_dir = (entry.kind == .directory);

        c.lua_newtable(L);
        _ = c.lua_pushlstring(L, entry.name.ptr, entry.name.len);
        c.lua_setfield(L, -2, "name");
        c.lua_pushboolean(L, if (is_dir) 1 else 0);
        c.lua_setfield(L, -2, "is_dir");

        c.lua_rawseti(L, -2, index);
        index += 1;
    }

    return 1;
}

pub fn lua_fs_rename(L: ?*c.lua_State) callconv(.c) c_int {
    var old_len: usize = 0;
    const old_c = c.lua_tolstring(L, 1, &old_len);
    var new_len: usize = 0;
    const new_c = c.lua_tolstring(L, 2, &new_len);

    if (old_c == null or new_c == null or old_len == 0 or new_len == 0) {
        return result.push_error(L, "INVALID_ARGUMENT", "expected (old_path: string, new_path: string)");
    }

    const io = default_io();
    Io.Dir.rename(.cwd(), old_c[0..old_len], .cwd(), new_c[0..new_len], io) catch {
        return result.push_error(L, "RENAME_FAILED", "failed to rename file or directory");
    };

    return result.push_success_bool(L, true);
}

pub fn lua_fs_delete(L: ?*c.lua_State) callconv(.c) c_int {
    var len: usize = 0;
    const path_c = c.lua_tolstring(L, 1, &len);
    if (path_c == null or len == 0) {
        return result.push_error(L, "INVALID_ARGUMENT", "expected (path: string)");
    }

    const is_dir = if (c.lua_gettop(L) >= 2) (c.lua_toboolean(L, 2) != 0) else false;
    const path_slice = path_c[0..len];
    const io = default_io();
    const cwd = Io.Dir.cwd();

    if (is_dir) {
        cwd.deleteDir(io, path_slice) catch {
            cwd.deleteFile(io, path_slice) catch {
                return result.push_error(L, "DELETE_FAILED", "failed to delete file or directory");
            };
        };
    } else {
        cwd.deleteFile(io, path_slice) catch {
            cwd.deleteDir(io, path_slice) catch {
                return result.push_error(L, "DELETE_FAILED", "failed to delete file or directory");
            };
        };
    }

    return result.push_success_bool(L, true);
}

pub fn lua_fs_mkdir(L: ?*c.lua_State) callconv(.c) c_int {
    var len: usize = 0;
    const path_c = c.lua_tolstring(L, 1, &len);
    if (path_c == null or len == 0) {
        return result.push_error(L, "INVALID_ARGUMENT", "expected (path: string)");
    }

    const io = default_io();
    Io.Dir.cwd().createDir(io, path_c[0..len], .default_dir) catch {
        return result.push_error(L, "MKDIR_FAILED", "failed to create directory");
    };

    return result.push_success_bool(L, true);
}

pub fn lua_fs_touch(L: ?*c.lua_State) callconv(.c) c_int {
    var len: usize = 0;
    const path_c = c.lua_tolstring(L, 1, &len);
    if (path_c == null or len == 0) {
        return result.push_error(L, "INVALID_ARGUMENT", "expected (path: string)");
    }

    const path_slice = path_c[0..len];
    const io = default_io();
    const cwd = Io.Dir.cwd();

    if (cwd.statFile(io, path_slice, .{})) |_| {
        return result.push_success_bool(L, true);
    } else |_| {}

    var file = cwd.createFile(io, path_slice, .{}) catch {
        return result.push_error(L, "TOUCH_FAILED", "could not create file");
    };
    file.close(io);

    return result.push_success_bool(L, true);
}
