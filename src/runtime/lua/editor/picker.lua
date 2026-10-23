local M = {}
editor = editor or {}
editor.picker = M

Snacks = Snacks or {}
Snacks.picker = Snacks.picker or {}

local DEFAULT_MAX_ROWS = 23
local DEFAULT_SCROLLOFF = 4

local DEFAULT_SCORE = 1000
local INVERSE_SCORE = 1000

local SCORE_MATCH = 16
local SCORE_GAP_START = -3
local SCORE_GAP_EXTENSION = -1
local BONUS_BOUNDARY = SCORE_MATCH / 2
local BONUS_NONWORD = SCORE_MATCH / 2
local BONUS_CAMEL_123 = BONUS_BOUNDARY - 1
local BONUS_CONSECUTIVE = -(SCORE_GAP_START + SCORE_GAP_EXTENSION)
local BONUS_FIRST_CHAR_MULTIPLIER = 2
local BONUS_NO_PATH_SEP = BONUS_BOUNDARY - 2
local BONUS_BOUNDARY_WHITE = BONUS_BOUNDARY + 2
local BONUS_BOUNDARY_DELIMITER = BONUS_BOUNDARY + 1

local CHAR_WHITE = 0
local CHAR_NONWORD = 1
local CHAR_DELIMITER = 2
local CHAR_LOWER = 3
local CHAR_UPPER = 4
local CHAR_LETTER = 5
local CHAR_NUMBER = 6

local CHAR_CLASS = {}
for b = 0, 255 do
    local c = CHAR_NONWORD
    local ch = string.char(b)
    if ch:match("%s") then
        c = CHAR_WHITE
    elseif ch:match("[/\\,:;|]") then
        c = CHAR_DELIMITER
    elseif b >= 48 and b <= 57 then
        c = CHAR_NUMBER
    elseif b >= 65 and b <= 90 then
        c = CHAR_UPPER
    elseif b >= 97 and b <= 122 then
        c = CHAR_LOWER
    end
    CHAR_CLASS[b] = c
end

local function _compute_bonus(prev, curr)
    if curr > CHAR_NONWORD then
        if prev == CHAR_WHITE then
            return BONUS_BOUNDARY_WHITE
        elseif prev == CHAR_DELIMITER then
            return BONUS_BOUNDARY_DELIMITER
        elseif prev == CHAR_NONWORD then
            return BONUS_BOUNDARY
        end
    end
    if (prev == CHAR_LOWER and curr == CHAR_UPPER) or (prev ~= CHAR_NUMBER and curr == CHAR_NUMBER) then
        return BONUS_CAMEL_123
    end
    if curr == CHAR_NONWORD or curr == CHAR_DELIMITER then
        return BONUS_NONWORD
    elseif curr == CHAR_WHITE then
        return BONUS_BOUNDARY_WHITE
    end
    return 0
end

local BONUS_MATRIX = {}
for prev = 0, 6 do
    BONUS_MATRIX[prev] = {}
    for curr = 0, 6 do
        BONUS_MATRIX[prev][curr] = _compute_bonus(prev, curr)
    end
end

local _scorer = {
    score = 0,
    consecutive = 0,
    prev = nil,
    prev_class = CHAR_WHITE,
    is_file = true,
    first_bonus = 0,
    str = "",
}

local function _score_is_left_boundary(str, pos)
    return pos == 1 or (CHAR_CLASS[str:byte(pos - 1)] or CHAR_NONWORD) < CHAR_LOWER
end

local function _score_is_right_boundary(str, pos)
    return pos == #str or (CHAR_CLASS[str:byte(pos + 1)] or CHAR_NONWORD) < CHAR_LOWER
end

