local M = {}

local function basename(path)
  local value = tostring(path or '')
  if value == '' or value == '/' then return '/' end
  return value:match '([^/]+)$' or value
end

local function join_path(dir, name)
  local base = tostring(dir or '/')
  local child = tostring(name or '')
  if base == '' then base = '/' end
  if base == '/' then return '/' .. child end
  return base .. '/' .. child
end

local function dirname_rel(path)
  local value = tostring(path or '')
  if value == '' then return '' end
  local dir = value:match '^(.*)/[^/]+$'
  return dir or ''
end

local function split_rel(path)
  local out = {}
  local value = tostring(path or '')
  for segment in value:gmatch '[^/]+' do
    table.insert(out, segment)
  end
  return out
end

local function trim(value)
  return tostring(value or ''):match '^%s*(.-)%s*$'
end

local function tempfile_for_handle(handle, prefix)
  local suffix = tostring(handle.name or ''):match '(%.[^./]+)$'
  local path, err = lc.fs.tempfile({
    prefix = prefix,
    suffix = suffix,
  })
  return path, err
end

local function build_target(profile)
  if profile.user ~= '' then return profile.user .. '@' .. profile.host end
  return profile.host
end

local function handle_error(out, fallback)
  local err = trim(out and out.stderr or '')
  if err == '' then err = trim(out and out.stdout or '') end
  if err == '' then err = fallback or 'remote command failed' end
  return err
end

local function new_control_path(profile)
  local path, err = lc.fs.tempfile({
    prefix = 'lazycmd-sftp-' .. tostring(profile.name) .. '-',
    suffix = '.sock',
  })
  if err then return nil, err end
  lc.fs.remove(path)
  return path
end

local function ssh_base_cmd(profile, state)
  local cmd = { 'ssh' }
  for _, opt in ipairs(profile.ssh_opts or {}) do
    table.insert(cmd, tostring(opt))
  end
  if profile.port then
    table.insert(cmd, '-p')
    table.insert(cmd, tostring(profile.port))
  end
  if state and state.control_path then
    table.insert(cmd, '-S')
    table.insert(cmd, state.control_path)
  end
  return cmd
end

local function scp_base_cmd(profile, state)
  local cmd = { 'scp' }
  for _, opt in ipairs(profile.ssh_opts or {}) do
    table.insert(cmd, '-o')
    table.insert(cmd, tostring(opt))
  end
  if profile.port then
    table.insert(cmd, '-P')
    table.insert(cmd, tostring(profile.port))
  end
  if state and state.control_path then
    table.insert(cmd, '-o')
    table.insert(cmd, 'ControlPath=' .. tostring(state.control_path))
  end
  return cmd
end

local function run_ssh(profile, state, extra_args, opts, cb)
  local cmd = ssh_base_cmd(profile, state)
  for _, arg in ipairs(extra_args or {}) do
    table.insert(cmd, arg)
  end
  table.insert(cmd, build_target(profile))
  lc.system(cmd, opts or {}, function(out)
    if out.code == 0 then
      cb(out, nil)
      return
    end
    cb(nil, handle_error(out, table.concat(cmd, ' ') .. ' failed'))
  end)
end

function M.new(profile)
  local self = {
    name = 'sftp',
    route_name = 'sftp',
    profile = profile,
    base_dir = profile.base_dir or '/',
    state = {
      control_path = nil,
      ready = false,
      connecting = false,
      waiters = {},
    },
  }
  return setmetatable(self, { __index = M })
end

function M:handle(path, is_dir, rel_path)
  local remote_path = tostring(path or self.base_dir)
  local rel = rel_path
  if rel == nil then
    if remote_path == self.base_dir then
      rel = ''
    elseif self.base_dir == '/' then
      rel = remote_path:gsub('^/', '')
    else
      rel = remote_path:gsub('^' .. self.base_dir .. '/?', '')
    end
  end

  return {
    id = self.profile.name .. ':' .. remote_path,
    name = basename(remote_path),
    path = remote_path,
    rel_path = rel,
    is_dir = is_dir == true,
    profile = self.profile.name,
  }
end

function M:root()
  return self:handle(self.base_dir, true, '')
end

function M:decode_page_path(path)
  if type(path) ~= 'table' or path[1] ~= self.route_name or path[2] ~= self.profile.name then
    return nil, 'Invalid page path for sftp profile ' .. tostring(self.profile.name)
  end

  local rel = ''
  if #path > 2 then
    rel = table.concat({ table.unpack(path, 3) }, '/')
  end
  if rel == '' then return self:root() end
  return self:handle(join_path(self.base_dir, rel), true, rel)
end

function M:encode_page_path(handle)
  local out = { self.route_name, self.profile.name }
  for _, segment in ipairs(split_rel(handle.rel_path or '')) do
    table.insert(out, segment)
  end
  return out
end

function M:parent(handle)
  local rel = tostring(handle.rel_path or '')
  if rel == '' then return nil end
  local parent_rel = dirname_rel(rel)
  if parent_rel == '' then return self:root() end
  return self:handle(join_path(self.base_dir, parent_rel), true, parent_rel)
