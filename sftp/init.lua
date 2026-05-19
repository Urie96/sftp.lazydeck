local file = require 'file'
local config = require 'sftp.config'
local Provider = require 'sftp.provider'

local M = {}

function M.meta()
  return {
    icon = '󰈁',
    desc = 'SFTP file browser',
    color = 'cyan',
  }
end

local runtime = {
  cfg = config.new(),
  browsers = {},
}

local function span(text, color)
  local s = deck.style.span(tostring(text or ''))
  if color and color ~= '' then s = s:fg(color) end
  return s
end

local function line(parts) return deck.style.line(parts) end
local function text(lines) return deck.style.text(lines) end

local function info_entry(key, message, color)
  return {
    key = key,
    kind = 'info',
    message = message,
    display = line {
      span(message, color or 'darkgray'),
    },
    preview = function(self, cb)
      cb(text {
        line { span(self.message or message, color or 'darkgray') },
      })
    end,
  }
end

local function profile_names()
  local out = {}
  for name in pairs(runtime.cfg.profiles or {}) do
    table.insert(out, name)
  end
  table.sort(out, function(a, b) return string.lower(a) < string.lower(b) end)
  return out
end

local function profile_entry(profile)
  local target = profile.user ~= '' and (profile.user .. '@' .. profile.host) or profile.host
  return {
    key = profile.name,
    kind = 'profile',
    profile = profile.name,
    display = line {
      span(profile.name, 'cyan'),
      span('  ', 'darkgray'),
      span(target, 'white'),
      span('  ', 'darkgray'),
      span(profile.base_dir, 'yellow'),
    },
    preview = function(self, cb)
      cb(text {
        line { span('Profile: ', 'darkgray'), span(self.profile, 'cyan') },
        line { span('Host: ', 'darkgray'), span(profile.host, 'white') },
        line { span('User: ', 'darkgray'), span(profile.user ~= '' and profile.user or '(default)', 'white') },
        line { span('Base Dir: ', 'darkgray'), span(profile.base_dir, 'yellow') },
        line { span('Port: ', 'darkgray'), span(profile.port and tostring(profile.port) or '(default)', 'white') },
      })
    end,
  }
end

local function browser_options()
  return {
    preview_max_chars = runtime.cfg.preview_max_chars,
    show_hidden = runtime.cfg.show_hidden,
    preview_debounce_ms = runtime.cfg.preview_debounce_ms,
    preview_mode = runtime.cfg.preview_mode,
    keymap = runtime.cfg.keymap,
  }
end

local function get_browser(profile_name)
  if runtime.browsers[profile_name] then return runtime.browsers[profile_name] end

  local profile = runtime.cfg.profiles[profile_name]
  if not profile then return nil end

  runtime.browsers[profile_name] = file.new(Provider.new(profile), browser_options())
  return runtime.browsers[profile_name]
end

local function root_entries()
  local names = profile_names()
  if #names == 0 then
    return {
      info_entry('empty', 'No sftp profiles configured', 'yellow'),
      info_entry('hint', 'Configure require("sftp").setup { profiles = { ... } }'),
    }
  end

  local entries = {}
  for _, name in ipairs(names) do
    table.insert(entries, profile_entry(runtime.cfg.profiles[name]))
  end
  return entries
end

function M.setup(opt)
  runtime.cfg = config.new(opt or {})
  for _, browser in pairs(runtime.browsers) do
    if browser and browser.provider and browser.provider.close then
      browser.provider:close()
    end
  end
  runtime.browsers = {}

  if not deck.system.executable 'ssh' then
    deck.notify 'ssh command not found'
    deck.log('warn', 'ssh command not found')
  end
  deck.plugin.load("file")
  deck.hook.pre_quit(function()
    for _, browser in pairs(runtime.browsers) do
      if browser and browser.provider and browser.provider.close then
        browser.provider:close()
      end
    end
  end)
end

function M.list(path, cb)
  if #path <= 1 then
    cb(root_entries())
    return
  end

  local profile_name = path[2]
  if not runtime.cfg.profiles[profile_name] then
    cb {
      info_entry('missing-profile', 'Unknown sftp profile: ' .. tostring(profile_name), 'red'),
    }
    return
  end

  local expected_path = deck.api.get_current_path() or {}
  local browser = get_browser(profile_name)
  browser:list(path, function(entries)
    if deck.deep_equal(expected_path, deck.api.get_current_path() or {}) then
      cb(entries)
    end
  end)
end

return M
