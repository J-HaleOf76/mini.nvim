-- NOTE: These are basic tests which cover basic functionliaty. A lot of
-- nuances are not tested to meet "complexity-necessity" trade-off.
local helpers = dofile('tests/helpers.lua')

local child = helpers.new_child_neovim()
local expect, eq = helpers.expect, helpers.expect.equality
local new_set = MiniTest.new_set

-- Helpers with child processes
--stylua: ignore start
local load_module = function(config) child.mini_load('completion', config) end
local unload_module = function() child.mini_unload('completion') end
local reload_module = function(config) unload_module(); load_module(config) end
local set_cursor = function(...) return child.set_cursor(...) end
local get_cursor = function(...) return child.get_cursor(...) end
local set_lines = function(...) return child.set_lines(...) end
local get_lines = function(...) return child.get_lines(...) end
local type_keys = function(...) return child.type_keys(...) end
local sleep = function(ms) helpers.sleep(ms, child, true) end
local mock_lsp = function() child.cmd('luafile tests/dir-completion/mock-months-lsp.lua') end
local new_buffer = function() child.api.nvim_set_current_buf(child.api.nvim_create_buf(true, false)) end
--stylua: ignore end

-- Tweak `expect_screenshot()` to test only on 0.9<=Neovim<=0.10 (as 0.8 does
-- not have titles and current Nightly 0.11 has different way of computing
-- attributes in popup-menu; see https://github.com/neovim/neovim/pull/29980)
-- TODO: Update to use Neovim>=0.11 when Neovim 0.11 is released
child.expect_screenshot_orig = child.expect_screenshot
child.expect_screenshot = function(opts)
  if not (child.fn.has('nvim-0.9') == 1 and child.fn.has('nvim-0.11') == 0) then return end
  child.expect_screenshot_orig(opts)
end

local mock_miniicons = function()
  child.lua([[
    require('mini.icons').setup()
    local _, hl_text = MiniIcons.get('lsp', 'Text')
    local _, hl_function = MiniIcons.get('lsp', 'Function')
    _G.ref_hlgroup = { text = hl_text, func = hl_function}
  ]])
end

local mock_completefunc_lsp_tracking = function()
  child.lua([[
    local completefunc_lsp_orig = MiniCompletion.completefunc_lsp
    MiniCompletion.completefunc_lsp = function(...)
      _G.n_completfunc_lsp = (_G.n_completfunc_lsp or 0) + 1
      return completefunc_lsp_orig(...)
    end
  ]])
end

-- NOTE: this can't show "what filtered text is actually shown in window".
-- Seems to be because information for `complete_info()`
--- is updated in the very last minute (probably, by UI). This means that the
--- idea of "Type <C-n> -> get selected item" loop doesn't work (because
--- "selected item" is not updated). Can't find a way to force its update.
---
--- Using screen tests to get information about actually shown filtered items.
---
--- More info: https://github.com/vim/vim/issues/10007
local get_completion = function(what)
  what = what or 'word'
  return vim.tbl_map(function(x) return x[what] end, child.fn.complete_info().items)
end

local get_floating_windows = function()
  return vim.tbl_filter(
    function(x) return child.api.nvim_win_get_config(x).relative ~= '' end,
    child.api.nvim_list_wins()
  )
end

local validate_single_floating_win = function(opts)
  opts = opts or {}
  local wins = get_floating_windows()
  eq(#wins, 1)

  local win_id = wins[1]
  if opts.lines ~= nil then
    local buf_id = child.api.nvim_win_get_buf(win_id)
    local lines = child.api.nvim_buf_get_lines(buf_id, 0, -1, true)
    eq(lines, opts.lines)
  end
  if opts.config ~= nil then
    local true_config = child.api.nvim_win_get_config(win_id)
    local compare_config = {}
    for key, _ in pairs(opts.config) do
      compare_config[key] = true_config[key]
    end
    eq(compare_config, opts.config)
  end
end

-- Time constants
local default_completion_delay, default_info_delay, default_signature_delay = 100, 100, 50
local small_time = helpers.get_time_const(10)

-- Output test set ============================================================
local T = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      load_module()
    end,
    post_once = child.stop,
  },
  n_retry = helpers.get_n_retry(2),
})

-- Unit tests =================================================================
T['setup()'] = new_set()

T['setup()']['creates side effects'] = function()
  -- Global variable
  eq(child.lua_get('type(_G.MiniCompletion)'), 'table')

  -- Autocommand group
  eq(child.fn.exists('#MiniCompletion'), 1)

  -- Highlight groups
  child.cmd('hi clear')
  load_module()
  expect.match(child.cmd_capture('hi MiniCompletionActiveParameter'), 'gui=underline')
end

T['setup()']['creates `config` field'] = function()
  eq(child.lua_get('type(_G.MiniCompletion.config)'), 'table')

  -- Check default values
  local expect_config = function(field, value) eq(child.lua_get('MiniCompletion.config.' .. field), value) end

  expect_config('delay.completion', 100)
  expect_config('delay.info', 100)
  expect_config('delay.signature', 50)
  expect_config('window.info.height', 25)
  expect_config('window.info.width', 80)
  expect_config('window.info.border', 'single')
  expect_config('window.signature.height', 25)
  expect_config('window.signature.width', 80)
  expect_config('window.signature.border', 'single')
  expect_config('lsp_completion.source_func', 'completefunc')
  expect_config('lsp_completion.auto_setup', true)
  eq(child.lua_get('type(_G.MiniCompletion.config.lsp_completion.process_items)'), 'function')
  eq(child.lua_get('type(_G.MiniCompletion.config.fallback_action)'), 'function')
  expect_config('mappings.force_twostep', '<C-Space>')
  expect_config('mappings.force_fallback', '<A-Space>')
  expect_config('mappings.scroll_down', '<C-f>')
  expect_config('mappings.scroll_up', '<C-b>')
  expect_config('set_vim_settings', true)
end

T['setup()']['respects `config` argument'] = function()
  -- Check setting `MiniCompletion.config` fields
  reload_module({ delay = { completion = 300 } })
  eq(child.lua_get('MiniCompletion.config.delay.completion'), 300)
end