end

function M:join(dir_handle, name)
  local rel = trim(dir_handle.rel_path or '')
  local next_rel = rel == '' and tostring(name) or (rel .. '/' .. tostring(name))
  return self:handle(join_path(dir_handle.path, name), false, next_rel)
end

function M:flush_waiters(ok, err)
  local waiters = self.state.waiters
  self.state.waiters = {}
  for _, waiter in ipairs(waiters) do
    waiter(ok, err)
  end
end

function M:ensure_connection(cb)
  if self.profile.host == '' then
    cb(false, 'Missing host for sftp profile: ' .. tostring(self.profile.name))
    return
  end

  if self.state.ready and self.state.control_path then
    run_ssh(self.profile, self.state, { '-O', 'check' }, nil, function(_, err)
      if err == nil then
        cb(true)
        return
      end

      self.state.ready = false
      self:ensure_connection(cb)
    end)
    return
  end

  if self.state.connecting then
    table.insert(self.state.waiters, cb)
    return
  end

  local control_path, err = new_control_path(self.profile)
  if not control_path then
    cb(false, err)
    return
  end

  self.state.control_path = control_path
  self.state.connecting = true
  table.insert(self.state.waiters, cb)

  local cmd = ssh_base_cmd(self.profile, self.state)
  table.insert(cmd, '-o')
  table.insert(cmd, 'ControlMaster=yes')
  table.insert(cmd, '-o')
  table.insert(cmd, 'ControlPersist=yes')
  table.insert(cmd, '-fnNT')
  table.insert(cmd, build_target(self.profile))

  lc.system(cmd, function(out)
    self.state.connecting = false
    if out.code == 0 then
      self.state.ready = true
      self:flush_waiters(true)
      return
    end

    local connect_err = handle_error(out, 'failed to establish ssh control master')
    if self.state.control_path then
      lc.fs.remove(self.state.control_path)
    end
    self.state.control_path = nil
    self.state.ready = false
    self:flush_waiters(false, connect_err)
  end)
end

function M:exec_remote(script, args, cb)
  self:ensure_connection(function(ok, err)
    if not ok then
      cb(nil, err)
      return
    end

    local cmd = ssh_base_cmd(self.profile, self.state)
    table.insert(cmd, build_target(self.profile))
    table.insert(cmd, 'sh')
    table.insert(cmd, '-s')
    table.insert(cmd, '--')
    for _, arg in ipairs(args or {}) do
      table.insert(cmd, tostring(arg))
    end

    lc.system(cmd, { stdin = script }, function(out)
      if out.code == 0 then
        cb(out, nil)
        return
      end
      cb(nil, handle_error(out, table.concat(cmd, ' ') .. ' failed'))
    end)
  end)
end

function M:close(cb)
  if not self.state.control_path then
    if cb then cb(true) end
    return
  end

  local control_path = self.state.control_path
  run_ssh(self.profile, self.state, { '-O', 'exit' }, nil, function(_, _)
    lc.fs.remove(control_path)
    self.state.control_path = nil
    self.state.ready = false
    self.state.connecting = false
    self.state.waiters = {}
    if cb then cb(true) end
  end)
end

function M:list(dir_handle, cb)
  local list_path = dir_handle.path
  if list_path ~= '/' then list_path = list_path .. '/' end
  self:exec_remote(
    [[
      path=$1
      ls -1 -A -F -- "$path" | while IFS= read -r entry; do
        if [ -z "$entry" ]; then
          continue
        fi
        case "$entry" in
          *@)
            name=${entry%?}
            if [ -d "$path/$name" ]; then
              printf '%s/\n' "$name"
            else
              printf '%s\n' "$entry"
            fi
            ;;
          *)
            printf '%s\n' "$entry"
            ;;
        esac
      done
    ]],
    { list_path },
    function(out, err)
      if err then
        cb(nil, err)
        return
      end

      local entries = {}
      local stdout = trim(out.stdout)
      if stdout == '' then
        cb(entries)
        return
      end

      for _, raw_line in ipairs(stdout:split '\n') do
        local value = trim(raw_line)
        if value ~= '' then
          local rel = trim(dir_handle.rel_path or '')
          local is_dir = value:sub(-1) == '/'
          local name = value
          if is_dir or value:sub(-1) == '*' or value:sub(-1) == '@' or value:sub(-1) == '|' then
            name = value:sub(1, -2)
          end
          if name ~= '' then
            local child_rel = rel == '' and name or (rel .. '/' .. name)
            table.insert(entries, self:handle(join_path(dir_handle.path, name), is_dir, child_rel))
          end
        end
      end

      cb(entries)
    end
  )
end

function M:stat(handle, cb)
  self:exec_remote(
    [[
      path=$1
      if [ -d "$path" ]; then
        printf "dir\n"
      elif [ -f "$path" ]; then
        printf "file\n"
      elif [ -e "$path" ]; then
        printf "other\n"
      else
        printf "missing\n"
      fi
    ]],
    { handle.path },
    function(out, err)
      if err then
        cb({ exists = false, is_dir = false, is_file = false }, err)
        return
      end

      local kind = trim(out.stdout)
      cb({
        exists = kind ~= 'missing',
        is_dir = kind == 'dir',
        is_file = kind == 'file',
      })
    end
  )
