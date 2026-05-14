local M = {}

local defaults = {
  profiles = {},
  preview_debounce_ms = 220,
  preview_mode = 'full',
}

local function normalize_profile(name, profile)
  local out = deck.tbl_extend('force', {}, profile or {})
  out.name = name
  out.host = tostring(out.host or '')
  out.user = tostring(out.user or '')
  out.base_dir = tostring(out.base_dir or '/')
  out.port = tonumber(out.port)
  out.ssh_opts = out.ssh_opts or {}
  if out.base_dir == '' then out.base_dir = '/' end
  return out
end

function M.new(opt)
  local cfg = deck.tbl_deep_extend('force', defaults, opt or {})
  local profiles = {}
  for name, profile in pairs(cfg.profiles or {}) do
    profiles[name] = normalize_profile(name, profile)
  end
  cfg.profiles = profiles
  return cfg
end

return M