T['setup()']['validates `config` argument'] = function()
  unload_module()

  local expect_config_error = function(config, name, target_type)
    expect.error(load_module, vim.pesc(name) .. '.*' .. vim.pesc(target_type), config)
  end

  expect_config_error('a', 'config', 'table')
  expect_config_error({ delay = 'a' }, 'delay', 'table')
  expect_config_error({ delay = { completion = 'a' } }, 'delay.completion', 'number')
  expect_config_error({ delay = { info = 'a' } }, 'delay.info', 'number')
  expect_config_error({ delay = { signature = 'a' } }, 'delay.signature', 'number')
  expect_config_error({ window = 'a' }, 'window', 'table')
  expect_config_error({ window = { info = 'a' } }, 'window.info', 'table')
  expect_config_error({ window = { info = { height = 'a' } } }, 'window.info.height', 'number')
  expect_config_error({ window = { info = { width = 'a' } } }, 'window.info.width', 'number')
  expect_config_error({ window = { info = { border = 1 } } }, 'window.info.border', 'string or array')
  expect_config_error({ window = { signature = 'a' } }, 'window.signature', 'table')
  expect_config_error({ window = { signature = { height = 'a' } } }, 'window.signature.height', 'number')
  expect_config_error({ window = { signature = { width = 'a' } } }, 'window.signature.width', 'number')
  expect_config_error({ window = { signature = { border = 1 } } }, 'window.signature.border', 'string or array')
  expect_config_error({ lsp_completion = 'a' }, 'lsp_completion', 'table')
  expect_config_error(
    { lsp_completion = { source_func = 'a' } },
    'lsp_completion.source_func',
    '"completefunc" or "omnifunc"'
  )
  expect_config_error({ lsp_completion = { auto_setup = 'a' } }, 'lsp_completion.auto_setup', 'boolean')
  expect_config_error({ lsp_completion = { process_items = 'a' } }, 'lsp_completion.process_items', 'function')
  expect_config_error({ fallback_action = 1 }, 'fallback_action', 'function or string')
  expect_config_error({ mappings = 'a' }, 'mappings', 'table')
  expect_config_error({ mappings = { force_twostep = 1 } }, 'mappings.force_twostep', 'string')
  expect_config_error({ mappings = { force_fallback = 1 } }, 'mappings.force_fallback', 'string')
  expect_config_error({ mappings = { scroll_down = 1 } }, 'mappings.scroll_down', 'string')
  expect_config_error({ mappings = { scroll_up = 1 } }, 'mappings.scroll_up', 'string')
  expect_config_error({ set_vim_settings = 1 }, 'set_vim_settings', 'boolean')
end

T['setup()']['ensures colors'] = function()
  child.cmd('colorscheme default')
  expect.match(child.cmd_capture('hi MiniCompletionActiveParameter'), 'gui=underline')
end

T['setup()']['properly handles `config.mappings`'] = function()
  local has_map = function(lhs, pattern) return child.cmd_capture('imap ' .. lhs):find(pattern) ~= nil end
  eq(has_map('<C-Space>', 'Complete'), true)

  unload_module()
  child.api.nvim_del_keymap('i', '<C-Space>')

  -- Supplying empty string should mean "don't create keymap"
  load_module({ mappings = { force_twostep = '' } })
  eq(has_map('<C-Space>', 'Complete'), false)
end

T['setup()']['uses `config.lsp_completion`'] = function()
  local validate = function(auto_setup, source_func)
    reload_module({ lsp_completion = { auto_setup = auto_setup, source_func = source_func } })
    local buf_id = child.api.nvim_create_buf(true, false)
    child.api.nvim_set_current_buf(buf_id)

    local omnifunc, completefunc
    if auto_setup == false then
      omnifunc, completefunc = '', ''
    else
      local val = 'v:lua.MiniCompletion.completefunc_lsp'
      omnifunc = source_func == 'omnifunc' and val or ''
      completefunc = source_func == 'completefunc' and val or ''
    end

    eq(child.bo.omnifunc, omnifunc)
    eq(child.bo.completefunc, completefunc)
  end

  validate(false)
  validate(true, 'omnifunc')
  validate(true, 'completefunc')
end

T['setup()']['respects `config.set_vim_settings`'] = function()
  reload_module({ set_vim_settings = true })
  expect.match(child.api.nvim_get_option('shortmess'), 'c')
  if child.fn.has('nvim-0.9') == 1 then expect.match(child.api.nvim_get_option('shortmess'), 'C') end
  eq(child.api.nvim_get_option('completeopt'), 'menuone,noselect')
end

T['default_process_items()'] = new_set({
  hooks = {
    pre_case = function()
      -- Mock LSP items
      child.lua([[
        _G.items = {
          { kind = 1,   label = "January",  sortText = "001" },
          { kind = 2,   label = "May",      sortText = "005" },
          { kind = 2,   label = "March",    sortText = "003" },
          { kind = 2,   label = "April",    sortText = "004" },
          { kind = 1,   label = "February", sortText = "002" },
          -- Unknown kind
          { kind = 100, label = "July",     sortText = "007" },
          { kind = 3,   label = "June",     sortText = "006" },
        }
      ]])
    end,
  },
})

T['default_process_items()']['works'] = function()
  local ref_processed_items = {
    { kind = 2, label = 'March', sortText = '003' },
    { kind = 2, label = 'May', sortText = '005' },
  }
  eq(child.lua_get('MiniCompletion.default_process_items(_G.items, "M")'), ref_processed_items)
end

T['default_process_items()']["highlights LSP kind if 'mini.icons' is enabled"] = function()
  mock_miniicons()
  local ref_hlgroup = child.lua_get('_G.ref_hlgroup')
  local ref_processed_items = {
    { kind = 1, kind_hlgroup = ref_hlgroup.text, label = 'January', sortText = '001' },
    { kind = 3, kind_hlgroup = ref_hlgroup.func, label = 'June', sortText = '006' },
    -- Unknown kind should not get highlighted
    { kind = 100, kind_hlgroup = nil, label = 'July', sortText = '007' },
  }
  eq(child.lua_get('MiniCompletion.default_process_items(_G.items, "J")'), ref_processed_items)

  -- Should not modify original items
  eq(child.lua_get('_G.items[1].kind_hlgroup'), vim.NIL)
end

