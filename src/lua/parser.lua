local M = {}

local p_try, p_multiple, p_or

function p_try(t_stream, rule)
	local old_pos = t_stream.pos
	local s, capture = rule(t_stream)
	if s then
		return true, capture
	else
		t_stream.pos = old_pos
		return false
	end
end

function p_multiple(t_stream, rule)
	local t = {}
	while not t_stream:eof() do
		local s, capture = p_try(t_stream, rule)
		if s then
			t[#t + 1] = capture
		else
			break
		end
	end
	return t
end

function p_or(t_stream, rules)
	for _, rule in pairs(rules) do
		local s, capture = p_try(t_stream, rule)
		if s then
			return true, capture
		end
	end
end

local p_chunk, p_stat, p_laststat, p_varlist, p_var, p_namelist, p_explist,
      p_exp, p_prefixexp, p_prefixexp_restricted, p_args, p_functioncall

function p_chunk(t_stream)
	local stats = p_multiple(t_stream, p_stat)
	if not t_stream:eof() then
		local s, capture = p_laststat(t_stream)
		if s then
			stats[#stats + 1] = capture
		end
	end
	return true, {
		rule = 'chunk',
		statements = stats,
	}
end

local p_stat_t = {
	['varlist'] = function(t_stream)
		local s, varlist = p_varlist(t_stream)
		if not s then
			return false
		end
		if t_stream:eof() or not t_stream:symbol('=') then
			return false
		end
		t_stream:get()
		local s, explist = p_explist(t_stream)
		if not s then
			return false
		end
		return true, {
			rule = 'stat',
			type = 'varlist',
			varlist = varlist,
			explist = explist,
		}
	end,
	['functioncall'] = function(t_stream)
		local s, exp = p_functioncall(t_stream)
		if s then
			return true, {
				rule = 'stat',
				type = 'functioncall',
				prefixexp = exp
			}
		end
	end,
}
function p_stat(t_stream)
	if t_stream:eof() then
		return false
	end
	for _, rule in pairs(p_stat_t) do
		local s, capture = p_try(t_stream, rule)
		if s then
			if not t_stream:eof() and t_stream:symbol(';') then
				t_stream:get()
			end
			return true, capture
		end
	end
	return false
end

local p_laststat_t = {
	['return'] = function(t_stream)
		if not t_stream:keyword('return') then
			return false
		end
		local line = t_stream:get().line
		local s, explist = p_explist()
		if not s then
			return false
		end
		return true, {
			line = line,
			rule = 'stat',
			type = 'return',
			explist = explist,
		}
	end,
	['break'] = function(t_stream)
		if not t_stream:keyword('break') then
			return false
		end
		local line = t_stream:get().line
		return true, {
			line = line,
			rule = 'stat',
			type = 'break',
		}
	end,
}
function p_laststat(t_stream)
	for _, rule in pairs(p_laststat_t) do
		local s, capture = rule(t_stream)
		if s then
			if t_stream:symbol(';') then
				t_stream:get()
			end
			return true, capture
		end
	end
	return false
end

function p_varlist(t_stream)
	local list = {}
	local s, var = p_var(t_stream)
	if not s then
		return false
	end
	list[1] = var
	while not t_stream:eof() and t_stream:symbol(',') do
		t_stream:get()
		s, var = p_var(t_stream)
		if not s then
			error('Variable expected after `,`')
		end
		list[#list + 1] = var
	end
	return true, {
		rule = 'varlist',
		list = list,
	}
end

function p_var(t_stream)
	return p_prefixexp(t_stream)
end

function p_namelist(t_stream)

end

function p_explist(t_stream)
	local list = {}
	local s, var = p_exp(t_stream)
	if not s then
		return false, {
			rule = 'explist',
			list = list,
		}
	end
	list[1] = var
	while not t_stream:eof() and t_stream:symbol(',') do
		t_stream:get()
		s, var = p_exp(t_stream)
		if not s then
			error('Expression expected after `,`')
		end
		list[#list + 1] = var
	end
	return true, {
		rule = 'explist',
		list = list,
	}
end

local p_exp_t = {
	['nil'] = function(t_stream)
		if not t_stream:keyword('nil') then
			return false
		end
		t_stream:get()
		return true, {
			rule = 'exp',
			type = 'nil',
		}
	end,
	['false'] = function(t_stream)
		if not t_stream:keyword('false') then
			return false
		end
		t_stream:get()
		return true, {
			rule = 'exp',
			type = 'false',
		}
	end,
	['true'] = function(t_stream)
		if not t_stream:keyword('true') then
			return false
		end
		t_stream:get()
		return true, {
			rule = 'exp',
			type = 'true',
		}
	end,
	['number'] = function(t_stream)
		if not t_stream:number() then
			return false
		end
		return true, {
			rule = 'exp',
			type = 'number',
			value = t_stream:get().value
		}
	end,
	['string'] = function(t_stream)
		if not t_stream:string() then
			return false
		end
		return true, {
			rule = 'exp',
			type = 'string',
			value = t_stream:get().value
		}
	end,
	['varg'] = function(t_stream)
		if not t_stream:symbol('...') then
			return false
		end
		t_stream:get()
		return true, {
			rule = 'exp',
			type = 'varg',
		}
	end,
	['function'] = function(t_stream)
		
	end,
	['prefixexp'] = function(t_stream)
		local s, prefixexp = p_prefixexp(t_stream)
		if not prefixexp then
			return false
		end
		return true, {
			rule = 'exp',
			type = 'prefixexp',
			prefixexp = prefixexp,
		}
	end,
}
function p_exp(t_stream)
	return p_or(t_stream, p_exp_t)
end

function p_prefixexp(t_stream)
	if t_stream:eof() then
		return false
	end
	if t_stream:ident() then
		local ident = t_stream:get()
		return p_prefixexp_restricted(t_stream, {
			rule = 'prefixexp',
			type = 'var',
			var = {
				rule = 'var',
				type = 'name',
				line = ident.line,
				name = ident.value,
			},
		})
	else
		local s, prefixexp = p_prefixexp_restricted(t_stream)
		if s then
			return s, prefixexp
		end
		if t_stream:symbol('(') then
			local open = t_stream:get()
			local s, exp = p_exp(t_stream)
			if not s or t_stream:eof() or not t_stream:symbol(')') then
				return error()
			end
			t_stream:get()
			local s, prefix = p_prefixexp_restricted(t_stream, exp)
			return true, prefix
		end
		return false
	end
end

function p_prefixexp_restricted(t_stream, exp)
	if t_stream:eof() then
		return exp ~= nil, exp
	end
	if t_stream:symbol('[') then
		local sym = t_stream:get()
		local s, index_exp = p_exp(t_stream)
		if not s then
			return error()
		end
		if not t_stream:symbol(']') then
			return error()
		end
		t_stream:get()
		return p_prefixexp_restricted(t_stream, {
			rule = 'prefixexp',
			type = 'var',
			line = sym.line,
			var = {
				rule = 'var',
				type = 'prefixexp_exp',
				prefixexp = exp,
				exp = index_exp,
			}
		})
	elseif t_stream:symbol('.') then
		local sym = t_stream:get()
		if not t_stream:ident() then
			return error()
		end
		local name = t_stream:get()
		return p_prefixexp_restricted(t_stream, {
			rule = 'prefixexp',
			type = 'var',
			line = sym.line,
			var = {
				rule = 'var',
				type = 'prefixexp_name',
				prefixexp = exp,
				name = name.value,
			}
		})
	else
		local method
		if t_stream:symbol(':') then
			t_stream:get()
			if not t_stream:ident() then
				return error()
			end
			method = t_stream:get().value
		end
		local s, args = p_args(t_stream, exp)
		if s then
			local token = {
				rule = 'functioncall',
				type = method and 'method' or 'normal',
				line = args.line,
				args = args
			}
			if method then
				token.name = method
			end
			return p_prefixexp_restricted(t_stream, {
				rule = 'prefixexp',
				type = 'functioncall',
				prefixexp = exp,
				functioncall = token,
			})
		else
			return exp ~= nil, exp
		end --]]
	end 
end

function p_args(t_stream, exp)
	if exp then	-- don't match p_args without a prefixexp
		if t_stream:symbol('(') then
			local open = t_stream:get()
			local _, explist = p_explist(t_stream)
			if not t_stream:symbol(')') then
				return error()
			end
			t_stream:get()
			return true, {
				rule = 'args',
				type = 'explist',
				line = open.line,
				explist = explist,
			}
		elseif t_stream:symbol('{') then
			local _, tableconstructor = p_tableconstructor()
			return true, {
				rule = 'args',
				type = 'tableconstructor',
				line = tableconstructor.line,
				tableconstructor = tableconstructor,
			}
		elseif t_stream:string() then
			local str = t_stream:get().value
			return true, {
				rule = 'args',
				type = 'string',
				line = str.line,
				value = str.value,
			}
		else
			return false
		end
	end
end

function p_functioncall(t_stream)
	local s, exp = p_prefixexp(t_stream)
	if not s then
		return false
	end
	if exp.rule == 'prefixexp' and exp.type == 'functioncall' then
		return true, exp
	end
	return false
end

function M.parse(t_stream)
	return p_chunk(t_stream)
end

return M