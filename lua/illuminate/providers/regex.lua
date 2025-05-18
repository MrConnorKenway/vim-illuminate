local config = require('illuminate.config')
local util = require('illuminate.util')

local M = {}

M.is_regex = true

function M.get_references()
end

function M.is_ready(bufnr)
    local name = vim.fn.synIDattr(
        vim.fn.synIDtrans(
            vim.fn.synID(vim.fn.line('.'), vim.fn.col('.'), 1)
        ),
        'name'
    )
    if util.is_allowed(
            config.provider_regex_syntax_allowlist(bufnr),
            config.provider_regex_syntax_denylist(bufnr),
            name
        ) then
        return true
    end
    return false
end

return M
