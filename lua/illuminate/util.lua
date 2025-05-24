local config = require('illuminate.config')

local M = {}

function M.get_cursor_pos(winid)
    winid = winid or vim.api.nvim_get_current_win()
    local cursor = vim.api.nvim_win_get_cursor(winid)
    cursor[1] = cursor[1] - 1 -- we always want line to be 0-indexed
    return cursor
end

function M.list_to_set(list)
    if list == nil then
        return nil
    end

    local set = {}
    for _, v in pairs(list) do
        set[v] = true
    end
    return set
end

local START_WORD_REGEX = vim.regex([[^\k*]])
local END_WORD_REGEX = vim.regex([[\k*$]])

-- foo
-- foo
-- Foo
-- fOo
function M.get_cur_word(bufnr, cursor)
    local line = vim.api.nvim_buf_get_lines(bufnr, cursor[1], cursor[1] + 1, false)[1]
    local left_part = string.sub(line, 0, cursor[2] + 1)
    local right_part = string.sub(line, cursor[2] + 1)
    local start_idx, _ = END_WORD_REGEX:match_str(left_part)
    local _, end_idx = START_WORD_REGEX:match_str(right_part)
    local word = string.format('%s%s', string.sub(left_part, start_idx + 1), string.sub(right_part, 2, end_idx))
    local modifiers = [[\V]]
    if config.case_insensitive_regex() then
        modifiers = modifiers .. [[\c]]
    else
        modifiers = modifiers .. [[\C]]
    end
    local ok, escaped = pcall(vim.fn.escape, word, [[/\]])
    if ok then
        return modifiers .. [[\<]] .. escaped .. [[\>]]
    end
end

function M.is_allowed(allow_list, deny_list, thing)
    if #allow_list == 0 and #deny_list == 0 then
        return true
    end

    if #deny_list > 0 then
        return not vim.tbl_contains(deny_list, thing)
    end

    return vim.tbl_contains(allow_list, thing)
end

function M.tbl_get(tbl, expected_type, ...)
    local cur = tbl
    for _, key in ipairs({ ... }) do
        if type(cur) ~= 'table' or cur[key] == nil then
            return nil
        end

        cur = cur[key]
    end

    return type(cur) == expected_type and cur or nil
end

function M.has_keymap(mode, lhs)
    return vim.fn.mapcheck(lhs, mode) ~= ''
end

return M