T['default_process_items()']['works after `MiniIcons.tweak_lsp_kind()`'] = function()
  mock_miniicons()
  child.lua('MiniIcons.tweak_lsp_kind()')

  local ref_hlgroup = child.lua_get('_G.ref_hlgroup')
  local ref_processed_items = {
    { kind = 1, kind_hlgroup = ref_hlgroup.text, label = 'January', sortText = '001' },
    { kind = 3, kind_hlgroup = ref_hlgroup.func, label = 'June', sortText = '006' },
    -- Unknown kind should not get highlighted
    { kind = 100, kind_hlgroup = nil, label = 'July', sortText = '007' },
  }
  eq(child.lua_get('MiniCompletion.default_process_items(_G.items, "J")'), ref_processed_items)
end

-- Integration tests ==========================================================
T['Autocompletion'] = new_set({
  hooks = {
    pre_case = function()
      -- Create new buffer to set buffer-local `completefunc` or `omnifunc`
      new_buffer()
      -- For details see mocking of 'textDocument/completion' request
      mock_lsp()
    end,
  },
})

T['Autocompletion']['works with LSP client'] = function()
  type_keys('i', 'J')
  eq(get_completion(), {})

  -- Shows completion only after delay
  sleep(default_completion_delay - small_time)
  eq(get_completion(), {})
  sleep(small_time + small_time)
  -- Both completion word and kind are shown
  eq(get_completion(), { 'January', 'June', 'July' })
  eq(get_completion('kind'), { 'Text', 'Function', 'Function' })

  -- Completion menu is filtered after entering characters
  type_keys('u')
  child.set_size(10, 20)
  child.expect_screenshot()
end

T['Autocompletion']['works without LSP clients'] = function()
  -- Mock absence of LSP
  child.lsp.buf_get_clients = function() return {} end
  child.lsp.get_clients = function() return {} end

  type_keys('i', 'aab aac aba a')
  eq(get_completion(), {})
  sleep(default_completion_delay - small_time)
  eq(get_completion(), {})
  sleep(small_time + small_time)
  eq(get_completion(), { 'aab', 'aac', 'aba' })

  -- Completion menu is filtered after entering characters
  type_keys('a')
  child.set_size(10, 20)
  child.expect_screenshot()
end

T['Autocompletion']['implements debounce-style delay'] = function()
  type_keys('i', 'J')

  sleep(default_completion_delay - small_time)
  eq(get_completion(), {})
  type_keys('u')
  sleep(default_completion_delay - small_time)
  eq(get_completion(), {})
  sleep(small_time + small_time)
  eq(get_completion(), { 'June', 'July' })
end

T['Autocompletion']['uses fallback'] = function()
  set_lines({ 'Jackpot', '' })
  set_cursor(2, 0)

  type_keys('i', 'Ja')
  sleep(default_completion_delay + small_time)
  eq(get_completion(), { 'January' })

  -- Due to how 'completefunc' and 'omnifunc' currently work, fallback won't
  -- trigger after the first character which lead to empty completion list.
  -- The reason seems to be that at that point Neovim's internal filtering of
  -- completion items is still "in charge" (backspace leads to previous
  -- completion item list without reevaluating completion function). It is
  -- only after the next character completion function gets reevaluated
  -- leading to zero items from LSP which triggers fallback action.
  type_keys('c')
  eq(child.fn.pumvisible(), 0)
  type_keys('k')
  eq(get_completion(), { 'Jackpot' })
end

T['Autocompletion']['forces new LSP completion at LSP trigger'] = new_set(
  -- Test with different source functions because they (may) differ slightly on
  -- how certain completion events (`CompleteDonePre`) are triggered, which
  -- affects whether autocompletion is done in certain cases (for example, when
  -- completion candidate is fully typed).
  -- See https://github.com/echasnovski/mini.nvim/issues/813
  { parametrize = { { 'completefunc' }, { 'omnifunc' } } },
  {
    test = function(source_func)
      reload_module({ lsp_completion = { source_func = source_func } })
      mock_completefunc_lsp_tracking()
      child.set_size(16, 20)
      child.api.nvim_set_current_buf(child.api.nvim_create_buf(true, false))

      --stylua: ignore
      local all_months = {
        'January', 'February', 'March', 'April', 'May', 'June',
        'July', 'August', 'September', 'October', 'November', 'December',
      }
      type_keys('i', '<C-Space>')
      eq(get_completion(), all_months)
      -- - Should only call two times, as per `:h complete-functions`, i.e. not
      --   use it to actually make request (which would have made it 3 times).
      eq(child.lua_get('_G.n_completfunc_lsp'), 2)

      type_keys('May.')
      eq(child.lua_get('_G.n_completfunc_lsp'), 2)
      eq(child.fn.pumvisible(), 0)
      sleep(default_completion_delay - small_time)
      eq(child.fn.pumvisible(), 0)
      sleep(small_time + small_time)
      eq(get_completion(), all_months)
      eq(child.lua_get('_G.n_completfunc_lsp'), 4)
      child.expect_screenshot()

      -- Should show only LSP without fallback, i.e. typing LSP trigger should
      -- show no completion if there is no LSP completion (as is imitated
      -- inside commented lines).
      type_keys('<Esc>o', '# .')
      sleep(default_completion_delay + small_time)
      child.expect_screenshot()
    end,
  }
)

T['Autocompletion']['works with `<BS>`'] = function()
  mock_completefunc_lsp_tracking()
  child.set_size(10, 20)
  child.api.nvim_set_current_buf(child.api.nvim_create_buf(true, false))

  type_keys('i', 'J', 'u', '<C-Space>')
  -- - Should only call two times, as per `:h complete-functions`: first to
  --   find the start column, second to return completion suggestions.
  eq(child.lua_get('_G.n_completfunc_lsp'), 2)

  type_keys('n')
  child.expect_screenshot()
  eq(child.lua_get('_G.n_completfunc_lsp'), 2)

  -- Should keep completion menu and adjust items without extra 'completefunc'
  -- calls (as it is still at or after initial start column)
  type_keys('<BS>')
  child.expect_screenshot()
  eq(child.lua_get('_G.n_completfunc_lsp'), 2)

  -- Should reevaluate completion list as it is past initial start column
  type_keys('<BS>')
  child.expect_screenshot()
  -- - Should call three times: first to make a request, second and third to
  --   act as a regular 'completefunc'/'omnifunc'
  eq(child.lua_get('_G.n_completfunc_lsp'), 5)
