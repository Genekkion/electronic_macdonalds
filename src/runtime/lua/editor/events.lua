-- runtime/lua/editor/events.lua
-- Event / Autocommand Engine for Electronic Macdonalds

editor = editor or {}

local listeners = {}

--- Register a general event callback
-- @param event string Event name (e.g. "BufWritePre", "ModeChanged")
-- @param fn function Callback function receiving event data
function editor.on(event, fn)
    assert(type(event) == "string", "event name must be a string")
    assert(type(fn) == "function", "callback must be a function")
    if not listeners[event] then
        listeners[event] = {}
    end
    table.insert(listeners[event], { callback = fn })
end

--- Register a pattern-filtered autocommand
-- @param event string Event name
-- @param opts table Table containing callback and optional pattern
function editor.autocmd(event, opts)
    assert(type(event) == "string", "event name must be a string")
    assert(type(opts) == "table" and type(opts.callback) == "function", "opts.callback must be a function")
    if not listeners[event] then
        listeners[event] = {}
    end
    table.insert(listeners[event], {
        pattern = opts.pattern,
        callback = opts.callback,
    })
end

--- Dispatch an event to all registered listeners
-- @param event string Event name
-- @param data table Event payload (e.g. buf_id, buf_path, from, to)
function editor.emit(event, data)
    local list = listeners[event]
    if not list then return end
    data = data or {}
    for _, item in ipairs(list) do
        local matches = true
        if item.pattern and data.buf_path then
            local pat = item.pattern
            local lua_pat = pat:gsub("%.", "%%."):gsub("%*", ".*") .. "$"
            matches = (data.buf_path:match(lua_pat) ~= nil)
        end
        if matches then
            local ok, err = pcall(item.callback, data)
            if not ok then
                editor.set_error("Autocmd error (" .. event .. "): " .. tostring(err))
            end
        end
    end
end

return {
    on = editor.on,
    autocmd = editor.autocmd,
    emit = editor.emit,
}
