-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local _G = _G;
local setmetatable, rawget, rawset, io, os, error, dofile, type, pairs, ipairs =
      setmetatable, rawget, rawset, io, os, error, dofile, type, pairs, ipairs;
local format, math_max, t_insert = string.format, math.max, table.insert;

local envload = require"util.envload".envload;
local deps = require"util.dependencies";
local resolve_relative_path = require"util.paths".resolve_relative_path;
local glob_to_pattern = require"util.paths".glob_to_pattern;
local path_sep = package.config:sub(1,1);
local get_traceback_table = require "util.debug".get_traceback_table;

local encodings = deps.softreq"util.encodings";
local nameprep = encodings and encodings.stringprep.nameprep or function (host) return host:lower(); end

local _M = {};
local _ENV = nil;
-- luacheck: std none

_M.resolve_relative_path = resolve_relative_path; -- COMPAT

local parser = nil;

local config_mt = { __index = function (t, _) return rawget(t, "*"); end};
local config = setmetatable({ ["*"] = { } }, config_mt);
local files = {};

-- When host not found, use global
local host_mt = { __index = function(_, k) return config["*"][k] end }

function _M.getconfig()
	return config;
end

function _M.get(host, key)
	return config[host][key];
end
function _M.rawget(host, key)
	local hostconfig = rawget(config, host);
	if hostconfig then
		return rawget(hostconfig, key);
	end
end

local function set(config_table, host, key, value)
	if host and key then
		local hostconfig = rawget(config_table, host);
		if not hostconfig then
			hostconfig = rawset(config_table, host, setmetatable({}, host_mt))[host];
		end
		hostconfig[key] = value;
		return true;
	end
	return false;
end

function _M.set(host, key, value)
	return set(config, host, key, value);
end

function _M.load(filename, config_format)
	config_format = config_format or filename:match("%w+$");

	if config_format == "lua" then
		local f, err = io.open(filename);
		if f then
			local new_config = setmetatable({ ["*"] = { } }, config_mt);
			local ok, err = parser.load(f:read("*a"), filename, new_config);
			f:close();
			if ok then
				config = new_config;
			end
			return ok, "parser", err;
		end
		return f, "file", err;
	end

	if not config_format then
		return nil, "file", "no parser specified";
	else
		return nil, "file", "no parser for "..(config_format);
	end
end

function _M.files()
	return files;
end