end

T['Autocompletion']['forces new LSP completion in case of `isIncomplete`'] = function()
  mock_completefunc_lsp_tracking()
  child.set_size(10, 20)
  child.api.nvim_set_current_buf(child.api.nvim_create_buf(true, false))

  -- Mock incomplete completion list which contains only months 1-6
  child.lua('_G.mock_isincomplete = true')
  type_keys('i', 'J', '<C-Space>')
  -- - Should not contain `July` as it is not in the response
  child.expect_screenshot()
  eq(child.lua_get('_G.n_textdocument_completion'), 1)
  -- - Should only call two times, as per `:h complete-functions`: first to
  --   find the start column, second to return completion suggestions.
  eq(child.lua_get('_G.n_completfunc_lsp'), 2)

  -- Should force new request which this time will be complete
  child.lua('_G.mock_isincomplete = false')
  type_keys('u')
  child.expect_screenshot()
  eq(child.lua_get('_G.n_textdocument_completion'), 2)
  -- - NOTE: not using completefunc to make an LSP request is a key to reduce
  --   flickering in this use case (as executing `<C-x>...` forces popup hide).
  eq(child.lua_get('_G.n_completfunc_lsp'), 4)

  -- Shouldn't force new requests or call 'completefunc' for complete responses
  type_keys('n')
  eq(child.lua_get('_G.n_textdocument_completion'), 2)
  eq(child.lua_get('_G.n_completfunc_lsp'), 4)
  type_keys('<BS>')
  eq(child.lua_get('_G.n_textdocument_completion'), 2)
  eq(child.lua_get('_G.n_completfunc_lsp'), 4)

  -- Should force new request if deleting past the start of previous request.
  -- This time response will be complete.
  type_keys('<BS>')
  child.expect_screenshot()
  eq(child.lua_get('_G.n_textdocument_completion'), 3)
  -- - Should call three times: first to make a request, second and third to
  --   act as a regular 'completefunc'/'omnifunc'
  eq(child.lua_get('_G.n_completfunc_lsp'), 7)
end

T['Autocompletion']['respects `config.delay.completion`'] = function()
  child.lua('MiniCompletion.config.delay.completion = ' .. (2 * default_completion_delay))

  type_keys('i', 'J')
  sleep(2 * default_completion_delay - small_time)
  eq(get_completion(), {})
  sleep(small_time + small_time)
  eq(get_completion(), { 'January', 'June', 'July' })

  -- Should also use buffer local config
  child.ensure_normal_mode()
  set_lines({ '' })
  set_cursor(1, 0)
  child.b.minicompletion_config = { delay = { completion = default_completion_delay } }
  type_keys('i', 'J')
  sleep(default_completion_delay - small_time)
  eq(get_completion(), {})
  sleep(small_time + small_time)
  eq(get_completion(), { 'January', 'June', 'July' })
end

T['Autocompletion']['respects `config.lsp_completion.process_items`'] = function()
  child.lua('_G.process_items = function(items, base) return { items[2], items[3] } end')
  child.lua('MiniCompletion.config.lsp_completion.process_items = _G.process_items')

  type_keys('i', 'J')
  sleep(default_completion_delay + small_time)
  eq(get_completion(), { 'February', 'March' })

  child.ensure_normal_mode()
  set_lines({ '' })
  set_cursor(1, 0)
  child.lua('_G.process_items_2 = function(items, base) return { items[4], items[5] } end')
  child.lua('vim.b.minicompletion_config = { lsp_completion = { process_items = _G.process_items_2 } }')

  type_keys('i', 'J')
  sleep(default_completion_delay + small_time)
  eq(get_completion(), { 'April', 'May' })
end

T['Autocompletion']['respects string `config.fallback_action`'] = function()
  child.set_size(10, 25)
  child.lua([[MiniCompletion.config.fallback_action = '<C-x><C-l>']])

  set_lines({ 'Line number 1', '' })
  set_cursor(2, 0)
  type_keys('i', 'L')
  sleep(default_completion_delay + small_time)
  child.expect_screenshot()

  -- Should also use buffer local config
  child.ensure_normal_mode()
  child.b.minicompletion_config = { fallback_action = '<C-p>' }
  set_lines({ 'Line number 1', '' })
  set_cursor(2, 0)
  type_keys('i', 'L')
  sleep(default_completion_delay + small_time)
  child.expect_screenshot()
end

T['Autocompletion']['respects function `config.fallback_action`'] = function()
  child.lua([[MiniCompletion.config.fallback_action = function() _G.inside_fallback = true end]])
  type_keys('i', 'a')
  sleep(default_completion_delay + small_time)
  eq(child.lua_get('_G.inside_fallback'), true)

  child.ensure_normal_mode()
  child.lua('vim.b.minicompletion_config = { fallback_action = function() _G.inside_local_fallback = true end }')
  type_keys('i', 'a')
  sleep(default_completion_delay + small_time)
  eq(child.lua_get('_G.inside_local_fallback'), true)
end

T['Autocompletion']['respects `vim.{g,b}.minicompletion_disable`'] = new_set({
  parametrize = { { 'g' }, { 'b' } },
}, {
  test = function(var_type)
    child[var_type].minicompletion_disable = true
    type_keys('i', 'J')
    sleep(default_completion_delay + small_time)
    eq(get_completion(), {})
  end,
})

T['Manual completion'] = new_set({
  hooks = {
    pre_case = function()
      -- Virtually disable auto-completion
      child.lua('MiniCompletion.config.delay.completion = 100000')
      -- Create new buffer to set buffer-local `completefunc` or `omnifunc`
      new_buffer()
      -- For details see mocking of 'textDocument/completion' request
      mock_lsp()

      set_lines({ 'Jackpot', '' })
      set_cursor(2, 0)
    end,
  },
})

T['Manual completion']['works with two-step completion'] = function()
  type_keys('i', 'J', '<C-Space>')
  eq(get_completion(), { 'January', 'June', 'July' })

  type_keys('ac')
  eq(child.fn.pumvisible(), 0)

  type_keys('<C-Space>')
  eq(get_completion(), { 'Jackpot' })
end

