local t_unpack = table.unpack or unpack; -- luacheck: ignore 113
local time_now = os.time;

local jid_prep = require "util.jid".prep;
local set = require "util.set";
local st = require "util.stanza";
local it = require "util.iterators";
local uuid_generate = require "util.uuid".generate;
local dataform = require"util.dataforms".new;

local xmlns_pubsub = "http://jabber.org/protocol/pubsub";
local xmlns_pubsub_errors = "http://jabber.org/protocol/pubsub#errors";
local xmlns_pubsub_owner = "http://jabber.org/protocol/pubsub#owner";

local _M = {};

local handlers = {};
_M.handlers = handlers;

local pubsub_errors = {
	["conflict"] = { "cancel", "conflict" };
	["invalid-jid"] = { "modify", "bad-request", nil, "invalid-jid" };
	["jid-required"] = { "modify", "bad-request", nil, "jid-required" };
	["nodeid-required"] = { "modify", "bad-request", nil, "nodeid-required" };
	["item-not-found"] = { "cancel", "item-not-found" };
	["not-subscribed"] = { "modify", "unexpected-request", nil, "not-subscribed" };
	["invalid-options"] = { "modify", "bad-request", nil, "invalid-options" };
	["forbidden"] = { "auth", "forbidden" };
	["not-allowed"] = { "cancel", "not-allowed" };
	["not-acceptable"] = { "modify", "not-acceptable" };
	["internal-server-error"] = { "wait", "internal-server-error" };
	["precondition-not-met"] = { "cancel", "conflict", nil, "precondition-not-met" };
};
local function pubsub_error_reply(stanza, error)
	local e = pubsub_errors[error];
	local reply = st.error_reply(stanza, t_unpack(e, 1, 3));
	if e[4] then
		reply:tag(e[4], { xmlns = xmlns_pubsub_errors }):up();
	end
	return reply;
end
_M.pubsub_error_reply = pubsub_error_reply;

-- Note: If any config options are added that are of complex types,
-- (not simply strings/numbers) then the publish-options code will
-- need to be revisited
local node_config_form = dataform {
	{
		type = "hidden";
		name = "FORM_TYPE";
		value = "http://jabber.org/protocol/pubsub#node_config";
	};
	{
		type = "text-single";
		name = "pubsub#title";
		label = "Title";
	};
	{
		type = "text-single";
		name = "pubsub#description";
		label = "Description";
	};
	{
		type = "text-single";
		name = "pubsub#type";
		label = "The type of node data, usually specified by the namespace of the payload (if any)";
	};
	{
		type = "text-single";
		name = "pubsub#max_items";
		label = "Max # of items to persist";
	};
	{
		type = "boolean";
		name = "pubsub#persist_items";
		label = "Persist items to storage";
	};
	{
		type = "list-single";
		name = "pubsub#access_model";
		label = "Specify the subscriber model";
		options = {
			"authorize",
			"open",
			"presence",
			"roster",
			"whitelist",
		};
	};
	{
		type = "list-single";
		name = "pubsub#publish_model";
		label = "Specify the publisher model";
		options = {
			"publishers";
			"subscribers";
			"open";
		};
	};
	{
		type = "list-single";
		name = "pubsub#notification_type";
		label = "Specify the delivery style for notifications";
		options = {
			{ label = "Messages of type normal", value = "normal" },
			{ label = "Messages of type headline", value = "headline", default = true },
		};
	};
};

local subscribe_options_form = dataform {
	{
		type = "hidden";
		name = "FORM_TYPE";
		value = "http://jabber.org/protocol/pubsub#subscribe_options";
	};
	{
		type = "boolean";
		name = "pubsub#include_body";
		label = "Receive message body in addition to payload?";
	};
};

local node_metadata_form = dataform {
	{
		type = "hidden";
		name = "FORM_TYPE";
		value = "http://jabber.org/protocol/pubsub#meta-data";
	};
	{
		type = "text-single";
		name = "pubsub#title";
	};
	{
		type = "text-single";
		name = "pubsub#description";
	};
	{
		type = "text-single";
		name = "pubsub#type";
	};
};

