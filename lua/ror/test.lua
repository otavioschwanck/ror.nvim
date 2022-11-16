local config = require("ror.config").values.test
local notify = require("ror.notify").notify

local M = {}

local function get_notification_message(relative_file_path, cursor_position)
  if type == "Line" then
    return config.message.line .. ": " .. relative_file_path .. ":" .. cursor_position .. "..."
  else
    return config.message.file .. ": " .. relative_file_path .. "..."
  end
end

local function win_config(relative_file_path, cursor_position)
  local notification_length = #get_notification_message(relative_file_path, cursor_position)

  local ui = vim.api.nvim_list_uis()[1]
  return {
    relative="editor",
    anchor = "SW",
    width=notification_length,
    height=1,
    row=0,
    col=(ui.width / 2) - (notification_length / 2),
    border="double",
    style="minimal"
  }
end

local function execute_float_window(relative_file_path, cursor_position)
  if M.notification_winnr ~= nil and vim.api.nvim_win_is_valid(M.notification_winnr) then
    vim.api.nvim_win_close(tonumber(M.notification_winnr), true)
  end
  if M.notification_bufnr ~= nil and vim.api.nvim_buf_is_valid(M.notification_bufnr) then
    vim.api.nvim_buf_delete(M.notification_bufnr, {})
  end

  local notification_bufnr = vim.api.nvim_create_buf(false, true)
  M.notification_bufnr = notification_bufnr

  local notification_winnr = vim.api.nvim_open_win(notification_bufnr, false, win_config(relative_file_path, cursor_position))
  M.notification_winnr = notification_winnr

  vim.api.nvim_win_set_option(notification_winnr, "winhl", "Normal:MoreMsg")
  vim.api.nvim_buf_set_lines(notification_bufnr, 0, -1, false, { get_notification_message(relative_file_path, cursor_position) })

  return notification_winnr, notification_bufnr
end

local function execute_notification(relative_file_path, cursor_position)
  if config.notification_style == "buffer" then
    return execute_float_window(relative_file_path, cursor_position)
  else
    local message = get_notification_message(relative_file_path, cursor_position)

    notify(message)
  end
end

local function non_empty_last_line(bufnr)
  local lines = vim.fn.getbufline(bufnr, 1, '$')

  local line = ""

  for i = #lines, 1, -1 do
    if lines[i] ~= "" then
      line = lines[i]

      break
    end
  end

  return line
end

local function verify_debugger()
  if M.terminal_bufnr and vim.fn.bufexists(M.terminal_bufnr) then
    local last_line = non_empty_last_line(M.terminal_bufnr)

    if last_line == '[Process exited 1]' or vim.fn.bufnr() == M.terminal_bufnr then
      return
    elseif last_line:match('%(byebug%)') or last_line:match('pry%(#.*%)') or last_line:match('%(rdbg%)') or last_line == ':' then
      M.attach_terminal()
      vim.cmd("startinsert")
    else
      vim.fn.timer_start(500, function ()
        verify_debugger()
      end)
    end
  end
end

local function run(type)
  local bufnr = vim.api.nvim_get_current_buf()
  local ns = vim.api.nvim_create_namespace("ror-minitest")
  local relative_file_path = vim.fn.expand("%:~:.")
  local cursor_position = vim.api.nvim_win_get_cursor(0)[1]

  local function get_test_path()
    if type == "Line" then
      return relative_file_path .. ":" .. cursor_position
    else
      return relative_file_path
    end
  end
  local test_path = get_test_path()

  local terminal_bufnr = vim.api.nvim_create_buf(false, true)

  M.terminal_bufnr = terminal_bufnr

  -- Clear extmark
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  -- Reset current diagnostic
  vim.diagnostic.reset(ns, bufnr)

  local notification_winnr, notification_bufnr = execute_notification(relative_file_path, cursor_position)

  vim.fn.timer_start(500, function ()
    verify_debugger()
  end)


  vim.api.nvim_buf_call(terminal_bufnr, function()
    if string.find(test_path, "_spec.rb") then
      require("ror.test.rspec").run(test_path, bufnr, ns, notification_winnr, notification_bufnr, terminal_bufnr)
    else
      require("ror.test.minitest").run(test_path, bufnr, ns, notification_winnr, notification_bufnr, terminal_bufnr)
    end
  end)
end

local function clear()
  local bufnr = vim.api.nvim_get_current_buf()
  local ns = vim.api.nvim_create_namespace("ror-minitest")
  -- Clear extmark
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  -- Hide current diagnostic
  vim.diagnostic.hide(ns, bufnr)

  if M.notification_winnr ~= nil and vim.api.nvim_win_is_valid(M.notification_winnr) then
    vim.api.nvim_win_close(tonumber(M.notification_winnr), true)
  end
  if M.notification_bufnr ~= nil and vim.api.nvim_buf_is_valid(M.notification_bufnr) then
    vim.api.nvim_buf_delete(M.notification_bufnr, {})
  end

  -- Reseting
  M.notification_bufnr = nil
  M.notification_winnr = nil
end

function M.run(type)
  run(type)
end

function M.clear()
  clear()
end

function M.attach_terminal()
  if M.terminal_bufnr ~= nil and vim.fn.buffer_exists(M.terminal_bufnr) ~= 0 then
    local ui = vim.api.nvim_list_uis()[1]
    local width = math.floor((ui.width * 0.5) + 0.5)
    local height = math.floor((ui.height * 0.5) + 0.5)

    local term_buf_info = vim.fn.getbufinfo(M.terminal_bufnr)[1]

    local window_config = {
      relative = "editor",
      anchor = "SW",
      width = width,
      height = height,
      col = (ui.width - width) / 2,
      row = (ui.height - height),
      style = 'minimal',
      border = "double"
    }

    if term_buf_info.hidden == 1 then
      vim.api.nvim_open_win(
        M.terminal_bufnr,
        true,
        window_config
      )
    else
      vim.api.nvim_win_close(0, true)
    end
  else
    print("No active terminal buffer to attach to.")
  end
end

return M