local function _score_update(pos)
    local b = _scorer.str:byte(pos)
    local class = CHAR_CLASS[b] or CHAR_NONWORD
    local bonus = 0
    local gap = _scorer.prev and (pos - _scorer.prev - 1) or 0

    if gap > 0 then
        _scorer.prev_class = CHAR_CLASS[_scorer.str:byte(pos - 1)] or CHAR_NONWORD
        bonus = BONUS_MATRIX[_scorer.prev_class][class] or 0
        _scorer.score = _scorer.score + SCORE_GAP_START + (gap - 1) * SCORE_GAP_EXTENSION
        _scorer.consecutive = 0
        _scorer.first_bonus = 0
    else
        bonus = BONUS_MATRIX[_scorer.prev_class][class] or 0
        if _scorer.consecutive == 0 then
            _scorer.first_bonus = bonus
        else
            if bonus >= BONUS_BOUNDARY and bonus > _scorer.first_bonus then
                _scorer.first_bonus = bonus
            end
            bonus = math.max(bonus, _scorer.first_bonus, BONUS_CONSECUTIVE)
        end
        _scorer.consecutive = _scorer.consecutive + 1
    end

    if not _scorer.prev then
        bonus = bonus * BONUS_FIRST_CHAR_MULTIPLIER
    end

    _scorer.score = _scorer.score + SCORE_MATCH + bonus
    _scorer.prev_class = class
    _scorer.prev = pos
end

local function _score_init(str, first, is_file)
    _scorer.str = str
    _scorer.score = 0
    _scorer.consecutive = 0
    _scorer.prev_class = CHAR_WHITE
    _scorer.prev = nil
    _scorer.first_bonus = 0
    _scorer.is_file = is_file
    if first > 1 then
        _scorer.prev_class = CHAR_CLASS[str:byte(first - 1)] or CHAR_NONWORD
    end
    if is_file and not str:find("/", first + 1, true) then
        _scorer.score = _scorer.score + BONUS_NO_PATH_SEP
    end
    _score_update(first)
end

local function _score_get(str, from, to, is_file)
    _score_init(str, from, is_file)
    for i = from + 1, to do
        _score_update(i)
    end
    return _scorer.score
end

