#!/usr/bin/env lua

local dirent = require 'posix.dirent'
local optarg = require 'optarg'
local posix = require 'posix'
local sys_stat = require 'posix.sys.stat'
local unistd = require 'posix.unistd'

local chown = unistd.chown
local is_dir = sys_stat.S_ISDIR
local is_link = sys_stat.S_ISLNK
local listdir = dirent.files
local lstat = sys_stat.lstat
local max = math.max
local min = math.min


local help_opts = [[
Options:
  -b, --both     Convert both UIDs and GIDs
  -g, --gid      Convert GIDs (groups)
  -u, --uid      Convert UIDs (owners)
  -r, --range    Find min/max UID and GID used in the directory tree
  -v, --verbose  Be verbose
  -h, --help     Show this help and exit
]]

local help_msg = [[
Usage:
  ${progname} (-u | -g | -b) [-r] [-v] <path> <src> <dst> [<count>]
  ${progname} [-r] [-v] <path>
  ${progname} -h

Shifts UIDs/GIDs of the directory entries (recursively) within the range
<src..(src + count)> to <dst..(dst + count)> or finds lowest and highest
UID/GID in the directory tree. Default value of <count> is 65536.

${options}
Examples:
  ${progname} -r /path/to/directory               # show min/max UID/GID
  ${progname} -b /path/to/directory 0 100000 500  # map UIDs and GIDs up
  ${progname} -u /path/to/directory 100000 0 500  # map the UIDs back down
]]


local function printf (str, ...)
  print(str:format(...))
end

local function printf_err (str, ...)
  io.stderr:write((str..'\n'):format(...))
end

local function walk_directory (dir_path)
  assert(dir_path and dir_path ~= '', 'dir_path parameter is missing or empty')

  -- Trim trailing "/".
  if dir_path:sub(-1) == '/' then
    dir_path = dir_path:sub(1, -2)
  end

  local function yieldtree (dir)
    local ok, res = pcall(listdir, dir)
    if not ok then
      printf_err(res:gsub("bad argument #1 to '%?' %((.*)%)", '%1'))
      return
    end

    for entry in res do
      if entry ~= '.' and entry ~= '..' then
        local path = dir..'/'..entry
        local stat = assert(lstat(path))

        coroutine.yield(path, stat)

        if is_dir(stat.st_mode) ~= 0 then
          yieldtree(path)  -- recursive call
        end
      end
    end
  end

  return coroutine.wrap(function() yieldtree(dir_path) end)
end

local function shift_owner (opts, path, uid, gid)
  assert(path and path ~= '', 'path parameter is missing or empty')

  local map_id = function (old_id)
    if old_id >= opts.first and old_id < opts.last then
      return old_id + opts.offset
    end
    return -1
  end

  local new_uid = opts.convert_uids and map_id(uid) or -1
  local new_gid = opts.convert_gids and map_id(gid) or -1

  if new_uid ~= -1 or new_gid ~= -1 then
    local _, err = chown(path, new_uid, new_gid)

    if err then
      printf_err("failed to chown %d:%d %s", new_uid, new_gid, path)
    elseif opts.verbose then
      printf("chown %d:%d %s  # was %d:%d", new_uid, new_gid, path, uid, gid)
    end
  end
end

local function print_help ()
  local msg, _ = help_msg
      :gsub('${progname}', _G.arg[0])
      :gsub('${options}', help_opts)
  print(msg)
end

local function parse_opts ()
  local opts, args = optarg.from_opthelp(help_opts)

  if not opts then
    return nil
  end

  if #args < 1 and opts.show_range then
    return nil
  end

  if #args < 3 and (opts.uid or opts.gid or opts.both) then
    return nil
  end

  local src = tonumber(args[2]) or 0
  local dst = tonumber(args[3]) or 0
  local count = tonumber(args[4]) or 65536

  return {
    convert_uids = opts.uid or opts.both,
    convert_gids = opts.gid or opts.both,
    show_range = opts.range,
    show_help = opts.help,
    verbose = opts.verbose,
    path = args[1],
    first = src,
    last = src + count,
    offset = -src + dst,
  }
end


---------  M a i n  ---------

local opts = parse_opts()

if not opts then
  print('')
  print_help()
  os.exit(1)
end

if opts.show_help then
  print_help()
  os.exit(0)
end

local min_uid, max_uid, min_gid, max_gid = 0, 0, 0, 0

for path, stat in walk_directory(opts.path) do
  if is_link(stat.st_mode) == 0 then  -- not link
    local old_uid, old_gid = stat.st_uid, stat.st_gid

    if opts.show_range then
      min_uid = min(min_uid, old_uid)
      max_uid = max(max_uid, old_uid)
      min_gid = min(min_gid, old_gid)
      max_gid = max(max_gid, old_gid)
    end

    if opts.convert_uids or opts.convert_gids then
      shift_owner(opts, path, old_uid, old_gid)
    end
  end
end

if opts.show_range then
  printf("UIDs %d - %d\nGIDs %d - %d", min_uid, max_uid, min_gid, max_gid)
end