local config_field_map = {
	title = "pubsub#title";
	description = "pubsub#description";
	payload_type = "pubsub#type";
	max_items = "pubsub#max_items";
	persist_items = "pubsub#persist_items";
	notification_type = "pubsub#notification_type";
	access_model = "pubsub#access_model";
	publish_model = "pubsub#publish_model";
};
local reverse_config_field_map = {};
for k, v in pairs(config_field_map) do reverse_config_field_map[v] = k; end

-- util.pubsub is meant to be agnostic to XEP-0060
local function config_to_xep0060(node_config)
	return {
		["pubsub#title"] = node_config["title"];
		["pubsub#description"] = node_config["description"];
		["pubsub#type"] = node_config["payload_type"];
		["pubsub#max_items"] = tostring(node_config["max_items"]);
		["pubsub#persist_items"] = node_config["persist_items"];
		["pubsub#notification_type"] = node_config["notification_type"];
		["pubsub#access_model"] = node_config["access_model"];
		["pubsub#publish_model"] = node_config["publish_model"];
	}
end

local function config_from_xep0060(config, strict)
	local ret = {};
	for config_field, config_value in pairs(config) do
		local mapped_name = reverse_config_field_map[config_field];
		if mapped_name then
			-- FIXME: The intention is to add "subtype" support to
			-- util.dataforms, which will remove the need for this
			-- ugly hack
			if mapped_name == "max_items" then
				config_value = tonumber(config_value);
			end
			ret[mapped_name] = config_value;
		elseif strict and config_field ~= "FORM_TYPE" then
			return nil, "unknown-field", config_field;
		end
	end
	return ret;
end

-- Used to check that the config of a node is as expected (i.e. 'publish-options')
local function check_preconditions(node_config, required_config)
	if not (node_config and required_config) then
		return false;
	end
	for config_field, value in pairs(required_config) do
		if node_config[config_field] ~= value then
			return false;
		end
	end
	return true;
end

local service_method_feature_map = {
	add_subscription = { "subscribe" };
	create = { "create-nodes", "instant-nodes", "item-ids", "create-and-configure" };
	delete = { "delete-nodes" };
	get_items = { "retrieve-items" };
	get_subscriptions = { "retrieve-subscriptions" };
	node_defaults = { "retrieve-default" };
	publish = { "publish", "multi-items", "publish-options" };
	purge = { "purge-nodes" };
	retract = { "delete-items", "retract-items" };
	set_node_config = { "config-node" };
	set_affiliation = { "modify-affiliations" };
};
local service_config_feature_map = {
	autocreate_on_publish = { "auto-create" };
};

function _M.get_feature_set(service)
	local supported_features = set.new();

	for method, features in pairs(service_method_feature_map) do
		if service[method] then
			for _, feature in ipairs(features) do
				if feature then
					supported_features:add(feature);
				end
			end
		end
	end

	for option, features in pairs(service_config_feature_map) do
		if service.config[option] then
			for _, feature in ipairs(features) do
				if feature then
					supported_features:add(feature);
				end
			end
		end
	end

	for affiliation in pairs(service.config.capabilities) do
		if affiliation ~= "none" and affiliation ~= "owner" then
			supported_features:add(affiliation.."-affiliation");
		end
	end

	if service.node_defaults.access_model then
		supported_features:add("access-"..service.node_defaults.access_model);
	end

	if rawget(service.config, "itemstore") and rawget(service.config, "nodestore") then
		supported_features:add("persistent-items");
	end

	return supported_features;
end