local function _prepare_mod(pattern)
    local mods = {
        pattern = pattern,
        entropy = 0,
        chars = {},
        ignorecase = true,
        fuzzy = true,
    }

    local field, p = pattern:match("^([%w_][%w_]+):(.*)$")
    if field then
        mods.field = field
        mods.pattern = p
    end

    local is_lower = (mods.pattern:lower() == mods.pattern)
    mods.ignorecase = is_lower

    if mods.pattern:sub(1, 1) == "!" then
        mods.fuzzy = false
        mods.inverse = true
        mods.pattern = mods.pattern:sub(2)
        mods.entropy = mods.entropy - 1
    end

    if mods.pattern:sub(1, 1) == "'" then
        mods.fuzzy = false
        mods.pattern = mods.pattern:sub(2)
        mods.entropy = mods.entropy + 10
        if mods.pattern:sub(-1, -1) == "'" then
            mods.word = true
            mods.pattern = mods.pattern:sub(1, -2)
            mods.entropy = mods.entropy + 10
        end
    elseif mods.pattern:sub(1, 1) == "^" then
        mods.fuzzy = false
        mods.exact_prefix = true
        mods.pattern = mods.pattern:sub(2)
        mods.entropy = mods.entropy + 20
    end

    if mods.pattern:sub(-1, -1) == "$" then
        mods.fuzzy = false
        mods.exact_suffix = true
        mods.pattern = mods.pattern:sub(1, -2)
        mods.entropy = mods.entropy + 20
    end

    local rare_chars = #mods.pattern:gsub("[%w%s]", "")
    mods.entropy = mods.entropy + math.min(#mods.pattern, 20) + rare_chars * 2
    if not mods.ignorecase and not is_lower then
        mods.entropy = mods.entropy * 2
    end
    if mods.ignorecase then
        mods.pattern = mods.pattern:lower()
    end

    for c = 1, #mods.pattern do
        mods.chars[c] = mods.pattern:sub(c, c)
    end
    return mods
end

local function _parse_query_mods(query)
    local trimmed = (query or ""):match("^%s*(.-)%s*$")
    if trimmed == "" then
        return {}
    end
    local mod_groups = {}
    local is_or = false
    for token in trimmed:gmatch("%S+") do
        if token == "|" then
            is_or = true
        else
            local mods = _prepare_mod(token)
            if mods.pattern ~= "" then
                if is_or and #mod_groups > 0 then
                    table.insert(mod_groups[#mod_groups], mods)
                else
                    table.insert(mod_groups, { mods })
                end
            end
            is_or = false
        end
    end
    for _, ors in ipairs(mod_groups) do
        table.sort(ors, function(a, b)
            return a.entropy < b.entropy
        end)
    end
    table.sort(mod_groups, function(a, b)
        return a[1].entropy > b[1].entropy
    end)
    return mod_groups
end

local function _fuzzy_find(str, str_orig, pattern, init, is_file)
    local from = string.find(str, pattern[1], init or 1, true)
    if not from then
        return nil, nil
    end
    _score_init(str_orig, from, is_file)
    local last = from
    local n = #pattern
    for i = 2, n do
        last = string.find(str, pattern[i], last + 1, true)
        if last then
            _score_update(last)
        else
            return nil, nil
        end
    end
    return from, last
end

local function _fuzzy_match(str, str_orig, pattern, is_file)
    local from, to = _fuzzy_find(str, str_orig, pattern, 1, is_file)
    if not from then
        return nil, nil, nil, nil
    end
    local best_from, best_to, best_score = from, to, _scorer.score
    while from do
        if _scorer.score > best_score then
            best_from, best_to, best_score = from, to, _scorer.score
        end
        from, to = _fuzzy_find(str, str_orig, pattern, from + 1, is_file)
    end
    return best_score, best_from, best_to, str
end

local function _fuzzy_positions(str, pattern, from)
    local ret = { from }
    for i = 2, #pattern do
        local nxt = string.find(str, pattern[i], ret[#ret] + 1, true)
        if nxt then
            ret[#ret + 1] = nxt
        end
    end
    return ret
end

local function _match_single_mod(item, mods)
    local is_file = (item.file ~= nil or item.path ~= nil)
    local str = item.text or item.path or tostring(item)
    if mods.field then
        if item[mods.field] == nil then
            if mods.inverse then
                return INVERSE_SCORE, nil, nil, nil
            end
            return nil, nil, nil, nil
        end
        str = tostring(item[mods.field])
    end

    local str_orig = str
    str = mods.ignorecase and str:lower() or str
    if mods.fuzzy then
        return _fuzzy_match(str, str_orig, mods.chars, is_file)
    end

    local from, to = nil, nil
    if mods.exact_prefix then
        if str:sub(1, #mods.pattern) == mods.pattern then
            from, to = 1, #mods.pattern
        end
    elseif mods.exact_suffix then
        if str:sub(-#mods.pattern) == mods.pattern then
            from, to = #str - #mods.pattern + 1, #str
        end
    else
        from, to = str:find(mods.pattern, 1, true)
        while mods.word and from and to do
            if _score_is_left_boundary(str, from) and _score_is_right_boundary(str, to) then
                break
            end
            from, to = str:find(mods.pattern, to + 1, true)
        end
    end

    if mods.inverse then
        if not from then
            return INVERSE_SCORE, nil, nil, nil
        end
        return nil, nil, nil, nil
    end
    if from and to then
        return _score_get(str_orig, from, to, is_file), from, to, str
    end
    return nil, nil, nil, nil
end

local function _match_item(item, mod_groups)
    if #mod_groups == 0 then
        return DEFAULT_SCORE
    end
    local total_score = 0
    for _, any in ipairs(mod_groups) do
        local s = nil
        for _, mods in ipairs(any) do
            s = _match_single_mod(item, mods)
            if s then
                break
            end
        end
        if not s then
            return 0
        end
        total_score = total_score + s
    end
    return total_score
end

local function _compute_item_highlights(item, mod_groups)
    local cols = {}
    local seen = {}
    if item.left_hl_col and item.left_hl_len and item.left_hl_len > 0 then
        for c = item.left_hl_col, item.left_hl_col + item.left_hl_len - 1 do
            if not seen[c] then
                seen[c] = true
                cols[#cols + 1] = c
            end
        end
        return cols
    end
    for _, any in ipairs(mod_groups) do
        for _, mods in ipairs(any) do
            if not mods.field and not mods.inverse then
                local _, from, to, str = _match_single_mod(item, mods)
                if from and to and str then
                    if mods.fuzzy then
                        local fpos = _fuzzy_positions(str, mods.chars, from)
                        for _, p in ipairs(fpos) do
                            local col0 = p - 1
                            if not seen[col0] then
                                seen[col0] = true
                                cols[#cols + 1] = col0
                            end
                        end
                    else
                        for c = from, to do
                            local col0 = c - 1
                            if not seen[col0] then
                                seen[col0] = true
                                cols[#cols + 1] = col0
                            end
                        end
                    end
                end
            end
        end
    end
    table.sort(cols)
    return cols
end

local _state = nil

local function _join_path(cwd, rel_path)
    if not cwd or cwd == "" or cwd == "." then
        return rel_path
    end
    if cwd:sub(-1) == "/" then
        return cwd .. rel_path
    end
    return cwd .. "/" .. rel_path
end

local function _build_default_preview(item, max_rows)
    if not item then
        return {}
    end
    if item.preview_lines then
        return item.preview_lines
    end
    local target_path = item.full_path or item.path
    if not target_path or target_path == "" then
        if item.text then
            return { item.text }
        end
        return {}
    end

    local f = io.open(target_path, "r")
    if not f then
        return { item.text or target_path }
    end

    local limit = max_rows or DEFAULT_MAX_ROWS
    local lines = {}
    local highlight = nil
    local center_line = item.line or 1
    local start_line = math.max(1, center_line - math.floor(limit / 3))
    local end_line = start_line + limit - 1
    local idx = 1

    for line in f:lines() do
        if idx >= start_line and idx <= end_line then
            local marker = (idx == center_line and item.line ~= nil) and ">> " or "   "
            local prefix = string.format("%s%4d | ", marker, idx)
            table.insert(lines, prefix .. line)
            if idx == center_line and item.line ~= nil and item.col ~= nil then
                local m_len = item.match_len or (_state and _state.query and #_state.query or 0)
                if m_len > 0 then
                    highlight = {
                        line = #lines - 1,
                        col = #prefix + (item.col - 1),
                        len = m_len,
                    }
                end
            end
        elseif idx > end_line then
            break
        end
        idx = idx + 1
    end
    f:close()
    return lines, highlight
end

local function _basename_len(str)
    local last_slash = str:match("^.*()/")
    if last_slash then
        return #str - last_slash
    end
    return #str
end

local function _refresh_candidates()
    if not _state then
        return
    end

    local query = _state.query or ""
    local mod_groups = _parse_query_mods(query)
    _state.mod_groups = mod_groups

    if _state.finder then
        local results = _state.finder(query) or {}
        _state.filtered = results
    else
        if #mod_groups == 0 then
            local all = {}
            for i, item in ipairs(_state.items) do
                item._idx = i
                item._score = DEFAULT_SCORE
                all[#all + 1] = item
            end
            _state.filtered = all
        else
            local matched = {}
            for i, item in ipairs(_state.items) do
                item._idx = i
                local sc = _match_item(item, mod_groups)
                if sc > 0 then
                    item._score = sc
                    matched[#matched + 1] = item
                end
            end
            table.sort(matched, function(a, b)
                if a._score ~= b._score then
                    return a._score > b._score
                end
                local at = a.text or a.path or ""
                local bt = b.text or b.path or ""
                if (a.file or a.path) and (b.file or b.path) then
                    local ab = _basename_len(at)
                    local bb = _basename_len(bt)
                    if ab ~= bb then
                        return ab < bb
                    end
                end
                if #at ~= #bt then
                    return #at < #bt
                end
                return (a._idx or 0) < (b._idx or 0)
            end)
            _state.filtered = matched
        end
    end

    if #_state.filtered == 0 then
        _state.selected = 0
        _state.scroll_top = 1
    elseif _state.selected < 1 or _state.selected > #_state.filtered then
        _state.selected = 1
        _state.scroll_top = 1
    end
end

local function _update_scroll_with_padding(visible_rows)
    if not _state then
        return
    end
    local total = #_state.filtered
    if visible_rows <= 0 or total == 0 then
        _state.scroll_top = 1
        return
    end

    local scrolloff = DEFAULT_SCROLLOFF
    local eff_scrolloff = 0
    if visible_rows > 1 then
        eff_scrolloff = math.min(scrolloff, math.floor((visible_rows - 1) / 2))
    end

    local sel = _state.selected
    local scroll_top = _state.scroll_top or 1

    if sel < scroll_top + eff_scrolloff then
        scroll_top = math.max(1, sel - eff_scrolloff)
    end

    if visible_rows > eff_scrolloff then
        local bottom_bound = scroll_top + visible_rows - 1 - eff_scrolloff
        if sel > bottom_bound then
            scroll_top = math.max(1, sel - visible_rows + 1 + eff_scrolloff)
        end
    end

    local max_scroll = math.max(1, total - visible_rows + 1)
    if scroll_top > max_scroll then
        scroll_top = max_scroll
    end

    _state.scroll_top = scroll_top
end

function M.open(opts)
    opts = opts or {}
    _state = {
        title = opts.title or "Picker",
        prompt = opts.prompt or "> ",
        query = opts.query or "",
        items = opts.items or {},
        finder = opts.finder,
        on_select = opts.on_select,
        on_cancel = opts.on_cancel,
        preview = opts.preview or _build_default_preview,
        filtered = {},
        selected = 1,
        scroll_top = 1,
    }
    _refresh_candidates()
    editor.set_status(string.format("[%s] %s%s (%d items)", _state.title, _state.prompt, _state.query, #_state.filtered))
    return true
end

function M.close()
    _state = nil
end

function M.is_open()
    return _state ~= nil
end

function M.get_state()
    return _state
end

function M.set_query(query)
    if not _state then
        return
    end
    _state.query = query or ""
    _state.selected = 1
    _state.scroll_top = 1
    _refresh_candidates()
    editor.set_status(string.format("[%s] %s%s (%d items)", _state.title, _state.prompt, _state.query, #_state.filtered))
end

function M.append_char(ch)
    if not _state or not ch or ch == "" then
        return
    end
    M.set_query(_state.query .. ch)
end

function M.backspace()
    if not _state then
        return
    end
    local q = _state.query
    if #q > 0 then
        M.set_query(q:sub(1, #q - 1))
    end
end

function M.move_selection(delta)
    if not _state then
        return
    end
    local count = #_state.filtered
    if count == 0 then
        _state.selected = 0
        return
    end
    local next_idx = _state.selected + (delta or 0)
    if next_idx < 1 then
        next_idx = count
    elseif next_idx > count then
        next_idx = 1
    end
    _state.selected = next_idx
end

function M.confirm()
    if not _state then
        return false
    end
    local current = _state
    local chosen = nil
    if current.selected >= 1 and current.selected <= #current.filtered then
        chosen = current.filtered[current.selected]
    end
    _state = nil
    if chosen and current.on_select then
        current.on_select(chosen)
    end
    return true
end

function M.cancel()
    if not _state then
        return false
    end
    local current = _state
    _state = nil
    if current.on_cancel then
        current.on_cancel()
    end
    editor.set_status("")
    return true
end

function M.handle_key(key_name, char, mods)
    if not _state then
        return false
    end
    mods = mods or 0
    local is_ctrl = (math.floor(mods / 2) % 2) == 1

    if key_name == "escape" then
        return M.cancel()
    end
    if key_name == "enter" then
        return M.confirm()
    end
    if key_name == "backspace" then
        M.backspace()
        return true
    end
    if key_name == "down" or (is_ctrl and (char == "j" or char == "n" or char == "\n" or char == "\x0e")) then
        M.move_selection(1)
        return true
    end
    if key_name == "up" or (is_ctrl and (char == "k" or char == "p" or char == "\x0b" or char == "\x10")) then
        M.move_selection(-1)
        return true
    end
    if char and #char == 1 then
        local byte = string.byte(char, 1)
        if byte >= 32 and byte < 127 and not is_ctrl then
            M.append_char(char)
            return true
        end
    end
    return true
end

function M.get_ui_data(max_rows)
    if not _state then
        return nil
    end
    local row_limit = max_rows or DEFAULT_MAX_ROWS
    _update_scroll_with_padding(row_limit)

    local total = #_state.filtered
    local sel = _state.selected
    local start_idx = _state.scroll_top or 1
    local end_idx = math.min(total, start_idx + row_limit - 1)

    local visible_items = {}
    local item_highlights = {}
    local selected_visible_idx = 0
    local mod_groups = _state.mod_groups or {}
    for i = start_idx, end_idx do
        local item = _state.filtered[i]
        table.insert(visible_items, item.text or item.path or tostring(item))
        table.insert(item_highlights, _compute_item_highlights(item, mod_groups))
        if i == sel then
            selected_visible_idx = #visible_items
        end
    end

    local active_item = (sel >= 1 and sel <= total) and _state.filtered[sel] or nil
    local preview_lines, preview_highlight = nil, nil
    if _state.preview then
        preview_lines, preview_highlight = _state.preview(active_item, row_limit)
    end
    preview_lines = preview_lines or {}

    return {
        title = _state.title,
        prompt = _state.prompt .. _state.query,
        total = total,
        selected_index = selected_visible_idx,
        items = visible_items,
        item_highlights = item_highlights,
        preview = table.concat(preview_lines, "\n"),
        preview_highlight = preview_highlight,
    }
end

function Snacks.picker.files(opts)
    opts = opts or {}
    local cwd = opts.cwd or "."
    local hidden = true
    if opts.hidden ~= nil then
        hidden = opts.hidden
    end
    local ignored = false
    if opts.ignored ~= nil then
        ignored = opts.ignored
    end

    local raw_files = editor.find_files({
        cwd = cwd,
        hidden = hidden,
        ignored = ignored,
    })

    local items = {}
    for _, rel_path in ipairs(raw_files) do
        local full_path = _join_path(cwd, rel_path)
        table.insert(items, {
            text = rel_path,
            path = rel_path,
            file = rel_path,
            full_path = full_path,
        })
    end

    return M.open({
        title = "Find Files",
        prompt = "Files> ",
        items = items,
        on_select = function(item)
            if item and item.full_path then
                editor.dispatch_command(":e " .. item.full_path)
            end
        end,
    })
end

function Snacks.picker.grep(opts)
    opts = opts or {}
    local cwd = opts.cwd or "."
    local hidden = true
    if opts.hidden ~= nil then
        hidden = opts.hidden
    end
    local ignored = false
    if opts.ignored ~= nil then
        ignored = opts.ignored
    end

    return M.open({
        title = "Live Grep",
        prompt = "Grep> ",
        finder = function(query)
            if not query or query == "" then
                return {}
            end
            local matches = editor.live_grep({
                cwd = cwd,
                pattern = query,
                hidden = hidden,
                ignored = ignored,
            })
            local items = {}
            local is_lower = (query:lower() == query)
            local q_search = is_lower and query:lower() or query
            for _, m in ipairs(matches) do
                local full_path = _join_path(cwd, m.path)
                local prefix = string.format("%s:%d:%d: ", m.path, m.line, m.col)
                local haystack = is_lower and m.text:lower() or m.text
                local m_start = haystack:find(q_search, 1, true)
                local left_hl_col = m_start and (#prefix + m_start - 1) or nil
                table.insert(items, {
                    text = prefix .. m.text,
                    path = m.path,
                    full_path = full_path,
                    line = m.line,
                    col = m.col,
                    match_len = #query,
                    left_hl_col = left_hl_col,
                    left_hl_len = m_start and #query or nil,
                    line_text = m.text,
                })
            end
            return items
        end,
        on_select = function(item)
            if item and item.full_path then
                editor.dispatch_command(":e " .. item.full_path)
                local target_line = math.max(0, (item.line or 1) - 1)
                local target_col = math.max(0, (item.col or 1) - 1)
                editor.set_cursor(target_line, target_col)
            end
        end,
    })
end

function Snacks.picker.lines(opts)
    opts = opts or {}
    local cur_buf = editor.get_current_buffer()
    local items = {}

    if cur_buf then
        local total = cur_buf:line_count()
        for i = 0, total - 1 do
            local line_text = cur_buf:get_line(i) or ""
            table.insert(items, {
                text = string.format("%4d: %s", i + 1, line_text),
                line = i + 1,
                preview_lines = { line_text },
            })
        end
    end

    return M.open({
        title = "Buffer Lines",
        prompt = "Lines> ",
        items = items,
        on_select = function(item)
            if item and item.line then
                editor.set_cursor(math.max(0, item.line - 1), 0)
            end
        end,
    })
end

return M