T['Manual completion']['uses `vim.lsp.protocol.CompletionItemKind` in LSP step'] = function()
  child.set_size(17, 30)
  child.lua([[vim.lsp.protocol = {
    CompletionItemKind = {
      [1] = 'Text',         Text = 1,
      [2] = 'Method',       Method = 2,
      [3] = 'S Something',  ['S Something'] = 3,
      [4] = 'Fallback',     Fallback = 4,
    },
  }]])
  type_keys('i', '<C-Space>')
  child.expect_screenshot()
end

T['Manual completion']['works with fallback action'] = function()
  type_keys('i', 'J', '<M-Space>')
  eq(get_completion(), { 'Jackpot' })
end

T['Manual completion']['works with explicit `<C-x>...`'] = new_set(
  { parametrize = { { 'completefunc' }, { 'omnifunc' } } },
  {
    test = function(source_func)
      reload_module({ lsp_completion = { source_func = source_func } })
      mock_completefunc_lsp_tracking()
      child.api.nvim_set_current_buf(child.api.nvim_create_buf(true, false))

      local source_keys = '<C-x>' .. (source_func == 'completefunc' and '<C-u>' or '<C-o>')
      type_keys('i', 'J', source_keys)
      eq(get_completion(), { 'January', 'June', 'July' })
      -- Should call three times: first to initiate request, second/third to
      -- perform its actions (as per `:h complete-functions`)
      eq(child.lua_get('_G.n_completfunc_lsp'), 3)
    end,
  }
)
T['Manual completion']['respects `config.mappings'] = function()
  reload_module({ mappings = { force_twostep = '<C-z>', force_fallback = '<C-x>' } })
  type_keys('i', 'J', '<C-z>')
  eq(get_completion(), { 'January', 'June', 'July' })
  type_keys('<C-x>')
  eq(get_completion(), { 'Jackpot' })
end

T['Manual completion']['applies `additionalTextEdits` from "textDocument/completion"'] = function()
  local validate = function(confirm_key)
    child.ensure_normal_mode()
    set_lines({})
    type_keys('i', 'Se', '<C-space>')
    child.poke_eventloop()
    type_keys('<C-n>', confirm_key)

    eq(child.fn.mode(), 'i')
    local is_explicit_confirm = confirm_key == '<C-y>'
    eq(
      get_lines(),
      { 'from months.completion import September', 'September' .. (is_explicit_confirm and '' or confirm_key) }
    )
    -- Text edits shouldn't interfere with relative cursor position
    eq(get_cursor(), { 2, 9 + (is_explicit_confirm and 0 or 1) })
  end

  -- 'Confirmation' should be either explicit ('<C-y>') or implicit
  -- (continued typing)
  validate('<C-y>')
  validate(' ')
end

T['Manual completion']['applies `additionalTextEdits` from "completionItem/resolve"'] = function()
  local validate = function(word_start, word)
    child.ensure_normal_mode()
    set_lines({})
    type_keys('i', word_start, '<C-space>')
    child.poke_eventloop()
    type_keys('<C-n>')
    -- Wait until `completionItem/resolve` request is sent
    sleep(default_info_delay + small_time)
    type_keys('<C-y>')

    eq(child.fn.mode(), 'i')
    eq(get_lines(), { 'from months.resolve import ' .. word, word })
    -- Text edits shouldn't interfere with relative cursor position
    eq(get_cursor(), { 2, word:len() })
  end

  -- Case when `textDocument/completion` doesn't have `additionalTextEdits`
  validate('Oc', 'October')

  -- Case when `textDocument/completion` does have `additionalTextEdits`
  validate('No', 'November')

  -- Should clear all possible cache for `additionalTextEdits`
  child.ensure_normal_mode()
  set_lines({})
  type_keys('i', 'Ja', '<C-space>')
  child.poke_eventloop()
  type_keys('<C-n>', '<C-y>')
  eq(get_lines(), { 'January' })
end

T['Manual completion']['prefers completion range from LSP response'] = function()
  set_lines({})
  type_keys('i', 'months.')
  -- Mock `textEdit` as in `tsserver` when called after `.`
  child.lua([[_G.mock_textEdit = {
    pos = vim.api.nvim_win_get_cursor(0),
    new_text = function(name) return '.' .. name end,
  } ]])
  type_keys('<C-space>')

  eq(get_completion('abbr'), { 'April', 'August' })
  eq(get_completion('word'), { '.April', '.August' })
  type_keys('<C-n>', '<C-y>')
  eq(get_lines(), { 'months.April' })
  eq(get_cursor(), { 1, 12 })
end

