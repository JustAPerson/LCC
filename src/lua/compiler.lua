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
		max_stack = 1,
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

local c_state =  {}
c_state.__mt = {__index = c_state}
function c_state.new()
	local state = setmetatable({
		proto = c_proto.new(),
		ra_top = -1,
	}, c_state.__mt)

	return state
end

function c_state:ra_push()
	self.ra_top = self.ra_top + 1
	if self.ra_top == self.proto.max_stack then
		self.proto.max_stack = self.proto.max_stack + 1
	end
	return self.ra_top
end
function c_state:ra_pop()
	self.ra_top = self.ra_top - 1
end

local c_chunk, c_block, c_stat, c_stat_t, c_var, c_var_t, c_exp, c_exp_t, 
      c_explist, c_prefixexp, c_prefixexp_t, c_functioncall, c_functioncalls,
      c_args, c_args_t, c_tableconstructor, c_field

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

		local top_before = state.ra_top
		c_explist(state, node.explist, false)
		local top_after = state.ra_top

		local top_diff = top_after - top_before
		if n_var_list > top_after - top_before then
			top_after = top_after + 1	-- get next available register
			state.proto:emit('LOADNIL', node.varlist.list[top_after-1].line, 
			                 top_after, top_after + n_var_list - top_diff)
		end

		for i = n_var_list, 1, -1 do
			c_prefixexp(state, node.varlist.list[i], 0, top_before + i)
		end

		repeat
			state:ra_pop()
		until state.ra_top == top_before
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
			state.proto:emit('SETGLOBAL', node.line, arg,
			                 state.proto:constant(node.name))
		else
			local reg = state:ra_push()
			state.proto:emit('GETGLOBAL', node.line, reg,
			                 state.proto:constant(node.name))
			return reg
		end
	end,
	['prefixexp_exp'] = function(state, node, results, arg)
		local prefix_reg = c_prefixexp(state, node.prefixexp, 1)
		local exp_reg = c_exp(state, node.exp, 1)
		state:ra_pop()
		state:ra_pop()
		if results == 0 then
			state.proto:emit('SETTABLE', node.line, prefix_reg, exp_reg, arg)
		else
			arg = state:ra_push()
			state.proto:emit('GETTABLE', node.line, arg, prefix_reg, exp_reg)
			return arg
		end
	end,
	['prefixexp_name'] = function(state, node, results, arg)
		local reg = c_prefixexp(state, node.prefixexp, 1)
		state:ra_pop()
		if results == 0 then
			state.proto:emit('SETTABLE', node.line, reg, 
			                 state.proto:constant(node.name) + 256, arg)
		else
			arg = state:ra_push()
			state.proto:emit('GETTABLE', node.line, arg, reg,
			                 state.proto:constant(node.name) + 256)
			return arg
		end
	end
}
function c_var(state, node, write, arg)
	return c_var_t[node.type](state, node, write, arg)
end

c_exp_t = {
	['nil'] = function(state, node)
		local reg = state:ra_push()
		state.proto:emit('LOADNIL', node.line, reg, reg)
		return reg
	end,
	['false'] = function(state, node)
		local reg = state:ra_push()
		state.proto:emit('LOADBOOL', node.line, reg, 0, 0)
		return reg
	end,
	['true'] = function(state, node)
		local reg = state:ra_push()
		state.proto:emit('LOADBOOL', node.line, reg, 1, 0)
		return reg
	end,
	['number'] = function(state, node)
		local reg = state:ra_push()
		state.proto:emit('LOADK', node.line, reg,
		                 state.proto:constant(node.value))
		return reg
	end,
	['string'] = function(state, node)
		local reg = state:ra_push()
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
	['tableconstructor'] = function(state, node)
		return c_tableconstructor(state, node.tableconstructor)
	end,
}
function c_exp(state, node, results)
	return c_exp_t[node.type](state, node, results)
end