function _M.handle_disco_info_node(event, service)
	local stanza, reply, node = event.stanza, event.reply, event.node;
	local ok, ret = service:get_nodes(stanza.attr.from);
	local node_obj = ret[node];
	if not ok or not node_obj then
		return;
	end
	event.exists = true;
	reply:tag("identity", { category = "pubsub", type = "leaf" }):up();
	if node_obj.config then
		reply:add_child(node_metadata_form:form({
			["pubsub#title"] = node_obj.config.title;
			["pubsub#description"] = node_obj.config.description;
			["pubsub#type"] = node_obj.config.payload_type;
		}, "result"));
	end
end

function _M.handle_disco_items_node(event, service)
	local stanza, reply, node = event.stanza, event.reply, event.node;
	local ok, ret = service:get_items(node, stanza.attr.from);
	if not ok then
		return;
	end

	for _, id in ipairs(ret) do
		reply:tag("item", { jid = module.host, name = id }):up();
	end
	event.exists = true;
end

function _M.handle_pubsub_iq(event, service)
	local origin, stanza = event.origin, event.stanza;
	local pubsub_tag = stanza.tags[1];
	local action = pubsub_tag.tags[1];
	if not action then
		return origin.send(st.error_reply(stanza, "cancel", "bad-request"));
	end
	local prefix = "";
	if pubsub_tag.attr.xmlns == xmlns_pubsub_owner then
		prefix = "owner_";
	end
	local handler = handlers[prefix..stanza.attr.type.."_"..action.name];
	if handler then
		handler(origin, stanza, action, service);
		return true;
	end
end

function handlers.get_items(origin, stanza, items, service)
	local node = items.attr.node;
	local item = items:get_child("item");
	local item_id = item and item.attr.id;

	if not node then
		origin.send(pubsub_error_reply(stanza, "nodeid-required"));
		return true;
	end
	local ok, results = service:get_items(node, stanza.attr.from, item_id);
	if not ok then
		origin.send(pubsub_error_reply(stanza, results));
		return true;
	end

	local data = st.stanza("items", { node = node });
	for _, id in ipairs(results) do
		data:add_child(results[id]);
	end
	local reply;
	if data then
		reply = st.reply(stanza)
			:tag("pubsub", { xmlns = xmlns_pubsub })
				:add_child(data);
	else
		reply = pubsub_error_reply(stanza, "item-not-found");
	end
	origin.send(reply);
	return true;
end

function handlers.get_subscriptions(origin, stanza, subscriptions, service)
	local node = subscriptions.attr.node;
	local ok, ret = service:get_subscriptions(node, stanza.attr.from, stanza.attr.from);
	if not ok then
		origin.send(pubsub_error_reply(stanza, ret));
		return true;
	end
	local reply = st.reply(stanza)
		:tag("pubsub", { xmlns = xmlns_pubsub })
			:tag("subscriptions");
	for _, sub in ipairs(ret) do
		reply:tag("subscription", { node = sub.node, jid = sub.jid, subscription = 'subscribed' }):up();
	end
	origin.send(reply);
	return true;
end

function handlers.owner_get_subscriptions(origin, stanza, subscriptions, service)
	local node = subscriptions.attr.node;
	local ok, ret = service:get_subscriptions(node, stanza.attr.from);
	if not ok then
		origin.send(pubsub_error_reply(stanza, ret));
		return true;
	end
	local reply = st.reply(stanza)
		:tag("pubsub", { xmlns = xmlns_pubsub_owner })
			:tag("subscriptions");
	for _, sub in ipairs(ret) do
		reply:tag("subscription", { node = sub.node, jid = sub.jid, subscription = 'subscribed' }):up();
	end
	origin.send(reply);
	return true;
end