T['Manual completion']['respects `filterText` from LSP response'] = function()
  set_lines({})
  type_keys('i', 'months.')
  -- Mock `textEdit` and `filterText` as in `tsserver` when called after `.`
  -- (see https://github.com/echasnovski/mini.nvim/issues/306#issuecomment-1602245446)
  child.lua([[
    _G.mock_textEdit = {
      pos = vim.api.nvim_win_get_cursor(0),
      new_text = function(name) return '[' .. name .. ']' end,
    }
    _G.mock_filterText = function(name) return '.' .. name end
  ]])
  type_keys('<C-space>')

  eq(get_completion('abbr'), { 'April', 'August' })
  eq(get_completion('word'), { '[April]', '[August]' })
  type_keys('<C-n>', '<C-y>')
  eq(get_lines(), { 'months[April]' })
  eq(get_cursor(), { 1, 13 })
end

T['Manual completion']['respects `labelDetails` from LSP response'] = function()
  child.set_size(16, 32)
  child.lua([[
    MiniCompletion.config.lsp_completion.process_items = function(items, base)
      for _, it in ipairs(items) do
        if it.label == 'January' then it.labelDetails = { detail = 'jan' } end
        if it.label == 'February' then it.labelDetails = { description = 'FEB' } end
        -- Should use both `detail` and `description`
        if it.label == 'March' then it.labelDetails = { detail = 'mar', description = 'MAR' } end
      end
      return MiniCompletion.default_process_items(items, base)
    end
  ]])

  set_lines({})
  type_keys('i', '<C-Space>')
  child.expect_screenshot()
end

T['Manual completion']['respects `kind_hlgroup` as item field'] = function()
  if child.fn.has('nvim-0.11') == 0 then MiniTest.skip('Kind highlighting is available on Neovim>=0.11') end
  child.set_size(10, 40)
  set_lines({})

  child.lua([[
    MiniCompletion.config.lsp_completion.process_items = function(items, base)
      local res = vim.tbl_filter(function(x) return vim.startswith(x.label, base) end, items)
      table.sort(res, function(a, b) return a.sortText < b.sortText end)
      for _, item in ipairs(res) do
        if item.label == 'January' then item.kind_hlgroup = 'String' end
        if item.label == 'June' then item.kind_hlgroup = 'Comment' end
      end
      return res
    end
  ]])
  type_keys('i', 'J', '<C-Space>')
  child.expect_screenshot()
end

T['Manual completion']['respects `vim.{g,b}.minicompletion_disable`'] = new_set({
  parametrize = { { 'g' }, { 'b' } },
}, {
  test = function(var_type)
    child[var_type].minicompletion_disable = true
    type_keys('i', '<C-Space>')
    child.poke_eventloop()
    eq(get_completion(), {})

    type_keys('i', '<M-Space>')
    child.poke_eventloop()
    eq(get_completion(), {})
  end,
})

T['Information window'] = new_set({
  hooks = {
    pre_case = function()
      -- Create new buffer to set buffer-local `completefunc` or `omnifunc`
      new_buffer()
      -- For details see mocking of 'textDocument/completion' request
      mock_lsp()
    end,
  },
})

local validate_info_win = function(delay)
  type_keys('i', 'J', '<C-Space>')
  eq(get_completion(), { 'January', 'June', 'July' })

  type_keys('<C-n>')
  eq(get_floating_windows(), {})
  sleep(delay - small_time)
  eq(get_floating_windows(), {})
  sleep(small_time + small_time)
  validate_single_floating_win({ lines = { 'Month #01' } })
end

T['Information window']['works'] = function()
  child.set_size(10, 40)
  validate_info_win(default_info_delay)
  child.expect_screenshot()
end

T['Information window']['respects `config.delay.info`'] = function()
  child.lua('MiniCompletion.config.delay.info = ' .. (2 * default_info_delay))
  validate_info_win(2 * default_info_delay)

  -- Should also use buffer local config
  child.ensure_normal_mode()
  set_lines({ '' })
  child.b.minicompletion_config = { delay = { info = default_info_delay } }
  validate_info_win(default_info_delay)
end

local validate_info_window_config = function(keys, completion_items, win_config)
  type_keys('i', keys, '<C-Space>')
  eq(get_completion(), completion_items)

  type_keys('<C-n>')
  -- Some windows can take a while to process on slow machines. So add `10`
  -- to ensure that processing is finished.
  sleep(default_info_delay + small_time)
  validate_single_floating_win({ config = win_config })
end

T['Information window']['respects `config.window.info`'] = function()
  child.set_size(25, 60)
  local win_config = { height = 20, width = 40, border = 'single' }
  child.lua('MiniCompletion.config.window.info = ' .. vim.inspect(win_config))
  validate_info_window_config('D', { 'December' }, {
    height = 20,
    width = 40,
    border = { '┌', '─', '┐', '│', '┘', '─', '└', '│' },
  })
  child.expect_screenshot()

  -- Should also use buffer local config
  child.ensure_normal_mode()
  set_lines({ '' })
  local test_border = { '1', '2', '3', '4', '5', '6', '7', '8' }
  child.b.minicompletion_config = { window = { info = { height = 10, width = 20, border = test_border } } }
  validate_info_window_config('D', { 'December' }, { height = 10, width = 20, border = test_border })
  child.expect_screenshot()
end

T['Information window']['accounts for border when picking side'] = function()
  child.set_size(10, 40)
  child.lua([[MiniCompletion.config.window.info.border = 'single']])

  set_lines({ 'aaaaaaaaaaaa ' })
  type_keys('A', 'J', '<C-Space>', '<C-n>')
  sleep(default_info_delay + small_time)
  child.expect_screenshot()
end

T['Information window']['has minimal dimensions for small text'] = function()
  child.set_size(10, 40)
  child.lua('MiniCompletion.config.window.info.height = 1')
  child.lua('MiniCompletion.config.window.info.width = 9')
  validate_info_window_config('J', { 'January', 'June', 'July' }, { height = 1, width = 9 })
  child.expect_screenshot()
end

T['Information window']['adjusts window width'] = function()
  child.set_size(10, 27)
  child.lua([[MiniCompletion.config.window.info= { height = 15, width = 10, border = 'single' }]])

  type_keys('i', 'J', '<C-Space>', '<C-n>')
  sleep(default_info_delay + small_time)
  child.expect_screenshot()
end

T['Information window']['stylizes markdown with concealed characters'] = function()
  if child.fn.has('nvim-0.10') == 0 then MiniTest.skip('Screenshots are generated for Neovim>=0.10') end

  child.set_size(15, 45)
  type_keys('i', 'Jul', '<C-Space>')
  type_keys('<C-n>')
  eq(get_floating_windows(), {})
  sleep(default_info_delay + small_time)
  child.expect_screenshot()
end

T['Information window']['uses `detail` to construct content'] = function()
  if child.fn.has('nvim-0.10') == 0 then MiniTest.skip('Screenshots are generated for Neovim>=0.10') end
  child.bo.filetype = 'lua'

  child.set_size(15, 45)
  type_keys('i', 'A', '<C-Space>')

  -- Should show `detail` in language's code block if it is new information
  -- Should also trim `detail` for a more compact view
  type_keys('<C-n>')
  sleep(default_info_delay + small_time)
  child.expect_screenshot()

  -- Should omit `detail` if its content is already present in `documentation`
  type_keys('<C-n>')
  sleep(default_info_delay + small_time)
  child.expect_screenshot()
end

T['Information window']['ignores data from first response if server can resolve completion item'] = function()
  if child.fn.has('nvim-0.10') == 0 then MiniTest.skip('Screenshots are generated for Neovim>=0.10') end

  child.set_size(10, 45)
  child.lua([[
    MiniCompletion.config.lsp_completion.process_items = function(items, base)
      for _, it in ipairs(items) do
        if it.label == 'April' then
          it.detail = 'Initial detail'
          it.documentation = 'Initial documentation'
        end
      end
      return MiniCompletion.default_process_items(items, base)
    end
  ]])

  set_lines({})
  type_keys('i', 'Apr', '<C-Space>')
  type_keys('<C-n>')
  sleep(default_info_delay + small_time)
  -- Should show resolved data and not initial in order to always prefer
  -- resolved if possible. This is useful if initial response contains only
  -- single `detail` or `documentation` but resolving gets them both (like in
  -- `r-language-server`, for example).
  child.expect_screenshot()
end

T['Information window']['adjusts for top/bottom code block delimiters'] = function()
  if child.fn.has('nvim-0.10') == 0 then MiniTest.skip('Screenshots are generated for Neovim>=0.10') end

  child.set_size(10, 30)
  type_keys('i', 'Sep', '<C-Space>')
  type_keys('<C-n>')
  sleep(default_info_delay + small_time)
  -- Should show floating window with height 1, i.e. both top and bottom code
  -- block delimiters should be hidden
  child.expect_screenshot()
end

T['Information window']['uses `info` field from not LSP source'] = function()
  child.set_size(10, 30)
  child.lua([[
    MiniCompletion.config.fallback_action = function()
      vim.fn.complete(1, { { word = 'Fall', abbr = 'Fall', info = 'back' } })
    end
  ]])

  set_lines({})
  type_keys('i', '<A-Space>')
  type_keys('<C-n>')
  sleep(default_info_delay + small_time)
  child.expect_screenshot()
end

T['Information window']['implements debounce-style delay'] = function()
  type_keys('i', 'J', '<C-Space>')
  eq(get_completion(), { 'January', 'June', 'July' })

  type_keys('<C-n>')
  sleep(default_info_delay - small_time)
  eq(#get_floating_windows(), 0)
  type_keys('<C-n>')
  sleep(default_info_delay - small_time)
  eq(#get_floating_windows(), 0)
  sleep(small_time + small_time)
  validate_single_floating_win({ lines = { 'Month #06' } })
end

T['Information window']['is closed when forced outside of Insert mode'] = new_set(
  { parametrize = { { '<Esc>' }, { '<C-c>' } } },
  {
    test = function(key)
      type_keys('i', 'J', '<C-Space>')
      eq(get_completion(), { 'January', 'June', 'July' })

      type_keys('<C-n>')
      sleep(default_info_delay + small_time)
      validate_single_floating_win({ lines = { 'Month #01' } })

      type_keys(key)
      eq(get_floating_windows(), {})
    end,
  }
)

T['Information window']['handles all buffer wipeout'] = function()
  validate_info_win(default_info_delay)
  child.ensure_normal_mode()

  child.cmd('%bw!')
  new_buffer()
  mock_lsp()

  validate_info_win(default_info_delay)
end

T['Information window']['respects `vim.{g,b}.minicompletion_disable`'] = new_set({
  parametrize = { { 'g' }, { 'b' } },
}, {
  test = function(var_type)
    child[var_type].minicompletion_disable = true

    set_lines({ 'aa ab ', '' })
    set_cursor(2, 0)
    type_keys('i', '<C-n>', '<C-n>')
    sleep(default_info_delay + small_time)
    eq(#get_floating_windows(), 0)
  end,
})

T['Signature help'] = new_set({
  hooks = {
    pre_case = function()
      -- Create new buffer to set buffer-local `completefunc` or `omnifunc`
      new_buffer()
      -- For details see mocking of 'textDocument/completion' request
      mock_lsp()
    end,
  },
})

local validate_signature_win = function(delay)
  type_keys('i', 'abc(')

  eq(get_floating_windows(), {})
  sleep(delay - small_time)
  eq(get_floating_windows(), {})
  sleep(small_time + small_time)
  validate_single_floating_win({ lines = { 'abc(param1, param2)' } })
end

T['Signature help']['works'] = function()
  child.set_size(7, 30)
  validate_signature_win(default_signature_delay)
  child.expect_screenshot()
end

T['Signature help']['respects `config.delay.signature`'] = function()
  child.lua('MiniCompletion.config.delay.signature = ' .. (2 * default_signature_delay))
  validate_signature_win(2 * default_signature_delay)

  -- Should also use buffer local config
  child.ensure_normal_mode()
  set_lines({ '' })
  child.b.minicompletion_config = { delay = { signature = default_signature_delay } }
  validate_signature_win(default_signature_delay)
end

T['Signature help']['updates highlighting of active parameter'] = function()
  child.set_size(7, 30)
  child.cmd('startinsert')

  type_keys('abc(')
  sleep(default_signature_delay + small_time)
  child.expect_screenshot()

  type_keys('1,')
  sleep(default_signature_delay + small_time)
  child.expect_screenshot()

  -- As there are only two parameters, nothing should be highlighted
  type_keys('2,')
  sleep(default_signature_delay + small_time)
  child.expect_screenshot()
end

local validate_signature_window_config = function(keys, win_config)
  child.cmd('startinsert')
  type_keys(keys)
  sleep(default_signature_delay + small_time)
  validate_single_floating_win({ config = win_config })
end

T['Signature help']['respects `config.window.signature`'] = function()
  local keys = { 'l', 'o', 'n', 'g', '(' }
  local win_config = { height = 15, width = 40, border = 'single' }
  child.lua('MiniCompletion.config.window.signature = ' .. vim.inspect(win_config))
  validate_signature_window_config(keys, {
    height = 15,
    width = 40,
    border = { '┌', '─', '┐', '│', '┘', '─', '└', '│' },
  })
  child.expect_screenshot()

  -- Should also use buffer local config
  child.ensure_normal_mode()
  set_lines({ '' })
  local test_border = { '1', '2', '3', '4', '5', '6', '7', '8' }
  child.b.minicompletion_config = { window = { signature = { height = 10, width = 20, border = test_border } } }
  validate_signature_window_config(keys, { height = 10, width = 20, border = test_border })
  child.expect_screenshot()
end

T['Signature help']['accounts for border when picking side'] = function()
  child.set_size(10, 40)
  child.lua([[MiniCompletion.config.window.signature.border = 'single']])

  type_keys('o<CR>', 'abc(')
  sleep(default_signature_delay + small_time)
  child.expect_screenshot()
end

T['Signature help']['has minimal dimensions for small text'] = function()
  child.set_size(7, 30)
  local keys = { 'a', 'b', 'c', '(' }
  child.lua('MiniCompletion.config.window.signature.height = 1')
  child.lua('MiniCompletion.config.window.signature.width = 19')
  validate_signature_window_config(keys, { height = 1, width = 19 })
  child.expect_screenshot()
end

T['Signature help']['adjusts window height'] = function()
  child.set_size(10, 25)
  child.lua([[MiniCompletion.config.window.signature = { height = 15, width = 10, border = 'single' }]])

  type_keys('i', 'long(')
  sleep(default_signature_delay + small_time)
  child.expect_screenshot()
end

T['Signature help']['handles multiline text'] = function()
  child.set_size(10, 35)

  type_keys('i', 'multiline(')
  sleep(default_signature_delay + small_time)
  child.expect_screenshot()
end

T['Signature help']['stylizes markdown with concealed characters'] = function()
  if child.fn.has('nvim-0.10') == 0 then MiniTest.skip('Screenshots are generated for Neovim>=0.10') end

  child.set_size(10, 65)
  child.bo.filetype = 'lua'
  type_keys('i', 'string.format(')
  sleep(default_signature_delay + small_time)
  child.expect_screenshot()
end

T['Signature help']['implements debounce-style delay'] = function()
  child.cmd('startinsert')
  type_keys('abc(')
  sleep(default_signature_delay - small_time)
  type_keys('d')
  sleep(default_signature_delay + small_time)
  eq(#get_floating_windows(), 0)

  type_keys(',')
  sleep(default_signature_delay + small_time)
  validate_single_floating_win({ lines = { 'abc(param1, param2)' } })
end

T['Signature help']['is closed when forced outside of Insert mode'] = new_set(
  { parametrize = { { '<Esc>' }, { '<C-c>' } } },
  {
    test = function(key)
      type_keys('i', 'abc(')
      sleep(default_signature_delay + small_time)
      validate_single_floating_win({ lines = { 'abc(param1, param2)' } })

      type_keys(key)
      eq(get_floating_windows(), {})
    end,
  }
)

T['Signature help']['handles all buffer wipeout'] = function()
  validate_signature_win(default_signature_delay)
  child.ensure_normal_mode()

  child.cmd('%bw!')
  new_buffer()
  mock_lsp()

  validate_signature_win(default_signature_delay)
end

T['Signature help']['respects `vim.{g,b}.minicompletion_disable`'] = new_set({
  parametrize = { { 'g' }, { 'b' } },
}, {
  test = function(var_type)
    child[var_type].minicompletion_disable = true

    type_keys('i', 'abc(')
    sleep(default_signature_delay + small_time)
    eq(#get_floating_windows(), 0)
  end,
})

T['Scroll'] = new_set({
  hooks = {
    pre_case = function()
      new_buffer()
      mock_lsp()
      child.set_size(10, 25)
    end,
  },
})

T['Scroll']['can be done in info window'] = function()
  child.lua('MiniCompletion.config.window.info.height = 4')

  type_keys('i', 'F', '<C-Space>')
  type_keys('<C-n>')
  sleep(default_info_delay + small_time)
  child.expect_screenshot()

  type_keys('<C-f>')
  child.expect_screenshot()
  type_keys('<C-f>')
  child.expect_screenshot()
  type_keys('<C-f>')
  child.expect_screenshot()

  type_keys('<C-b>')
  child.expect_screenshot()
  type_keys('<C-b>')
  child.expect_screenshot()
  type_keys('<C-b>')
  child.expect_screenshot()
end

T['Scroll']['can be done in signature window'] = function()
  if child.fn.has('nvim-0.10') == 0 then MiniTest.skip("'smoothscroll' requires Neovim>=0.10") end

  child.lua('MiniCompletion.config.window.signature.height = 4')
  child.lua('MiniCompletion.config.window.signature.width = 4')

  type_keys('i', 'scroll(')
  sleep(default_signature_delay + small_time)
  child.expect_screenshot()

  -- NOTE: there are `<<<` characters at the top during `:h 'smoothscroll'`
  local ignore_smoothscroll_lines = { ignore_lines = { 3 } }

  type_keys('<C-f>')
  child.expect_screenshot(ignore_smoothscroll_lines)
  type_keys('<C-f>')
  child.expect_screenshot(ignore_smoothscroll_lines)

  type_keys('<C-b>')
  child.expect_screenshot(ignore_smoothscroll_lines)
  type_keys('<C-b>')
  child.expect_screenshot()
end

T['Scroll']['can be done in both windows'] = function()
  child.lua('MiniCompletion.config.window.info.height = 4')
  child.lua('MiniCompletion.config.window.signature.height = 4')
  child.lua('MiniCompletion.config.window.signature.width = 4')

  type_keys('i', 'scroll(')
  sleep(default_signature_delay + small_time)

  type_keys('F', '<C-Space>')
  type_keys('<C-n>')
  sleep(default_info_delay + small_time)
  child.expect_screenshot()

  -- Should prefer scrolling in info window if both are visible
  type_keys('<C-f>')
  child.expect_screenshot()
  type_keys('<C-b>')
  child.expect_screenshot()

  if child.fn.has('nvim-0.10') == 0 then MiniTest.skip("'smoothscroll' requires Neovim>=0.10") end
  type_keys('<C-e>')
  type_keys('<C-f>')
  child.expect_screenshot()
end

T['Scroll']['respects `config.mappings`'] = function()
  child.lua([[
    vim.keymap.del('i', '<C-f>')
    vim.keymap.del('i', '<C-b>')
    MiniCompletion.setup({
      lsp_completion = { source_func = 'omnifunc' },
      mappings = { scroll_down = '<C-d>', scroll_up = '<C-u>' },
      window = { info = { height = 4 } },
    })
  ]])

  new_buffer()
  mock_lsp()

  type_keys('i', 'F', '<C-Space>')
  type_keys('<C-n>')
  sleep(default_info_delay + small_time)
  child.expect_screenshot()

  type_keys('<C-d>')
  child.expect_screenshot()
  type_keys('<C-u>')
  child.expect_screenshot()
  type_keys('<C-e>')

  -- Mapped keys can be used without active target window
  set_lines({ '  Line' })
  set_cursor(1, 6)
  type_keys('<C-d>')
  eq(get_lines(), { 'Line' })
  type_keys('<C-u>')
  eq(get_lines(), { '' })
end

return T