function c_explist(state, node, multi)
	local exp_list = node.list
	local n_exp_list = #exp_list
	local i = 0
	while i < n_exp_list do
		i = i + 1
		local exp = exp_list[i]
		if exp.type == 'nil' then
			local n = i
			i = i + 1
			local reg = state:ra_push()
			while i <= n_exp_list and node.explist[i].type == 'nil' do
				state:ra_push()
				i = i + 1
			end
			state.proto:emit('LOADNIL', exp.line, reg, reg + i - n - 1)
		else
			if i == n_exp_list and multi then	-- last exp can have multiple results
				c_exp(state, exp, -1)
				if (exp.type == 'prefixexp' and
				   exp.prefixexp.type == 'functioncall') or
				   exp.type == 'varg' then
					return -1
				end
			else
				c_exp(state, exp, 1)
			end
		end
	end
	return n_exp_list
end
c_prefixexp_t = {
	['var'] = function(state, node, results, arg)
		if results == 0 then
			return c_var(state, node.var, 0, arg)
		else
			return c_var(state, node.var, 1)
		end
	end,
	['functioncall'] = function(state, node, results)
		local reg = c_prefixexp(state, node.prefixexp, 1)
		return c_functioncall(state, node.functioncall, results, reg)
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
		local arg_count = c_args(state, node.args)
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
		return c_explist(state, node.explist, true)
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

--- Integer-to-Floating-Point-Byte
-- converts an integer to a "floating point byte", represented as
-- (eeeeexxx), where the real value is (1xxx) * 2^(eeeee - 1) if
-- eeeee != 0 and (xxx) otherwise.
-- This is taken verbatim from Yueliang.
--@author Kein-Hong Man
local function int2fb(x)
	local e = 0 -- exponent
	while x >= 16 do
		x = math.floor((x + 1) / 2)
		e = e + 1
	end
	if x < 8 then
		return x
	else
		return ((e + 1) * 8) + (x - 8)
	end
end

function c_tableconstructor(state, node)
	local n_array, n_hash = 0
	local fieldlist = node.fieldlist.list
	local n_fieldlist = #fieldlist
	for i = 1, n_fieldlist do
		if fieldlist[i].type == 'array' then
			n_array = n_array + 1
		end
	end
	n_hash = n_fieldlist - n_array
	local reg = state:ra_push()
	state.proto:emit('NEWTABLE', node.line, reg, int2fb(n_array),
	                 int2fb(n_hash))
	local n = 0
	for i = 1, n_fieldlist do
		local field = fieldlist[i]
		c_field(state, field, reg)
		if field.type == 'array' then
			n = n + 1
		end
		if i % 50 == 0 or i == n_fieldlist then
			state.proto:emit('SETLIST', field.line, reg, n % 50 + 1,
			                 math.ceil(n / 50))
			n = 0
		end
	end
end

local c_field_t = {
	['array'] = function(state, node)
		return c_exp(state, node.value_exp)
	end,
	['hash_exp'] = function(state, node, arg)
		local index_reg = c_exp(state, node.index_exp)
		local value_reg = c_exp(state, node.value_exp)
		state:ra_pop()
		state:ra_pop()
		return state.proto:emit('SETTABLE', node.line, arg, index_reg,
		                        value_reg)
	end,
	['hash_name'] = function(state, node, arg)
		local value_reg = c_exp(state, node.value_exp)
		state:ra_pop()
		return state.proto:emit('SETTABLE', node.line, arg,
		                        state.proto:constant(node.name) + 256,
		                        value_reg)
	end,
}
function c_field(state, node, arg)
	return c_field_t[node.type](state, node, arg)
end

function M.compile(input)
	local t_stream = c_lexer(input)
	if DEBUG then print(utils.serialize(t_stream, true)) end
	local _, ast = parser.parse(t_stream)
	if DEBUG then print(utils.serialize(ast, true)) end
	
	local state = c_state.new()
	state.proto.varg_flag = 2
	c_chunk(state, ast)
	state.proto:emit('RETURN', 0, 0, 1)
	
	if DEBUG then print(utils.serialize(state.proto, true)) end
	
	local header = string.dump(function() end):sub(1, 12)
	local chunk = {
		sizes = {
			int = header:sub(8, 8):byte(),
			size_t = header:sub(9, 9):byte(),
		},
		proto = state.proto,
	} 
	return linker.link(chunk)
end

return M