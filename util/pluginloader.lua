-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
-- luacheck: ignore 113/CFG_PLUGINDIR

local dir_sep, path_sep = package.config:match("^(%S+)%s(%S+)");
local lua_version = _VERSION:match(" (.+)$");
local plugin_dir = {};
for path in (CFG_PLUGINDIR or "./plugins/"):gsub("[/\\]", dir_sep):gmatch("[^"..path_sep.."]+") do
	path = path..dir_sep; -- add path separator to path end
	path = path:gsub(dir_sep..dir_sep.."+", dir_sep); -- coalesce multiple separaters
	plugin_dir[#plugin_dir + 1] = path;
end

local io_open = io.open;
local envload = require "util.envload".envload;

local function load_file(names)
	local file, err, path;
	for i=1,#plugin_dir do
		for j=1,#names do
			path = plugin_dir[i]..names[j];
			file, err = io_open(path);
			if file then
				local content = file:read("*a");
				file:close();
				return content, path;
			end
		end
	end
	return file, err;
end

local function load_resource(plugin, resource)
	resource = resource or "mod_"..plugin..".lua";
	local names = {
		"mod_"..plugin..dir_sep..plugin..dir_sep..resource; -- mod_hello/hello/mod_hello.lua
		"mod_"..plugin..dir_sep..resource;                  -- mod_hello/mod_hello.lua
		plugin..dir_sep..resource;                          -- hello/mod_hello.lua
		resource;                                           -- mod_hello.lua
		"share"..dir_sep.."lua"..dir_sep..lua_version..dir_sep..resource;
		"share"..dir_sep.."lua"..dir_sep..lua_version..dir_sep.."mod_"..plugin..dir_sep..resource;
	};

	return load_file(names);
end

local function load_code(plugin, resource, env)
	local content, err = load_resource(plugin, resource);
	if not content then return content, err; end
	local path = err;
	local f, err = envload(content, "@"..path, env);
	if not f then return f, err; end
	return f, path;
end

local function load_code_ext(plugin, resource, extension, env)
	local content, err = load_resource(plugin, resource.."."..extension);
	if not content and extension == "lib.lua" then
		content, err = load_resource(plugin, resource..".lua");
	end
	if not content then
		content, err = load_resource(resource, resource.."."..extension);
		if not content then
			return content, err;
		end
	end
	local path = err;
	local f, err = envload(content, "@"..path, env);
	if not f then return f, err; end
	return f, path;
end

return {
	load_file = load_file;
	load_resource = load_resource;
	load_code = load_code;
	load_code_ext = load_code_ext;
};
