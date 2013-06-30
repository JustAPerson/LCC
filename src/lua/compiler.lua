local utils = require 'utils'
local lexer = require 'lexer'
local parser = require 'lua.parser'
local linker = require 'lasm.linker'
local opcodes = require 'lasm.opcodes'
local M = {}

local lookupify = utils.lookupify
M.settings = {
	keywords = lookupify {'and', 'break', 'do', 'else', 'elseif', 'end',
	                      'false', 'for', 'function', 'if', 'in', 'local',
	                      'nil', 'not', 'or', 'repeat', 'return', 'then',
	                      'true', 'until', 'while'},
	symbols = {
		[1] = lookupify {'+', '-', '*', '/', '%', '^', '#', '>', '<', '=', '(',
		                 ')', '{', '}', '[', ']', ';', ':', ',', '.',},
		[2] = lookupify {'==', '~=', '<=', '>=', '..'},
		[3] = lookupify {'...'},
	},
}
local c_lexer = lexer.new(M.settings)

local c_proto = {}
c_proto.__mt = {__index = c_proto}
function c_proto.new()
	local proto = setmetatable({
		name = '',
		first_line = 0,
		last_line = 0,
		args = 0,
		varg_flag = 0,
		max_stack = 0,
		instructions = {},
		constants = {},
		protos = {},
		locals = {},
		upvalues = {},
		
		ktable = {},
	}, c_proto.__mt)
	return proto
