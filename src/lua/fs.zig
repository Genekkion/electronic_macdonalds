const std = @import("std");
const c = @import("c.zig").c;
const result = @import("result.zig");

const posix_c = @cImport({
    @cInclude("dirent.h");
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
});

pub fn lua_is_dir(L: ?*c.lua_State) callconv(.c) c_int {
    var len: usize = 0;
    const path_c = c.lua_tolstring(L, 1, &len);
    if (path_c == null) {
        c.lua_pushboolean(L, 0);
        return 1;
    }

    var buf: [1024]u8 = undefined;
    if (len >= buf.len) {
        c.lua_pushboolean(L, 0);
        return 1;
    }
    @memcpy(buf[0..len], path_c[0..len]);
    buf[len] = 0;

    var st: posix_c.struct_stat = undefined;
    if (posix_c.stat(&buf, &st) != 0) {
        c.lua_pushboolean(L, 0);
        return 1;
    }

    const is_dir = ((st.st_mode & posix_c.S_IFMT) == posix_c.S_IFDIR);
    c.lua_pushboolean(L, if (is_dir) 1 else 0);
    return 1;
}

pub fn lua_read_dir(L: ?*c.lua_State) callconv(.c) c_int {
    var len: usize = 0;
    const path_c = c.lua_tolstring(L, 1, &len);
    if (path_c == null) {
        c.lua_newtable(L);
        return 1;
    }

    var buf: [1024]u8 = undefined;
    if (len >= buf.len) {
        c.lua_newtable(L);
        return 1;
    }
    @memcpy(buf[0..len], path_c[0..len]);
    buf[len] = 0;

    const dir = posix_c.opendir(&buf);
    if (dir == null) {
        c.lua_newtable(L);
        return 1;
    }
    defer _ = posix_c.closedir(dir);

    c.lua_newtable(L);
    var index: c_longlong = 1;

    while (posix_c.readdir(dir)) |entry| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
            continue;
        }

        var is_dir = (entry.*.d_type == posix_c.DT_DIR);
        if (entry.*.d_type == posix_c.DT_UNKNOWN) {
            var full_path: [2048]u8 = undefined;
            const full_len = std.fmt.bufPrint(&full_path, "{s}/{s}", .{ buf[0..len], name }) catch null;
            if (full_len) |fl| {
                full_path[fl.len] = 0;
                var st: posix_c.struct_stat = undefined;
                if (posix_c.stat(&full_path, &st) == 0) {
                    is_dir = ((st.st_mode & posix_c.S_IFMT) == posix_c.S_IFDIR);
                }
            }
        }

        c.lua_newtable(L);
        _ = c.lua_pushlstring(L, name.ptr, name.len);
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

    if (old_c == null or new_c == null) {
        return result.push_error(L, "INVALID_ARGUMENT", "expected (old_path: string, new_path: string)");
    }

    var old_buf: [1024]u8 = undefined;
    var new_buf: [1024]u8 = undefined;
    if (old_len >= old_buf.len or new_len >= new_buf.len) {
        return result.push_error(L, "PATH_TOO_LONG", "path exceeds maximum length");
    }

    @memcpy(old_buf[0..old_len], old_c[0..old_len]);
    old_buf[old_len] = 0;
    @memcpy(new_buf[0..new_len], new_c[0..new_len]);
    new_buf[new_len] = 0;

    if (posix_c.rename(&old_buf, &new_buf) != 0) {
        return result.push_error(L, "RENAME_FAILED", "failed to rename file or directory");
    }

    return result.push_success_bool(L, true);
}

pub fn lua_fs_delete(L: ?*c.lua_State) callconv(.c) c_int {
    var len: usize = 0;
    const path_c = c.lua_tolstring(L, 1, &len);
    if (path_c == null) {
        return result.push_error(L, "INVALID_ARGUMENT", "expected (path: string)");
    }

    const is_dir = if (c.lua_gettop(L) >= 2) (c.lua_toboolean(L, 2) != 0) else false;

    var buf: [1024]u8 = undefined;
    if (len >= buf.len) {
        return result.push_error(L, "PATH_TOO_LONG", "path exceeds maximum length");
    }
    @memcpy(buf[0..len], path_c[0..len]);
    buf[len] = 0;

    const res = if (is_dir) posix_c.rmdir(&buf) else posix_c.unlink(&buf);
    if (res != 0) {
        // Fallback: try unlink if rmdir failed or vice versa
        const alt_res = if (is_dir) posix_c.unlink(&buf) else posix_c.rmdir(&buf);
        if (alt_res != 0) {
            return result.push_error(L, "DELETE_FAILED", "failed to delete file or directory");
        }
    }

    return result.push_success_bool(L, true);
}

pub fn lua_fs_mkdir(L: ?*c.lua_State) callconv(.c) c_int {
    var len: usize = 0;
    const path_c = c.lua_tolstring(L, 1, &len);
    if (path_c == null) {
        return result.push_error(L, "INVALID_ARGUMENT", "expected (path: string)");
    }

    var buf: [1024]u8 = undefined;
    if (len >= buf.len) {
        return result.push_error(L, "PATH_TOO_LONG", "path exceeds maximum length");
    }
    @memcpy(buf[0..len], path_c[0..len]);
    buf[len] = 0;

    if (posix_c.mkdir(&buf, 0o755) != 0) {
        return result.push_error(L, "MKDIR_FAILED", "failed to create directory");
    }

    return result.push_success_bool(L, true);
}

pub fn lua_fs_touch(L: ?*c.lua_State) callconv(.c) c_int {
    var len: usize = 0;
    const path_c = c.lua_tolstring(L, 1, &len);
    if (path_c == null) {
        return result.push_error(L, "INVALID_ARGUMENT", "expected (path: string)");
    }

    var buf: [1024]u8 = undefined;
    if (len >= buf.len) {
        return result.push_error(L, "PATH_TOO_LONG", "path exceeds maximum length");
    }
    @memcpy(buf[0..len], path_c[0..len]);
    buf[len] = 0;

    // If file already exists, success
    const f_check = posix_c.fopen(&buf, "rb");
    if (f_check != null) {
        _ = posix_c.fclose(f_check);
        return result.push_success_bool(L, true);
    }

    const f = posix_c.fopen(&buf, "wb");
    if (f == null) {
        return result.push_error(L, "TOUCH_FAILED", "could not create file");
    }
    _ = posix_c.fclose(f);

    return result.push_success_bool(L, true);
}
