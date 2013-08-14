local utils = require 'utils'
local M = {}

local function l_error(c_stream, m)
	error(("[lcc.lexer]<%s:%s> %s"):format(c_stream.line, c_stream.char, m), 0)
end

local lookupify = utils.lookupify

local char_stream = {}
function char_stream.new(input)
	local stream = {
		input = input,
		length = #input,
		pos = 1,
		char = 0,
		line = 1,
	}
	setmetatable(stream, {__index = char_stream})
	return stream
end
function char_stream:eof()
	return self.pos > self.length
end
function char_stream:peek(n)
	n = self.pos + (n or 0)
	return self.input:sub(n, n)
end
function char_stream:get()
	local char = self:peek()
	if char == '\n' then
		self.line = self.line + 1
		self.char = 0
	end
	self.char = self.char + 1
	self.pos = self.pos + 1
	return char
end

local token_stream = {}
function token_stream.new(char_stream)
	local stream = {
		char_stream = char_stream,
		tokens = {},
		pos = 1,
	}
	setmetatable(stream, {__index = token_stream})
	return stream
end
function token_stream:add(token)
	local ts = self.char_stream
	token.char = ts.char
	token.line = ts.line
	self.tokens[#self.tokens + 1] = token
end
function token_stream:peek()
	return self.tokens[self.pos]
end
function token_stream:get()
	local token = self:peek()
	self.pos = self.pos + 1
	return token
end
function token_stream:is(val)
	if val then
		return self:peek().value == val
	else
		return self:peek().value
	end
end
function token_stream:type(type)
	if type then
		return self:peek().type == type
	else
		return self:peek().type
	end
end
function token_stream:test(type, value)
	if not self:type(type) then
		return false
	end
	if value then
		return self:is(value)
	else
		return true
	end
end
function token_stream:keyword(keyword)
	return self:test('keyword', keyword)
end
function token_stream:symbol(symbol)
	return self:test('symbol', symbol)
end
function token_stream:number()
	return self:type('number')
end
function token_stream:string()
	return self:type('string')
end
function token_stream:ident()
	return self:type('ident')
end
function token_stream:eof()
	return self:type('eof')
end

function token_stream:error(m)
	local token = self:peek()
	error(('[lcc.parser]<%s:%s> %s'):format(token.line, token.char, m), 0)
end
function token_stream:check(cond, expected)
	if not cond then
		self:error(('%s expected near %s'):format(expected, self:is()))
	end
end
function token_stream:check_token(type, val, m)
	self:check(self[type](self, val), m or val)
end

local l_whites = lookupify {' ', '\t', '\n',}
local l_numbers = lookupify {'0', '1', '2', '3', '4', '5', '6', '7', '8', '9',}
local l_hexs = lookupify {'0', '1', '2', '3', '4', '5', '6', '7', '8', '9',
						 'a', 'b', 'c', 'd', 'e', 'f',
                         'A', 'B', 'C', 'D', 'E', 'F',}
local l_alphas = lookupify {'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j',
                            'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't',
                            'u', 'v', 'w', 'x', 'y', 'z',
                            'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J',
                            'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T',
                            'U', 'V', 'W', 'X', 'Y', 'Z', '_',}

local l_rules = {}
function l_rules.ident_keyword(c_stream, t_stream, settings)
	local str
	local alphas, numbers = settings.alphas, settings.numbers
	if not settings.alphas[c_stream:peek()] then
		return false
	end
	str = c_stream:get()
	local peek = c_stream:peek()
	while alphas[peek] or numbers[peek] do
		str = str .. c_stream:get()
		peek = c_stream:peek()
	end
	t_stream:add {
		type = settings.keywords[str] and 'keyword' or 'ident',
		value = str,
	}
	return true
end
function l_rules.number(c_stream, t_stream, settings)
	local str = ''
	local numbers = settings.numbers
	if numbers[c_stream:peek()] then
		str = c_stream:get()
		if c_stream:peek():lower() == 'x' then
			str = str .. c_stream:get()
			numbers = settings.hexs
			if not numbers[c_stream:peek()] then
				l_error(c_stream, "Digit expected after 'x'")
			end
			str = str .. c_stream:get()
		end
		while numbers[c_stream:peek()] do
			str = str .. c_stream:get()
		end
		if c_stream:peek() == "." then
			str = str .. c_stream:get()
			if not numbers[c_stream:peek()] then
				l_error(c_stream, "Digit expected after '.'")
			end
			while numbers[c_stream:peek()] do
				str = str .. c_stream:get()
				io.stdout:flush()
			end
		end
		if c_stream:peek():lower() == "e" then
			str = str .. c_stream:get()
			local peek = c_stream:peek()
			if peek == "+" or peek == "-" then
				str = str .. c_stream:get()
			elseif not numbers[peek] then
				l_error(c_stream, "Digit expected after 'e'")
			end
			while numbers[c_stream:peek()] do
				str = str .. c_stream:get()
			end
		end
		t_stream:add {
			type = 'number',
			value = tonumber(str),
		}
		return true
	end
	return false
end
function l_rules.string(c_stream, t_stream, settings)
	local peek = c_stream:peek()
	local str, delim = ''
	if peek == '\'' or peek == '\"' then
		delim = c_stream:get()
		local last
		while not (c_stream:peek() == delim and last ~= '\\') do
			last = c_stream:get()
			str = str .. last
		end
		c_stream:get()
		t_stream:add {
			type = 'string',
			value = tostring(str),
		}
		return true
	elseif peek == '[' then
		delim = c_stream:get()
		while c_stream:peek() == '=' do
			delim = delim .. c_stream:get()
		end
		if c_stream:peek() ~= '[' then
			return false
		end
		delim = delim .. c_stream:get()
		delim = delim:gsub('%[', ']')
		while not (c_stream.input:sub(c_stream.pos, c_stream.pos + #delim - 1)
		           == delim) do
			str = str .. c_stream:get()
		end
		for i = 1, #delim do
			c_stream:get()
		end
		t_stream:add {
			type = 'string',
			value = str,
		}
		return true
	else
		return false
	end
end
function l_rules.symbol(c_stream, t_stream, settings)
	local symbols = settings.symbols
	for i = #symbols, 1, -1 do
		local check = ''
		for n = 1, i do
			check = check .. c_stream:peek(n - 1)
		end
		if symbols[i][check] then
			for n = 1, i do
				c_stream:get()
			end
			t_stream:add {
				type = 'symbol',
				value = check,
			}
			return true
		end
	end
	return false
end
function M.new(settings)
	settings.whites = l_whites
	settings.numbers = l_numbers
	settings.hexs = l_hexs
	settings.alphas = l_alphas
	local function lexer(input)
		local c_stream = char_stream.new(input)
		local t_stream = token_stream.new(c_stream)

		local l_rules, settings, l_whites = l_rules, settings, l_whites
		while true do -- Parse entire c_stream
			while l_whites[c_stream:peek()] do
				c_stream:get()
			end
			if c_stream:eof() then
				break
			end

			local old_pos = c_stream.pos
			local matched = false
			for _, rule in pairs(l_rules) do	-- Try all token rules
				if rule(c_stream, t_stream, settings) then
					matched = true
					break
				end
				c_stream.pos = old_pos
			end

			if not matched then
				l_error(c_stream,
				        ("Unexpected character '%s'"):format(c_stream:peek()))
			end
		end
		t_stream:add {
			type = 'eof',
			value = '<eof>',
		}

		return t_stream
	end
	
	return lexer
end

return  M
