--[[
	chunk = {
		sizes = {
			int = 4,
			size_t = 4,
		}
		proto = proto,
	}
	
	proto = {
		name = '',
		first_line = 1,
		last_line = 2,
		args = 0,
		varg_flag = 0,
		max_stack = 3,
		instructions = {
			instruction,
		},
		constants = {
			constant,
		},
		protos = {
			proto,
		},
		locals = {
			local,
		},
		upvalues = {
			'name',
		},
	}
	
	instruction = {
		type = 'ABC/ABx/sBx',
		opcode = 'MOVE/LOADK/...',
		line = 1,
		A = 0,
		B = 0,	-- Servers as both Bx and sBx when necessary
		C = 0,
	}
	
	constant = {
		type = 'nil/bool/number/string',
		value,
	}
	
	local = {
		'name',
		spc = 0,
		epc = 1,
	}
--]]
local opcodes = require 'lasm.opcodes'
local bit = require 'utils'.bit.encode

local M = {}

local e_int, e_size_t
local e_number, e_int8, e_int32 = bit.float64, bit.int8, bit.int32

local function e_string(str)
	return e_size_t(#str + 1) .. str .. '\0'
end
local function e_instruction(instr)
	local floor = math.floor
--[[
	if instr.type == 'AsBx' then 
		instr.B = instr.B + 131071
		instr.type = 'ABx'
	end
	if instr.type == 'ABx' then
		instr.C = instr.B % 2^9
		instr.B = floor(instr.B / 2^9)
	end
	local c1, c2, c3, c4
	c1 = opcodes.name[instr.opcode] + (instr.A % 2^2) * 2^6
	c2 = floor(instr.A / 2^2) + (instr.C % 2^2) * 2^6
	c3 = floor(instr.C / 2^2) + (instr.B % 2^1) * 2^7
	c4 = floor(instr.B / 2^1)
	-- TODO redo using int32
--]]
	local n = opcodes.name[instr.opcode]
	n = n + instr.A * 2^6
	if instr.type == 'ABC' then
		n = n + instr.C * 2^14
		n = n + instr.B * 2^23
	elseif instr.type == 'ABx' then
		n = n + instr.B * 2^14
	elseif instr.type == 'AsBx' then
		n = n + (instr.B + 131071) * 2^14
	end
	return e_int32(n) 
end

local function l_proto(proto)
	local e_int, e_size_t, e_number, e_int8, e_string, e_instruction = e_int,
	      e_size_t, e_number, e_int8, e_string, e_instruction
	
	local output = ''
	if #proto.name == 0 then
		output = output .. e_size_t(0)
	else
		output = output .. e_string(proto.name)
	end
	output = output .. e_int(proto.first_line)
	output = output .. e_int(proto.last_line)
	output = output .. e_int8(#proto.upvalues)
	output = output .. e_int8(proto.args)
	output = output .. e_int8(proto.varg_flag)
	output = output .. e_int8(proto.max_stack)
	
	output = output .. e_int(#proto.instructions)
	for i, v in pairs(proto.instructions) do
		output = output .. e_instruction(v)
	end
	
	output = output .. e_int(#proto.constants)
	for i, v in pairs(proto.constants) do
		if v.type == 'nil' then
			output = output .. '\0'
		elseif v.type == 'bool' then
			output = output .. '\1'
			output = output .. (v.value and '\1' or '\0')	
		elseif v.type == 'number' then
			output = output .. '\3'
			output = output .. e_number(v.value)			
		elseif v.type == 'string' then
			output = output .. '\4'
			output = output .. e_string(v.value)
		end
	end
	
	output = output .. e_int(#proto.protos)
	for i, v in pairs(proto.protos) do
		output = output .. l_proto(v)
	end
	
	if proto.instructions[1] and proto.instructions[1].line then
		output = output .. e_int(#proto.instructions)
		for i, v in pairs(proto.instructions) do
			output = output .. e_int(v.line)
		end
	else
		output = output .. e_int(0)
	end
	
	output = output .. e_int(#proto.locals)
	for i, v in pairs(proto.locals) do
		output = output .. e_string(v.name)
		output = output .. e_int(v.spc)
		output = output .. e_int(v.epc)
	end
	
	output = output .. e_int(#proto.upvalues)
	for i,v in pairs(proto.upvalues) do
		output = output .. e_string(v)
	end
	
	return output
end

function M.link(chunk)
	local output = ''
	output = output .. '\27Lua'	-- Signature
	output = output .. '\81'	-- Version
	output = output .. '\0'	-- Official (0 = official)
	output = output .. '\1'	-- Endianness (0 = big)
	local s = chunk.sizes
	output = output .. e_int8(s.int) -- Size of int
	output = output .. e_int8(s.size_t) -- Size of size_t
	output = output .. '\4'	-- Size of instruction (Unimplemented)
	output = output .. '\8'	-- Size of lua_Number (Unimplemented)
	output = output .. '\0'	-- Integral flag (0 = floating point)
	
	if s.int == 4 then
		e_int = bit.int32
	elseif s.int == 8 then
		e_int = bit.int64
	end
	
	if s.size_t == 4 then
		e_size_t = bit.int32
	elseif s.size_t == 8 then
		e_size_t = bit.int64
	end
	
	output = output .. l_proto(chunk.proto)
	return output
end

return M