function handlers.owner_set_subscriptions(origin, stanza, subscriptions, service)
	local node = subscriptions.attr.node;
	if not node then
		origin.send(pubsub_error_reply(stanza, "nodeid-required"));
		return true;
	end
	if not service:may(node, stanza.attr.from, "subscribe_other") then
		origin.send(pubsub_error_reply(stanza, "forbidden"));
		return true;
	end

	local node_obj = service.nodes[node];
	if not node_obj then
		origin.send(pubsub_error_reply(stanza, "item-not-found"));
		return true;
	end

	for subscription_tag in subscriptions:childtags("subscription") do
		if subscription_tag.attr.subscription == 'subscribed' then
			local ok, err = service:add_subscription(node, stanza.attr.from, subscription_tag.attr.jid);
			if not ok then
				origin.send(pubsub_error_reply(stanza, err));
				return true;
			end
		elseif subscription_tag.attr.subscription == 'none' then
			local ok, err = service:remove_subscription(node, stanza.attr.from, subscription_tag.attr.jid);
			if not ok then
				origin.send(pubsub_error_reply(stanza, err));
				return true;
			end
		end
	end

	local reply = st.reply(stanza);
	origin.send(reply);
	return true;
end

function handlers.set_create(origin, stanza, create, service)
	local node = create.attr.node;
	local ok, ret, reply;
	local config;
	local configure = stanza.tags[1]:get_child("configure");
	if configure then
		local config_form = configure:get_child("x", "jabber:x:data");
		if not config_form then
			origin.send(st.error_reply(stanza, "modify", "bad-request", "Missing dataform"));
			return true;
		end
		local form_data, err = node_config_form:data(config_form);
		if not form_data then
			origin.send(st.error_reply(stanza, "modify", "bad-request", err));
			return true;
		end
		config = config_from_xep0060(form_data);
	end
	if node then
		ok, ret = service:create(node, stanza.attr.from, config);
		if ok then
			reply = st.reply(stanza);
		else
			reply = pubsub_error_reply(stanza, ret);
		end
	else
		repeat
			node = uuid_generate();
			ok, ret = service:create(node, stanza.attr.from, config);
		until ok or ret ~= "conflict";
		if ok then
			reply = st.reply(stanza)
				:tag("pubsub", { xmlns = xmlns_pubsub })
					:tag("create", { node = node });
		else
			reply = pubsub_error_reply(stanza, ret);
		end
	end
	origin.send(reply);
	return true;
end

function handlers.owner_set_delete(origin, stanza, delete, service)
	local node = delete.attr.node;

	local reply;
	if not node then
		origin.send(pubsub_error_reply(stanza, "nodeid-required"));
		return true;
	end
	local ok, ret = service:delete(node, stanza.attr.from);
	if ok then
		reply = st.reply(stanza);
	else
		reply = pubsub_error_reply(stanza, ret);
	end
	origin.send(reply);
	return true;
end

function handlers.set_subscribe(origin, stanza, subscribe, service)
	local node, jid = subscribe.attr.node, subscribe.attr.jid;
	jid = jid_prep(jid);
	if not (node and jid) then
		origin.send(pubsub_error_reply(stanza, jid and "nodeid-required" or "invalid-jid"));
		return true;
	end
	local options_tag, options = stanza.tags[1]:get_child("options"), nil;
	if options_tag then
		options = subscribe_options_form:data(options_tag.tags[1]);
	end
	local ok, ret = service:add_subscription(node, stanza.attr.from, jid, options);
	local reply;
	if ok then
		reply = st.reply(stanza)
			:tag("pubsub", { xmlns = xmlns_pubsub })
				:tag("subscription", {
					node = node,
					jid = jid,
					subscription = "subscribed"
				}):up();
		if options_tag then
			reply:add_child(options_tag);
		end
	else
		reply = pubsub_error_reply(stanza, ret);
	end
	origin.send(reply);
end

function handlers.set_unsubscribe(origin, stanza, unsubscribe, service)
	local node, jid = unsubscribe.attr.node, unsubscribe.attr.jid;
	jid = jid_prep(jid);
	if not (node and jid) then
		origin.send(pubsub_error_reply(stanza, jid and "nodeid-required" or "invalid-jid"));
		return true;
	end
	local ok, ret = service:remove_subscription(node, stanza.attr.from, jid);
	local reply;
	if ok then
		reply = st.reply(stanza);
	else
		reply = pubsub_error_reply(stanza, ret);
	end
	origin.send(reply);
	return true;