end

function M:read_file(handle, opts, cb)
  local max_chars = tonumber((opts or {}).max_chars) or 3000
  self:exec_remote(
    [[
      max=$1
      path=$2
      if [ ! -f "$path" ]; then
        printf "Not a regular file\n" >&2
        exit 1
      fi
      head -c "$max" -- "$path"
    ]],
    { tostring(max_chars), handle.path },
    function(out, err)
      if err then
        cb('', err)
        return
      end
      local content = tostring(out.stdout or '')
      cb(content, nil, { truncated = #content >= max_chars })
    end
  )
end

function M:edit(handle)
  local tmp, err = tempfile_for_handle(handle, 'lazycmd-sftp-edit-')
  if not tmp then
    lc.notify('Failed to create tempfile: ' .. tostring(err))
    return
  end

  self:ensure_connection(function(ok, connect_err)
    if not ok then
      lc.fs.remove(tmp)
      lc.notify('SFTP connection failed: ' .. tostring(connect_err))
      return
    end

    local target = build_target(self.profile)
    local cmd = {
      'sh',
      '-c',
      [[
        set -e
        target=$1
        remote=$2
        tmp=$3
        shift 3
        "$@" "$target:$remote" "$tmp"
        "${VISUAL:-${EDITOR:-vi}}" "$tmp"
        "$@" "$tmp" "$target:$remote"
      ]],
      'sh',
      target,
      handle.path,
      tmp,
    }
    for _, arg in ipairs(scp_base_cmd(self.profile, self.state)) do
      table.insert(cmd, arg)
    end

    lc.interactive({
      table.unpack(cmd),
    }, {
      wait_confirm = function(code) return code ~= 0 end,
    }, function(exit_code)
      lc.fs.remove(tmp)
      if exit_code ~= 0 then return end
      lc.notify('Edited ' .. tostring(handle.path))
      if lc.deep_equal(self:encode_page_path(handle), lc.api.get_hovered_path() or {}) then
        lc.cmd 'scroll_by 0'
      end
    end)
  end)
end

function M:create_file(dir_handle, name, cb)
  local target = self:join(dir_handle, name)
  self:exec_remote(
    [[
      path=$1
      if [ -e "$path" ]; then
        printf "Target already exists: %s\n" "$path" >&2
        exit 1
      fi
      : > "$path"
    ]],
    { target.path },
    function(_, err)
      cb(err == nil, err)
    end
  )
end

function M:create_dir(dir_handle, name, cb)
  local target = self:join(dir_handle, name)
  target.is_dir = true
  self:exec_remote(
    [[
      path=$1
      if [ -e "$path" ]; then
        printf "Target already exists: %s\n" "$path" >&2
        exit 1
      fi
      mkdir "$path"
    ]],
    { target.path },
    function(_, err)
      cb(err == nil, err)
    end
  )
end

function M:remove(handles, cb)
  local paths = {}
  for _, handle in ipairs(handles or {}) do
    table.insert(paths, handle.path)
  end

  self:exec_remote(
    [[
      if [ "$#" -eq 0 ]; then
        exit 0
      fi
      rm -rf -- "$@"
    ]],
    paths,
    function(_, err)
      cb(err == nil, err)
    end
  )
end

local function transfer(self, op, handles, target_dir, cb)
  local args = { target_dir.path }
  for _, handle in ipairs(handles or {}) do
    table.insert(args, handle.path)
  end

  local script = op == 'move'
      and [[
        target=$1
        shift
        mv -- "$@" "$target"
      ]]
    or [[
        target=$1
        shift
        cp -R -- "$@" "$target"
      ]]

  self:exec_remote(script, args, function(_, err)
    if err then
      cb(false, err)
      return
    end

    local targets = {}
    for _, handle in ipairs(handles or {}) do
      local target = self:join(target_dir, handle.name)
      target.is_dir = handle.is_dir
      table.insert(targets, target)
    end
    cb(true, nil, { targets = targets })
  end)
end

function M:copy(handles, target_dir, cb)
  transfer(self, 'copy', handles, target_dir, cb)
end

function M:move(handles, target_dir, cb)
  transfer(self, 'move', handles, target_dir, cb)
end

function M:rename(handle, name, cb)
  if tostring(handle.rel_path or '') == '' then
    cb(false, 'Cannot rename root directory')
    return
  end

  local parent = self:parent(handle)
  if not parent then
    cb(false, 'Failed to resolve parent directory')
    return
  end

  local target = self:join(parent, name)
  self:exec_remote(
    [[
      src=$1
      dst=$2
      if [ -e "$dst" ]; then
        printf "Target already exists: %s\n" "$dst" >&2
        exit 1
      fi
      mv -- "$src" "$dst"
    ]],
    { handle.path, target.path },
    function(_, err)
      if err then
        cb(false, err)
        return
      end
      target.is_dir = handle.is_dir
      cb(true, nil, { target = target })
    end
  )
end

return M