-- Built-in Lua parser
do
	local pcall = _G.pcall;
	local function get_line_number(config_file)
		local tb = get_traceback_table(nil, 2);
		for i = 1, #tb do
			if tb[i].info.short_src == config_file then
				return tb[i].info.currentline;
			end
		end
	end
	parser = {};
	function parser.load(data, config_file, config_table)
		local set_options = {}; -- set_options[host.."/"..option_name] = true (when the option has been set already in this file)
		local warnings = {};
		local env;
		-- The ' = true' are needed so as not to set off __newindex when we assign the functions below
		env = setmetatable({
			Host = true, host = true, VirtualHost = true,
			Component = true, component = true,
			Include = true, include = true, RunScript = true }, {
				__index = function (_, k)
					if k:match("^ENV_") then
						return os.getenv(k:sub(5));
					end
					return rawget(_G, k);
				end,
				__newindex = function (_, k, v)
					local host = env.__currenthost or "*";
					local option_path = host.."/"..k;
					if set_options[option_path] then
						t_insert(warnings, ("%s:%d: Duplicate option '%s'"):format(config_file, get_line_number(config_file), k));
					end
					set_options[option_path] = true;
					set(config_table, env.__currenthost or "*", k, v);
				end
		});

		rawset(env, "__currenthost", "*") -- Default is global
		function env.VirtualHost(name)
			if not name then
				error("Host must have a name", 2);
			end
			local prepped_name = nameprep(name);
			if not prepped_name then
				error(format("Name of Host %q contains forbidden characters", name), 0);
			end
			name = prepped_name;
			if rawget(config_table, name) and rawget(config_table[name], "component_module") then
				error(format("Host %q clashes with previously defined %s Component %q, for services use a sub-domain like conference.%s",
					name, config_table[name].component_module:gsub("^%a+$", { component = "external", muc = "MUC"}), name, name), 0);
			end
			rawset(env, "__currenthost", name);
			-- Needs at least one setting to logically exist :)
			set(config_table, name or "*", "defined", true);
			return function (config_options)
				rawset(env, "__currenthost", "*"); -- Return to global scope
				if type(config_options) == "string" then
					error(format("VirtualHost entries do not accept a module name (module '%s' provided for host '%s')", config_options, name), 2);
				elseif type(config_options) ~= "table" then
					error("Invalid syntax following VirtualHost, expected options but received a "..type(config_options), 2);
				end
				for option_name, option_value in pairs(config_options) do
					set(config_table, name or "*", option_name, option_value);
				end
			end;
		end
		env.Host, env.host = env.VirtualHost, env.VirtualHost;

		function env.Component(name)
			if not name then
				error("Component must have a name", 2);
			end
			local prepped_name = nameprep(name);
			if not prepped_name then
				error(format("Name of Component %q contains forbidden characters", name), 0);
			end
			name = prepped_name;
			if rawget(config_table, name) and rawget(config_table[name], "defined")
				and not rawget(config_table[name], "component_module") then
				error(format("Component %q clashes with previously defined VirtualHost %q, for services use a sub-domain like conference.%s",
					name, name, name), 0);
			end
			set(config_table, name, "component_module", "component");
			-- Don't load the global modules by default
			set(config_table, name, "load_global_modules", false);
			rawset(env, "__currenthost", name);
			local function handle_config_options(config_options)
				rawset(env, "__currenthost", "*"); -- Return to global scope
				for option_name, option_value in pairs(config_options) do
					set(config_table, name or "*", option_name, option_value);
				end
			end

			return function (module)
					if type(module) == "string" then
						set(config_table, name, "component_module", module);
						return handle_config_options;
					end
					return handle_config_options(module);
				end
		end
		env.component = env.Component;

		function env.Include(file)
			-- Check whether this is a wildcard Include
			if file:match("[*?]") then
				local lfs = deps.softreq "lfs";
				if not lfs then
					error(format("Error expanding wildcard pattern in Include %q - LuaFileSystem not available", file));
				end
				local path_pos, glob = file:match("()([^"..path_sep.."]+)$");
				local path = file:sub(1, math_max(path_pos-2,0));
				local config_path = config_file:gsub("[^"..path_sep.."]+$", "");
				if #path > 0 then
					path = resolve_relative_path(config_path, path);
				else
					path = config_path;
				end
				local patt = glob_to_pattern(glob);
				for f in lfs.dir(path) do
					if f:sub(1,1) ~= "." and f:match(patt) then
						env.Include(path..path_sep..f);
					end
				end
				return;
			end
			-- Not a wildcard, so resolve (potentially) relative path and run through config parser
			file = resolve_relative_path(config_file:gsub("[^"..path_sep.."]+$", ""), file);
			local f, err = io.open(file);
			if f then
				local ret, err = parser.load(f:read("*a"), file, config_table);
				if not ret then error(err:gsub("%[string.-%]", file), 0); end
				if err then
					for _, warning in ipairs(err) do
						t_insert(warnings, warning);
					end
				end
			end
			if not f then error("Error loading included "..file..": "..err, 0); end
			return f, err;
		end
		env.include = env.Include;

		function env.RunScript(file)
			return dofile(resolve_relative_path(config_file:gsub("[^"..path_sep.."]+$", ""), file));
		end

		local chunk, err = envload(data, "@"..config_file, env);

		if not chunk then
			return nil, err;
		end

		local ok, err = pcall(chunk);

		if not ok then
			return nil, err;
		end

		t_insert(files, config_file);

		return true, warnings;
	end

end

return _M;