end

function handlers.get_options(origin, stanza, options, service)
	local node, jid = options.attr.node, options.attr.jid;
	jid = jid_prep(jid);
	if not (node and jid) then
		origin.send(pubsub_error_reply(stanza, jid and "nodeid-required" or "invalid-jid"));
		return true;
	end
	local ok, ret = service:get_subscription(node, stanza.attr.from, jid);
	if not ok then
		origin.send(pubsub_error_reply(stanza, "not-subscribed"));
		return true;
	end
	if ret == true then ret = {} end
	origin.send(st.reply(stanza)
		:tag("pubsub", { xmlns = xmlns_pubsub })
			:tag("options", { node = node, jid = jid })
				:add_child(subscribe_options_form:form(ret)));
	return true;
end

function handlers.set_options(origin, stanza, options, service)
	local node, jid = options.attr.node, options.attr.jid;
	jid = jid_prep(jid);
	if not (node and jid) then
		origin.send(pubsub_error_reply(stanza, jid and "nodeid-required" or "invalid-jid"));
		return true;
	end
	local ok, ret = service:get_subscription(node, stanza.attr.from, jid);
	if not ok then
		origin.send(pubsub_error_reply(stanza, ret));
		return true;
	elseif not ret then
		origin.send(pubsub_error_reply(stanza, "not-subscribed"));
		return true;
	end
	local new_subopts, err = subscribe_options_form:data(options.tags[1]);
	if not new_subopts then
		origin.send(pubsub_error_reply(stanza, ret));
		return true;
	end
	local ok, err = service:add_subscription(node, stanza.attr.from, jid, new_subopts);
	if not ok then
		origin.send(pubsub_error_reply(stanza, err));
		return true;
	end
	origin.send(st.reply(stanza));
	return true;
end

function handlers.set_publish(origin, stanza, publish, service)
	local node = publish.attr.node;
	if not node then
		origin.send(pubsub_error_reply(stanza, "nodeid-required"));
		return true;
	end
	local publish_options = stanza.tags[1]:get_child("publish-options");
	if publish_options then
		-- Ensure that the node configuration matches the values in publish-options
		local publish_options_form = publish_options:get_child("x", "jabber:x:data");
		local required_config = config_from_xep0060(node_config_form:data(publish_options_form), true);
		local node_accessible, node_config = service:get_node_config(node, stanza.attr.from);
		if node_accessible == false and service.config.autocreate_on_publish then
			module:log("debug", "creating node %s with publish-options", node)
			-- we need to create the node here so that it is configured
			-- correctly
			local created, err = service:create(node, stanza.attr.from, required_config)
			if not created then
				local reply = pubsub_error_reply(stanza, err);
				origin.send(reply);
				return true;
			end
		elseif not check_preconditions(node_config, required_config) then
			local reply = pubsub_error_reply(stanza, "precondition-not-met");
			origin.send(reply);
			return true;
		end
	end
	local item = publish:get_child("item");
	local id = (item and item.attr.id);
	if not id then
		id = uuid_generate();
		if item then
			item.attr.id = id;
		end
	end
	local ok, ret = service:publish(node, stanza.attr.from, id, item);
	local reply;
	if ok then
		if type(ok) == "string" then
			id = ok;
		end
		reply = st.reply(stanza)
			:tag("pubsub", { xmlns = xmlns_pubsub })
				:tag("publish", { node = node })
					:tag("item", { id = id });
	else
		reply = pubsub_error_reply(stanza, ret);
	end
	origin.send(reply);
	return true;
end