end
function c_proto:add_proto(a)
	self.protos[#self.protos + 1] = a
end
function c_proto:emit(opcode, line, A, B, C)
	local type = opcodes.type[opcode]
	local instr = {
		type = type,
		opcode = opcode,
		line = line or 0,
		A = A or 0,
		B = B or 0,
		C = C or 0,
	}
	self.instructions[#self.instructions + 1] = instr
end
function c_proto:constant(k)
	if self.ktable[k] then
		return self.ktable[k]
	else
		local index = #self.constants
		self.constants[index + 1] = {type = type(k), value = k}
		self.ktable[k] = index
		return index
	end
end

local state = {}
state.__mt = {__index = state}
function state.new()
	local state = setmetatable({}, state.__mt)
	state.proto_root = c_proto.new()
	state.proto = state.proto_root
	state.ra_state_root = {}
	state.ra_state_root.state_root = {regs = {}, top = false}
	state.ra_state_root.state = state.ra_state_root.state_root
	state.ra_state = state.ra_state_root
	state.scope_root = {env = {}}
	state.scope = state.scope_root
	return state
end
function state:push()
	local proto = proto.new()
	proto.parent = self.proto
	self.proto:add_proto(prot)
	self.proto = proto
	self:sc_push()
	local ra_state = {}
	ra_state.parent = self.ra_state
	ra_state.state_root = {regs = {}}
	ra_state.state = ra_state.state_root
	self.ra_state = ra_state
end
function state:pop()
	self.proto = self.proto.parent
	self:sc_pop()
	self.ra_state = self.ra_state.parent
end
-- Register Allocator
function state:ra_push()
	local state = {
		regs = setmetatable({}, {__index = self.ra_state.state.regs}),
		list = {},
		top = false,
		parent =  self.ra_state.state,
	}
	self.ra_state.state = state
	
	return state.list
end
function state:ra_pop()
	self.ra_state.state = self.ra_state.state.parent
end
function state:ra_top()
	self.ra_state.state.top = not self.ra_state.state.top
end
function state:ra_get_top()
	local state = self.ra_state.state
	local regs = state.regs
	local i = self.proto.max_stack - 1	-- because max_stack is number of 
	                                  	-- registers used, get 0 based index
	while not regs[i] and i >= 0 do -- find top of stack
		i = i - 1
	end
	return i
end
function state:ra_alloc()
	local state = self.ra_state.state
	local regs = state.regs
	if state.top then
		local index = self:ra_get_top() + 1
		regs[index] = true
		state.list[#state.list + 1] = index
		if index + 1 > self.proto.max_stack then
			self.proto.max_stack = index + 1
		end
		return index
	else
		for i = 0, 255 do
			if not regs[i] then
				regs[i] = true
				state.list[#state.list + 1] = i
				if i + 1 > self.proto.max_stack then
					self.proto.max_stack = i + 1
				end
				return i
			end
		end
	end
end
function state:ra_free(reg)
	self.ra_state.state.regs[reg] = nil
end

-- Scope
function state:sc_push()
	local scope = {
		env = setmetatable({}, {__index = self.scope.env}),
		parent = self.scope,
	}
	self.scope = scope
end
function state:sc_pop()
	self.scope = self.scope.parent
end
function state:sc_new_local(name)
	self.scope.env[name] = self:ra_alloc()
end
function state:sc_get_local(name)
	return self.scope.env[name]
end

local c_chunk, c_block, c_stat, c_stat_t, c_var, c_var_t, c_exp, c_exp_t, 
      c_explist, c_prefixexp, c_prefixexp_t, c_functioncall, c_functioncalls,
      c_args, c_args_t, c_tableconstructor

function c_chunk(state, node)
	for _, statement in pairs(node.statements) do
		c_stat(state, statement)
	end
end

function c_block(state, node)
	return c_chunk(state, node)
end

c_stat_t = {
	['varlist'] = function(state, node)
		local n_var_list = #node.varlist.list
		state:ra_push()
		
		local top_before = state:ra_get_top()
		local reg_list = c_explist(state, node.explist, #node.varlist.list)
		local top_after = state:ra_get_top()
		
		local top_diff = top_after - top_before
		if n_var_list > top_after - top_before then
			top_after = top_after + 1	-- get next available register
			state.proto:emit('LOADNIL', node.varlist.list[i-1].line, 
			                 top_after, top_after + n_var_list - top_diff)
		end
		
		for i = n_var_list, 1, -1 do
			c_prefixexp(state, node.varlist.list[i], 0, reg_list[i])
		end
		state:ra_pop()
	end,
	['functioncall'] = function(state, node)
		return c_prefixexp(state, node.prefixexp, 0)
	end,
}
function c_stat(state, node)
	c_stat_t[node.type](state, node)
end

c_var_t = {
	['name'] = function(state, node, results, arg)
		if results == 0 then
			local reg = state:sc_get_local(node.name)
			if reg then
				state.proto:emit('MOVE', node.line, reg, arg)
			else
				state.proto:emit('SETGLOBAL', node.line, arg, 
				                 state.proto:constant(node.name))
			end
		else
			local reg = state:sc_get_local(node.name)
			if reg then
				state.proto:emit('MOVE', node.line, arg, reg)
			else
				state.proto:emit('GETGLOBAL', node.line, arg, 
				                 state.proto:constant(node.name))
				return reg
			end
		end
	end,
	['prefixexp_exp'] = function(state, node, results, arg)
		local prefix_reg = c_prefixexp(state, node.prefixexp, 1)
		local exp_reg = c_exp(state, node.exp, 1)
		if results == 0 then
			state.proto:emit('SETTABLE', node.line, prefix_reg, exp_reg, arg)
		else
			state.proto:emit('GETTABLE', node.line, arg, prefix_reg, exp_reg)		
		end
	end,
	['prefixexp_name'] = function(state, node, results, arg)
		local reg = c_prefixexp(state, node.prefixexp, 1)
		if results == 0 then
			state.proto:emit('SETTABLE', node.line, reg, 
			                 state.proto:constant(node.name) + 256, arg)
		else
			state.proto:emit('GETTABLE', node.line, arg, reg,
			                 state.proto:constant(node.name) + 256)
		end
		state:ra_free(reg)
	end
}
function c_var(state, node, write, arg)
	return c_var_t[node.type](state, node, write, arg)
end

c_exp_t = {
	['nil'] = function(state, node)
		local reg = state:ra_alloc()
		state.proto:emit('LOADNIL', node.line, reg, reg)
		return reg
	end,
	['false'] = function(state, node)
		local reg = state:ra_alloc()
		state.proto:emit('LOADBOOL', node.line, reg, 0, 0)
		return reg
	end,
	['true'] = function(state, node)
		local reg = state:ra_alloc()
		state.proto:emit('LOADBOOL', node.line, reg, 1, 0)
		return reg
	end,
	['number'] = function(state, node)
		local reg = state:ra_alloc()
		state.proto:emit('LOADK', node.line, reg,
		                 state.proto:constant(node.value))
		return reg
	end,
	['string'] = function(state, node)
		local reg = state:ra_alloc()
		state.proto:emit('LOADK', node.line, reg,
		                 state.proto:constant(node.value))
		return reg
	end,
	['varg'] = function(state, node)
	
	end,
	['function'] = function(state, node)
	
	end,
	['prefixexp'] = function(state, node, results)
		return c_prefixexp(state, node.prefixexp, results)
	end,
}
function c_exp(state, node, results)
	return c_exp_t[node.type](state, node, results)
end

function c_explist(state, node, n_vars)
	local reg_list = {}
	local exp_list = node.list
	local n_exp_list = #exp_list
	local i = 0
	while i < n_exp_list do
		i = i + 1
		local exp = exp_list[i]
		if exp.type == 'nil' then
			local n = i
			i = i + 1
			local reg = state:ra_alloc()
			while i <= n_exp_list and node.explist[i].type == 'nil' do
				state:ra_alloc()
				i = i + 1
			end
			state.proto:emit('LOADNIL', exp.line, reg, reg + i - n - 1)
		else
			if i == n_exp_list then	-- last exp can have multiple results
				reg_list[#reg_list + 1] = c_exp(state, exp, -1)			
			else
				reg_list[#reg_list + 1] = c_exp(state, exp, 1)
			end
		end
	end
	return reg_list
end
c_prefixexp_t = {
	['var'] = function(state, node, results, arg)
		if results == 0 then
			c_var(state, node.var, 0, arg)
		else
			local reg = state:ra_alloc()
			c_var(state, node.var, 1, reg)
			return reg			
		end
	end,
	['functioncall'] = function(state, node, results)
		state:ra_push()
		state:ra_top()
		local reg = c_prefixexp(state, node.prefixexp, 1)
		c_functioncall(state, node.functioncall, results, reg)
		state:ra_top()
		state:ra_pop()
	end,
	['exp'] = function(state, node)
		return c_exp(state, node.exp, 1)
	end,
}
function c_prefixexp(state, node, results, arg)
	return c_prefixexp_t[node.type](state, node, results, arg)
end

c_functioncalls = {
	['normal'] = function(state, node, results, func)
		local arg_count = c_args(state, node.args)	-- TODO loop over args
		state.proto:emit('CALL', node.line, func, arg_count + 1, results + 1)
	end,
	['method'] = function(state, node, results, func)
	
	end,
}
function c_functioncall(state, node, results, func)
	return c_functioncalls[node.type](state, node, results, func)
end

c_args_t = {
	['explist'] = function(state, node)
		return #c_explist(state, node)
	end,
	['tableconstructor'] = function(state, node)
		c_tableconstructor(state, node.tableconstructor)
		return 1
	end,
	['string'] = function(state, node)
		c_exp_t['string'](state, node)
		return 1
	end,
}
function c_args(state, node)
	return c_args_t[node.type](state, node)
end

function c_tableconstructor(state, node)

end

function M.compile(input)
	local t_stream = c_lexer(input)
	if DEBUG then print(utils.serialize(t_stream, true)) end
	local _, ast = parser.parse(t_stream)
	if DEBUG then print(utils.serialize(ast, true)) end
	
	local state = state.new()
	state.proto_root.varg_flag = 2
	state.proto_root.max_stack = 1
	c_chunk(state, ast)
	state.proto_root:emit('RETURN', 0, 0, 1)
	
	if DEBUG then print(utils.serialize(state.proto, true)) end
	
	local header = string.dump(function() end):sub(1, 12)
	local chunk = {
		sizes = {
			int = header:sub(8, 8):byte(),
			size_t = header:sub(9, 9):byte(),
		},
		proto = state.proto_root,
	} 
	return linker.link(chunk)
end

return M