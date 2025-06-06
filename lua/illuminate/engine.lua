local hl = require('illuminate.highlight')
local ref = require('illuminate.reference')
local config = require('illuminate.config')
local util = require('illuminate.util')

local M = {}

local AUGROUP = 'vim_illuminate_v2_augroup'
local timers = {}
local paused_bufs = {}
local stopped_bufs = {}
local is_paused = false
local tick = {}
local error_timestamps = {}
local frozen_bufs = {}
local invisible_bufs = {}
local started = false

local function buf_should_illuminate(bufnr)
    if is_paused or paused_bufs[bufnr] or stopped_bufs[bufnr] then
        return false
    end

    return config.should_enable()(bufnr)
        and (config.max_file_lines() == nil or vim.fn.line('$') <= config.max_file_lines())
        and util.is_allowed(
            config.modes_allowlist(bufnr),
            config.modes_denylist(bufnr),
            vim.api.nvim_get_mode().mode
        ) and util.is_allowed(
            config.filetypes_allowlist(),
            config.filetypes_denylist(),
            vim.api.nvim_buf_get_option(bufnr, 'filetype')
        )
end

local function stop_timer(timer)
    if vim.loop.is_active(timer) then
        vim.loop.timer_stop(timer)
        vim.loop.close(timer)
    end
end

function M.start()
    started = true
    vim.api.nvim_create_augroup(AUGROUP, { clear = true })
    vim.api.nvim_create_autocmd({ 'VimEnter', 'CursorMoved', 'CursorMovedI', 'ModeChanged', 'TextChanged' }, {
        group = AUGROUP,
        callback = function()
            M.refresh_references()
        end,
    })

    -- Set up auto-attach/detach for the treesitter provider if we can use builtin methods instead of
    -- treesitter modules.
    if vim.fn.has('nvim-0.9') == 1 then
        vim.api.nvim_create_autocmd({ 'FileType' }, {
            callback = function(details)
                require('illuminate.providers.treesitter').detach(details.buf)

                if not package.loaded['nvim-treesitter'] then
                    return
                end

                local lang = vim.treesitter.language.get_lang(details.match)
                local ok, query = pcall(require, 'nvim-treesitter.query')
                if not ok then
                    return
                end

                local parsers
                ok, parsers = pcall(require, 'nvim-treesitter.parsers')
                if not ok then
                    return
                end

                if not parsers.has_parser(lang) then
                    return false
                end

                if not lang or not query.has_locals(lang) then
                    return
                end

                require('illuminate.providers.treesitter').attach(details.buf)
            end,
        })
        vim.api.nvim_create_autocmd({ 'BufUnload' }, {
            callback = function(details)
                require('illuminate.providers.treesitter').detach(details.buf)
            end,
        })
    end

    vim.api.nvim_create_autocmd({ 'VimLeave' }, {
        group = AUGROUP,
        callback = function()
            for _, timer in pairs(timers) do
                stop_timer(timer)
            end
        end,
    })
end

function M.stop()
    started = false
    vim.api.nvim_create_augroup(AUGROUP, { clear = true })
end