function handlers.set_retract(origin, stanza, retract, service)
	local node, notify = retract.attr.node, retract.attr.notify;
	notify = (notify == "1") or (notify == "true");
	local item = retract:get_child("item");
	local id = item and item.attr.id
	if not (node and id) then
		origin.send(pubsub_error_reply(stanza, node and "item-not-found" or "nodeid-required"));
		return true;
	end
	local reply, notifier;
	if notify then
		notifier = st.stanza("retract", { id = id });
	end
	local ok, ret = service:retract(node, stanza.attr.from, id, notifier);
	if ok then
		reply = st.reply(stanza);
	else
		reply = pubsub_error_reply(stanza, ret);
	end
	origin.send(reply);
	return true;
end

function handlers.owner_set_purge(origin, stanza, purge, service)
	local node, notify = purge.attr.node, purge.attr.notify;
	notify = (notify == "1") or (notify == "true");
	local reply;
	if not node then
		origin.send(pubsub_error_reply(stanza, "nodeid-required"));
		return true;
	end
	local ok, ret = service:purge(node, stanza.attr.from, notify);
	if ok then
		reply = st.reply(stanza);
	else
		reply = pubsub_error_reply(stanza, ret);
	end
	origin.send(reply);
	return true;
end

function handlers.owner_get_configure(origin, stanza, config, service)
	local node = config.attr.node;
	if not node then
		origin.send(pubsub_error_reply(stanza, "nodeid-required"));
		return true;
	end

	local ok, node_config = service:get_node_config(node, stanza.attr.from);
	if not ok then
		origin.send(pubsub_error_reply(stanza, node_config));
		return true;
	end

	local pubsub_form_data = config_to_xep0060(node_config);
	local reply = st.reply(stanza)
		:tag("pubsub", { xmlns = xmlns_pubsub_owner })
			:tag("configure", { node = node })
				:add_child(node_config_form:form(pubsub_form_data));
	origin.send(reply);
	return true;
end

function handlers.owner_set_configure(origin, stanza, config, service)
	local node = config.attr.node;
	if not node then
		origin.send(pubsub_error_reply(stanza, "nodeid-required"));
		return true;
	end
	if not service:may(node, stanza.attr.from, "configure") then
		origin.send(pubsub_error_reply(stanza, "forbidden"));
		return true;
	end
	local config_form = config:get_child("x", "jabber:x:data");
	if not config_form then
		origin.send(st.error_reply(stanza, "modify", "bad-request", "Missing dataform"));
		return true;
	end
	local ok, old_config = service:get_node_config(node, stanza.attr.from);
	if not ok then
		origin.send(pubsub_error_reply(stanza, old_config));
		return true;
	end
	local form_data, err = node_config_form:data(config_form, old_config);
	if not form_data then
		origin.send(st.error_reply(stanza, "modify", "bad-request", err));
		return true;
	end
	local new_config = config_from_xep0060(form_data);
	local ok, err = service:set_node_config(node, stanza.attr.from, new_config);
	if not ok then
		origin.send(pubsub_error_reply(stanza, err));
		return true;
	end
	origin.send(st.reply(stanza));
	return true;
end

function handlers.owner_get_default(origin, stanza, default, service) -- luacheck: ignore 212/default
	local pubsub_form_data = config_to_xep0060(service.node_defaults);
	local reply = st.reply(stanza)
		:tag("pubsub", { xmlns = xmlns_pubsub_owner })
			:tag("default")
				:add_child(node_config_form:form(pubsub_form_data));
	origin.send(reply);
	return true;
end

function handlers.owner_get_affiliations(origin, stanza, affiliations, service)
	local node = affiliations.attr.node;
	if not node then
		origin.send(pubsub_error_reply(stanza, "nodeid-required"));
		return true;
	end
	if not service:may(node, stanza.attr.from, "set_affiliation") then
		origin.send(pubsub_error_reply(stanza, "forbidden"));
		return true;
	end

	local node_obj = service.nodes[node];
	if not node_obj then
		origin.send(pubsub_error_reply(stanza, "item-not-found"));
		return true;
	end

	local reply = st.reply(stanza)
		:tag("pubsub", { xmlns = xmlns_pubsub_owner })
			:tag("affiliations", { node = node });

	for jid, affiliation in pairs(node_obj.affiliations) do
		reply:tag("affiliation", { jid = jid, affiliation = affiliation }):up();
	end

	origin.send(reply);
	return true;
