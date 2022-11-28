local config = require("ror.config").values.test
local coverage = require("ror.test.coverage")
local notify_instance = require("ror.test.notify")

local M = {}

local function read_file(file)
  local f = assert(io.open(file, "rb"))
  local content = f:read("*all")
  f:close()
  return content
end


local function split(s, delimiter)
  local result = {};

  for match in ((s or '')..delimiter):gmatch("(.-)"..delimiter) do
    table.insert(result, match);
  end

  return result;
end

local function find_behaves_like_line(decoded)
  local file_string = read_file(decoded.file_path)

  if not file_string then
    return 1
  end

  local file = split(file_string, "\n")
  local result

  for i = tonumber(decoded.line_number),1,-1 do
    local regexp = "shared_examples ['\"](.*)['\"]"
    result = file[i]:match(regexp)

    if result then
      break
    end
  end

  if result then
    local lines = vim.fn.getline(1, '$')

    for i = 1, #lines, 1 do
      if lines[i]:match("it_behaves_like [\'\"]" .. result .. "[\'\"]") then
        return i
      end
    end

    return 1
  else
    return 1
  end
end

local function get_coverage_percentage(test_path)
  local root_path = vim.fn.getcwd()
  local original_file_path = string.gsub(test_path, "spec", "/app", 1)
  original_file_path = root_path .. string.gsub(original_file_path, "_spec", "")

  local _, finish = string.find(original_file_path, ".rb")

  if finish ~= nil then
    original_file_path = string.sub(original_file_path, 1, finish)
  end

  return coverage.percentage(original_file_path)
end

function M.run(test_path, bufnr, ns, terminal_bufnr, notify_record, type)
  local cmd

  if type == "Last" then
    cmd = vim.g.ror_last_command
  else
    cmd = { "bundle", "exec", "rspec", test_path, "--format", "j" }
  end

  if type == "OnlyFailures" then
    table.insert(cmd, "--only-failures")
  end

  vim.g.ror_last_command = cmd

  vim.fn.termopen(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      local failed = {}

      if not data then
        return
      end

      local function filter_result(response_data)
        if #response_data == 1 then
          -- Without hitting the debugger/pry
          return vim.json.decode(response_data[1])
        else
          local function filter_response(response)
            for _, v in ipairs(response) do
              if string.find(v, '{"version"') then
                return v
              elseif string.find(v, "{\"version\"") then
                return v
              end
            end
          end

          local filtered_result = filter_response(response_data)

          local function get_start_index(result)
            local start, _ = string.find(result, '{"version"')
            if start == nil then
              start, _ = string.find(result, '{"version"')
            end

            return start
          end

          local function get_finish_index(result)
            local _, finish = string.find(result, 'failure"}')
            if finish == nil then
              _, finish = string.find(result, 'failures"}')
            end

            return finish
          end

          local start_index = get_start_index(filtered_result)
          local finish_index = get_finish_index(filtered_result)

          return vim.json.decode(string.sub(filtered_result, start_index, finish_index))
        end
      end

      local result = filter_result(data)
      M.summary = result.summary

      for _, decoded in ipairs(result.examples) do
        if decoded.file_path ~= nil and decoded.file_path ~= "" then
          local is_shared_example = not(string.find(decoded.file_path, vim.fn.fnamemodify(test_path, ":t:r")) ~= nil)

          if decoded.status == "passed" then
            local text = { config.pass_icon }
            local line

            if is_shared_example then
              line = find_behaves_like_line(decoded)
            else
              line = decoded.line_number
            end

            vim.api.nvim_buf_set_extmark(bufnr, ns, tonumber(line) - 1, 0, {
              virt_text = { text }
            })
          else
            local function filter_backtrace(backtrace)
              local new_table = {}
              local index = 1
              for _, v in ipairs(backtrace) do
                if string.find(v, '_spec.rb:') then
                  new_table[index] = v
                  break
                end
              end

              return new_table
            end

            local fail_backtrace = filter_backtrace(decoded.exception.backtrace)[1]
            local example_line
            local exception_message

            if is_shared_example then
              exception_message = (decoded.description or '') ..
                  ' at ' .. (decoded.line_number or '') .. ': ' .. decoded.exception.message
              example_line = find_behaves_like_line(decoded)
            else
              exception_message = decoded.exception.message
              example_line = string.match(fail_backtrace, ":([^:]+)")
            end

            local text = { config.fail_icon }
            vim.api.nvim_buf_set_extmark(bufnr, ns, tonumber(example_line) - 1, 0, {
              virt_text = { text }
            })
            table.insert(failed, {
              bufnr = bufnr,
              lnum = tonumber(example_line) - 1,
              col = 0,
              severity = vim.diagnostic.severity.ERROR,
              source = "rspec",
              message = exception_message,
              user_data = {},
            })
          end
        end
      end

      vim.diagnostic.set(ns, bufnr, failed, {})
    end,
    on_stderr = function(_, data)
      if data[1] ~= "" then
        print("Error DATA: ")
        print(vim.inspect(data))
      end
    end,
    on_exit = function()
      local coverage_ok, coverage_percentage = pcall(get_coverage_percentage, test_path)

      -- Set the statistics window
      local message = "Examples: " .. M.summary.example_count .. ", Failures: " .. M.summary.failure_count

      if coverage_ok and coverage_percentage ~= nil then
        local formatted_coverage = string.format("%.2f%%", coverage_percentage)
        message = message .. ", Coverage: " .. formatted_coverage
      end

      local kind

      if M.summary.failure_count and M.summary.failure_count > 0 then
        kind = vim.log.levels.ERROR
      else
        kind = vim.log.levels.INFO
      end

      pcall(notify_instance.notify,
        message,
        kind,
        notify_record,
        {
          bufnr = bufnr,
          title = "Result: " .. vim.fn.fnamemodify(test_path, ":t")
        }
      )
      -- delete the terminal buffer
      vim.api.nvim_buf_delete(terminal_bufnr, {})
    end,
  })
end

return M