--- Get the highlighted references for the item under the cursor for
--- @bufnr and clears any old reference highlights
---
--- @bufnr (number)
function M.refresh_references(bufnr, winid)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    winid = winid or vim.api.nvim_get_current_win()

    if frozen_bufs[bufnr] then
        return
    end

    if not buf_should_illuminate(bufnr) then
        hl.buf_clear_references(bufnr)
        ref.buf_set_references(bufnr, {})
        return
    end

    local need_lsp_request = false
    local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
    local cword = util.get_cur_word(bufnr, util.get_cursor_pos(winid))

    if cword == [[\V\<\>]] or cword == [[\c\<\>]] then
        hl.buf_clear_references(bufnr)
        return
    end

    -- We might want to optimize here by returning early if cursor is in references.
    -- The downside is that LSP servers can sometimes return a different list of references
    -- as you move around an existing reference (like return statements).
    if tick[bufnr] ~= changedtick or not ref.buf_cursor_in_references(bufnr, util.get_cursor_pos(winid)) then
        hl.buf_clear_references(bufnr)
        ref.buf_set_references(bufnr, {})
        need_lsp_request = true
    elseif config.large_file_cutoff() ~= nil and vim.fn.line('$') > config.large_file_cutoff() then
        return
    end
    tick[bufnr] = changedtick

    if timers[bufnr] then
        stop_timer(timers[bufnr])
    end

    local provider = M.get_provider(bufnr)
    if not provider then return end
    if need_lsp_request then
        if provider.is_regex then
            local id = vim.w[winid].illuminated_match_id
            if id then
                vim.fn.matchdelete(id, winid)
            end
            vim.w[winid].illuminated_match_id = vim.fn.matchadd('IlluminatedWordText', cword, -1)
            return
        end

        pcall(provider['initiate_request'], bufnr, winid)
    else
        return
    end

    local timer = vim.loop.new_timer()
    timers[bufnr] = timer
    timer:start(config.delay(bufnr), 17, vim.schedule_wrap(function()
        local ok, err = pcall(function()
            if not bufnr or not vim.api.nvim_buf_is_loaded(bufnr) then
                stop_timer(timer)
                return
            end

            hl.buf_clear_references(bufnr)
            ref.buf_set_references(bufnr, {})

            if not buf_should_illuminate(bufnr) then
                stop_timer(timer)
                return
            end

            if vim.api.nvim_buf_get_changedtick(bufnr) ~= changedtick
                or vim.api.nvim_get_current_win() ~= winid
                or bufnr ~= vim.api.nvim_win_get_buf(0) then
                stop_timer(timer)
                return
            end

            provider = M.get_provider(bufnr)
            if not provider then
                stop_timer(timer)
                return
            end

            local references = provider.get_references(bufnr, util.get_cursor_pos(winid))
            if references ~= nil then
                ref.buf_set_references(bufnr, references)
                if ref.buf_cursor_in_references(bufnr, util.get_cursor_pos(winid)) then
                    if not invisible_bufs[bufnr] == true then
                        hl.buf_highlight_references(bufnr, ref.buf_get_references(bufnr))
                    end
                else
                    ref.buf_set_references(bufnr, {})
                end
                stop_timer(timer)
            end
        end)

        if not ok then
            local time = vim.loop.hrtime()
            if #error_timestamps == 5 then
                vim.notify(
                    'vim-illuminate: An internal error has occured: ' .. vim.inspect(ok) .. vim.inspect(err),
                    vim.log.levels.ERROR,
                    {}
                )
                M.stop()
                stop_timer(timer)
            elseif #error_timestamps == 0 or time - error_timestamps[#error_timestamps] < 500000000 then
                table.insert(error_timestamps, time)
            else
                error_timestamps = { time }
            end
        end
    end))
end

function M.get_provider(bufnr)
    for _, provider in ipairs(config.providers(bufnr) or {}) do
        local ok, providerModule = pcall(require, string.format('illuminate.providers.%s', provider))
        if ok and providerModule.is_ready(bufnr) then
            return providerModule, provider
        end
    end
    return nil
end

function M.pause()
    is_paused = true
    M.refresh_references()
end

function M.resume()
    is_paused = false
    M.refresh_references()
end

function M.toggle()
    is_paused = not is_paused
    M.refresh_references()
end

function M.toggle_buf(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if paused_bufs[bufnr] then
        paused_bufs[bufnr] = nil
    else
        paused_bufs[bufnr] = true
    end
    M.refresh_references()
end

function M.pause_buf(bufnr)
    paused_bufs[bufnr or vim.api.nvim_get_current_buf()] = true
    M.refresh_references()
end

function M.resume_buf(bufnr)
    paused_bufs[bufnr or vim.api.nvim_get_current_buf()] = nil
    M.refresh_references()
end

function M.stop_buf(bufnr)
    stopped_bufs[bufnr or vim.api.nvim_get_current_buf()] = true
    M.refresh_references()
end

function M.freeze_buf(bufnr)
    frozen_bufs[bufnr or vim.api.nvim_get_current_buf()] = true
end

function M.unfreeze_buf(bufnr)
    frozen_bufs[bufnr or vim.api.nvim_get_current_buf()] = nil
end

function M.toggle_freeze_buf(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    frozen_bufs[bufnr] = not frozen_bufs[bufnr]
end

function M.invisible_buf(bufnr)
    invisible_bufs[bufnr or vim.api.nvim_get_current_buf()] = true
    M.refresh_references()
end

function M.visible_buf(bufnr)
    invisible_bufs[bufnr or vim.api.nvim_get_current_buf()] = nil
    M.refresh_references()
end

function M.toggle_visibility_buf(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    invisible_bufs[bufnr] = not invisible_bufs[bufnr]
    M.refresh_references()
end

function M.debug()
    local bufnr = vim.api.nvim_get_current_buf()
    print('buf_should_illuminate', bufnr, buf_should_illuminate(bufnr))
    print('config', vim.inspect(config.get_raw()))
    print('started', started)
    print('provider', M.get_provider(bufnr))
    print('`termguicolors`', vim.opt.termguicolors:get())
end

function M.is_paused()
    return is_paused
end

return M