end

function handlers.owner_set_affiliations(origin, stanza, affiliations, service)
	local node = affiliations.attr.node;
	if not node then
		origin.send(pubsub_error_reply(stanza, "nodeid-required"));
		return true;
	end
	if not service:may(node, stanza.attr.from, "set_affiliation") then
		origin.send(pubsub_error_reply(stanza, "forbidden"));
		return true;
	end

	local node_obj = service.nodes[node];
	if not node_obj then
		origin.send(pubsub_error_reply(stanza, "item-not-found"));
		return true;
	end

	for affiliation_tag in affiliations:childtags("affiliation") do
		local jid = affiliation_tag.attr.jid;
		local affiliation = affiliation_tag.attr.affiliation;

		jid = jid_prep(jid);
		if affiliation == "none" then affiliation = nil; end

		local ok, err = service:set_affiliation(node, stanza.attr.from, jid, affiliation);
		if not ok then
			-- FIXME Incomplete error handling,
			-- see XEP 60 8.9.2.4 Multiple Simultaneous Modifications
			origin.send(pubsub_error_reply(stanza, err));
			return true;
		end
	end

	local reply = st.reply(stanza);
	origin.send(reply);
	return true;
end

local function create_encapsulating_item(id, payload)
	local item = st.stanza("item", { id = id, xmlns = xmlns_pubsub });
	item:add_child(payload);
	return item;
end

local function archive_itemstore(archive, config, user, node)
	module:log("debug", "Creation of itemstore for node %s with config %s", node, config);
	local get_set = {};
	local max_items = config["max_items"];
	function get_set:items() -- luacheck: ignore 212/self
		local data, err = archive:find(user, {
			limit = tonumber(max_items);
			reverse = true;
		});
		if not data then
			module:log("error", "Unable to get items: %s", err);
			return true;
		end
		module:log("debug", "Listed items %s", data);
		return it.reverse(function()
			local id, payload, when, publisher = data();
			if id == nil then
				return;
			end
			local item = create_encapsulating_item(id, payload, publisher);
			return id, item;
		end);
	end
	function get_set:get(key) -- luacheck: ignore 212/self
		local data, err = archive:find(user, {
			key = key;
			-- Get the last item with that key, if the archive doesn't deduplicate
			reverse = true,
			limit = 1;
		});
		if not data then
			module:log("error", "Unable to get item: %s", err);
			return nil, err;
		end
		local id, payload, when, publisher = data();
		module:log("debug", "Get item %s (published at %s by %s)", id, when, publisher);
		if id == nil then
			return nil;
		end
		return create_encapsulating_item(id, payload, publisher);
	end
	function get_set:set(key, value) -- luacheck: ignore 212/self
		local data, err;
		if value ~= nil then
			local publisher = value.attr.publisher;
			local payload = value.tags[1];
			data, err = archive:append(user, key, payload, time_now(), publisher);
		else
			data, err = archive:delete(user, { key = key; });
		end
		-- TODO archive support for maintaining maximum items
		archive:delete(user, {
			truncate = max_items;
		});
		if not data then
			module:log("error", "Unable to set item: %s", err);
			return nil, err;
		end
		return data;
	end
	function get_set:clear() -- luacheck: ignore 212/self
		return archive:delete(user);
	end
	function get_set:resize(size) -- luacheck: ignore 212/self
		max_items = size;
		return archive:delete(user, {
			truncate = size;
		});
	end
	function get_set:tail()
		-- This should conveniently return the last item
		local item = self:get(nil);
		if item then
			return item.attr.id, item;
		end
	end
	return setmetatable(get_set, archive);
end
_M.archive_itemstore = archive_itemstore;

return _M;