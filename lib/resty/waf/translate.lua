local _M = {}

_M.version = "0.8.2"

local re_find  = ngx.re.find
local re_match = ngx.re.match
local re_sub   = ngx.re.sub
local re_gsub  = ngx.re.gsub

function _M.clean_input(input)
	local lines    = {}
	local line_buf = {}

	for i = 1, #input do
		local line = input[i]

		-- ignore comments and blank lines
		local skip
		if #line == 0 then skip = true end
		if re_match(line, [[^\s*$]], 'oj') then skip = true end
		if re_match(line, [[^\s*#]], 'oj') then skip = true end

		if not skip then
			-- trim whitespace
			line = re_gsub(line, [[^\s*|\s*$]], '', 'oj')

			if (re_match(line, [[\s*\\\s*$]], 'oj')) then
				-- string the multi-line escape and surrounding whitespace
				table.insert(line_buf, line)
			else
				-- either the end of a mutli line directive, or a standalone line
				-- push the buffer to the return array and clear the buffer
				table.insert(line_buf, line)

				local final_line = table.concat(line_buf, ' ')

				table.insert(lines, final_line)
				line_buf = {}
			end
		end
	end

	return lines
end

function _M.tokenize(line)
	local re_quoted   = [[^"((?:[^"\\]+|\\.)*)"]]
	local re_unquoted = [[([^\s]+)]]

	local tokens = {}
	local x = 0

	repeat
		local m = re_match(line, re_quoted, 'oj')

		if (not m) then
			m = re_match(line, re_unquoted, 'oj')
		end

		if (not m) then error('uhhhh wat') end

		-- got our token!
		local token = m[1]

		local toremove = [["?\Q]] .. token .. [[\E"?]]

		line = re_sub(line, toremove, '', 'oj')
		line = re_sub(line, [[^\s*]], '', 'oj')


		-- remove any scaping backslashes from escaped quotes
		token = re_gsub(token, '\\"', '"', 'oj')

		table.insert(tokens, token)

	until #line == 0

	return tokens
end

local function split(str, pat)
	local t = {}
	local fpat = "(.-)" .. pat
	local last_end = 1
	local s, e, cap = str:find(fpat, 1)

	while s do
		if s ~= 1 or cap ~= "" then
			table.insert(t,cap)
		end
		last_end = e + 1
		s, e, cap = str:find(fpat, last_end)
	end

	if last_end <= #str then
		cap = str:sub(last_end)
		table.insert(t, cap)
	end

	return t
end

function _M.parse_vars(raw_vars)
	local tokens = {}
	local parsed_vars = {}
	local var_buf = {}
	local sentinal

	local split_vars = split(raw_vars, '|')

	repeat
		local chunk = table.remove(split_vars, 1)
		table.insert(var_buf, chunk)

		if (not re_find(chunk, [[(?:\/'?|'?\/)]], 'oj') or not string.find(chunk, ':', 1, true)) then
			local inbuf = (#var_buf > 1 and re_find(var_buf[1], [[(?:\/'?|'?\/)]], 'oj'))

			if not inbuf then sentinal = true end
		end

		if (re_find(chunk, [[\/'?$]], 'oj')) then
			sentinal = true
		end

		if sentinal then
			local token = table.concat(var_buf, '|')
			table.insert(tokens, token)
			var_buf = {}
			sentinal = false
		end
	until #split_vars == 0

	for i = 1, #tokens do
		local token = tokens[i]

		local token_parts = split(token, ':')
		local var = table.remove(token_parts, 1)
		local specific = table.concat(token_parts, ':')

		local parsed = {}
		local modifier

		if (string.find(var, '!', 1, true)) then
			var = string.sub(var, 2, #var)
			parsed.modifier = '!'
		end
		if (string.find(var, '&', 1, true)) then
			var = string.sub(var, 2, #var)
			parsed.modifier = '&'
		end

		parsed.variable = var
		if #specific > 0 then parsed.specific = specific end

		table.insert(parsed_vars, parsed)
	end

	return parsed_vars
end

function _M.parse_operator(raw_operator)
	local op_regex = [[\s*(?:(\!)?(?:\@([a-zA-Z]+)\s*)?)?(.*)$]]

	local m = re_match(raw_operator, op_regex, 'oj')
	if not m then error("wtsf") end

	local negated = m[1]
	local operator = m[2]
	if not operator then operator = 'rx' end
	local pattern = m[3]

	local parsed = {}

	if negated then parsed.negated = negated end
	parsed.operator = operator
	parsed.pattern = pattern

	return parsed
end

function _M.parse_actions(raw_actions)
	local tokens = {}
	local parsed_actions = {}
	local action_buf = {}
	local sentinal = false

	local split_actions = split(raw_actions, ',')

	repeat
		local chunk = table.remove(split_actions, 1)
		table.insert(action_buf, chunk)

		if (not string.find(chunk, "'", 1, true) or not string.find(chunk, ':', 1, true)) then
			local inbuf = (#action_buf > 1 and string.find(action_buf[1], "'", 1, true))

			if not inbuf then sentinal = true end
		end

		if (re_find(chunk, [['$]], 'oj')) then
			sentinal = true
		end

		if sentinal then
			local token = table.concat(action_buf, ',')
			table.insert(tokens, token)
			action_buf = {}
			sentinal = false
		end
	until #split_actions == 0

	for i = 1, #tokens do
		local token = tokens[i]

		local token_parts = split(token, ':')
		local action = table.remove(token_parts, 1)
		local value = table.concat(token_parts, ':')

		action = re_gsub(action, [[^\s*|\s*$]], '', 'oj')

		local parsed = {
			action = action
		}

		if #value > 0 then parsed.value = value end

		table.insert(parsed_actions, parsed)
	end

	return parsed_actions
end

function _M.parse_tokens(tokens)
	local entry, directive, vars, operator, actions
	entry = {}

	entry["original"] = table.concat(tokens, ' ')

	directive = table.remove(tokens, 1)
	if (directive == 'SecRule') then
		vars = table.remove(tokens, 1)
		operator = table.remove(tokens, 1)
	end
	actions = table.remove(tokens, 1)

	if (#actions ~= 0) then error("we still have shit?!?!") end

	entry.directive = directive
	if vars then entry.vars = _M.parse_vars(vars) end
	if operator then entry.operator = _M.parse_operator(operator) end
	if actions ~= '' then entry.actions = _M.parse_actions(actions) end

	return entry
end

function _M.build_chains(rules)
	local chain = {}
	local chains = {}

	for i = 1, #rules do
		local rule = rules[i]

		table.insert(chain, rule)

		local is_chain
		if (type(rule.actions) == 'table') then
			for j = 1, #rule.actions do
				local action = rule.actions[i]
				if action.action == 'chain' then is_chain = true; break end
			end
		end

		if not is_chain then
			table.insert(chains, chain)
			chain = {}
		end
	end
end

return _M
