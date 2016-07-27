#!/usr/bin/env lua

local optarg = require 'optarg'
local unix = require 'unix'

local is_dir = unix.S_ISDIR
local lchown = unix.lchown
local lstat = unix.lstat
local opendir = unix.opendir
local exit = os.exit
local max = math.max
local min = math.min


local version = '0.1.0'

local help_opts = [[
Options:
  -b, --both     Convert both UIDs and GIDs
  -g, --gid      Convert GIDs (groups)
  -u, --uid      Convert UIDs (owners)
  -r, --range    Find min/max UID and GID used in the directory tree
  -v, --verbose  Be verbose
  -V, --version  Show version information and exit
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
    local dirh, err = opendir(dir)
    if err then
      printf_err("%s: %s", err, dir)
      return
    end

    for entry in dirh:files('name') do
      if entry ~= '..' and (entry ~= '.' or dir == dir_path) then
        local path = dir..'/'..entry
        local stat = assert(lstat(path))

        coroutine.yield(path, stat)

        if is_dir(stat.mode) then
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
    local _, err = lchown(path, new_uid, new_gid)

    if err then
      printf_err("%s: chown -h %d:%d %s", err, new_uid, new_gid, path)
    elseif opts.verbose then
      printf("chown -h %d:%d %s  # was %d:%d", new_uid, new_gid, path, uid, gid)
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
    show_version = opts.version,
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
  exit(1)
end

if opts.show_help then
  print_help()
  exit(0)

elseif opts.show_version then
  printf("uidmapshift %s", version)
  exit(0)
end

local min_uid, max_uid, min_gid, max_gid = 0, 0, 0, 0

for path, stat in walk_directory(opts.path) do
  local old_uid, old_gid = stat.uid, stat.gid

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

if opts.show_range then
  printf("UIDs %d - %d\nGIDs %d - %d", min_uid, max_uid, min_gid, max_gid)
end
