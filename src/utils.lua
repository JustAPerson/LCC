local M = {}

function M.lookupify(t)
	local new = {}
	for i,v in pairs(t) do
		new[v] = true
	end
	return new
end

-- table to string serializer in Lua written by q66 on #lua@irc.freenode.net
-- see http://codepad.org/gyNqErXu for full code
do
	-- utils
	local is_array = function(t)
	    local i = 0
	    while t[i + 1] do i = i + 1 end
	    for _ in pairs(t) do
	        i = i - 1 if i < 0 then return false end
	    end
	    return i == 0
	end
	
	local tconc = table.concat
	local type = type
	local pairs, ipairs = pairs, ipairs
	local pcall = pcall
	
	local str_escapes = setmetatable({
	    ["\n"] = "\\n", ["\r"] = "\\r",
	    ["\a"] = "\\a", ["\b"] = "\\b",
	    ["\f"] = "\\f", ["\t"] = "\\t",
	    ["\v"] = "\\v", ["\\"] = "\\\\",
	    ['"' ] = '\\"', ["'" ] = "\\'"
	}, {
	    __index = function(self, c) return ("\\%03d"):format(c:byte()) end
	})
	local str_escp = (_VERSION == "Lua 5.2") and "\0\001-\031" or "%z\001-\031"
	
	local escape_string = function(s)
	    -- a space optimization: decide which string quote to
	    -- use as a delimiter (the one that needs less escaping)
	    local nsq, ndq = 0, 0
	    for c in s:gmatch("'") do nsq = nsq + 1 end
	    for c in s:gmatch('"') do ndq = ndq + 1 end
	    local sd = (ndq > nsq) and "'" or '"'
	    return sd .. s:gsub("[\\"..sd..str_escp.."]", str_escapes) .. sd
	end
	
	-- serializer
	local function serialize_fn(v, stream, kwargs, simp, tables, indent)
	    if simp then
	        v = simp(v)
	    end
	    local tv = type(v)
	    if tv == "string" then
	        stream(escape_string(v))
	    elseif tv == "number" or tv == "boolean" then
	        stream(tostring(v))
	    elseif tv == "table" then
	        local mline   = kwargs.multiline
	        local indstr  = kwargs.indent
	        local asstr   = kwargs.assign or "="
	        local sepstr  = kwargs.table_sep or ","
	        local isepstr = kwargs.item_sep
	        local endsep  = kwargs.end_sep
	        local optk    = kwargs.optimize_keys
	        local arr = is_array(v)
	        local nline   = arr and kwargs.narr_line or kwargs.nrec_line or 0
	        if tables[v] then
	            stream() -- let the stream know about an error
	            return false,
	                "circular table reference detected during serialization"
	        end
	        tables[v] = true
	        stream("{")
	        if mline then stream("\n") end
	        local first = true
	        local n = 0
	        for k, v in (arr and ipairs or pairs)(v) do
	            if first then first = false
	            else
	                stream(sepstr)
	                if mline then
	                    if n == 0 then
	                        stream("\n")
	                    elseif isepstr then
	                        stream(isepstr)
	                    end
	                end
	            end
	            if mline and indstr and n == 0 then
	                for i = 1, indent do stream(indstr) end
	            end
	            if arr then
	                local ret, err = serialize_fn(v, stream, kwargs, simp, tables,
	                    indent + 1)
	                if not ret then return ret, err end
	            else
	                if optk and type(k) == "string"
	                and k:match("^[%a_][%w_]*$") then
	                    stream(k)
	                else
	                    stream("[")
	                    local ret, err = serialize_fn(k, stream, kwargs, simp,
	                        tables, indent + 1)
	                    if not ret then return ret, err end
	                    stream("]")
	                end
	                stream(asstr)
	                local ret, err = serialize_fn(v, stream, kwargs, simp, tables,
	                    indent + 1)
	                if not ret then return ret, err end
	            end
	            n = (n + 1) % nline
	        end
	        if not first then
	            if endsep then stream(sepstr) end
	            if mline then stream("\n") end
	        end
	        if mline and indstr then
	            for i = 2, indent do stream(indstr) end
	        end
	        stream("}")
	    else
	        stream()
	        return false, ("invalid value type: " .. tv)
	    end
	    return true
	end
	
	local defkw = {
	    multiline = false, indent = nil, assign = "=", table_sep = ",",
	    end_sep = false, optimize_keys = true
	}
	
	local defkwp = {
	    multiline = true, indent = "    ", assign = " = ", table_sep = ",",
	    item_sep = " ", narr_line = 4, nrec_line = 2, end_sep = false,
	    optimize_keys = true
	}
	
	M.serialize = function(val, kwargs, stream, simplifier)
	    if kwargs == true then
	        kwargs = defkwp
	    elseif not kwargs then
	        kwargs = defkw
	    else
	        if  kwargs.optimize_keys == nil then
	            kwargs.optimize_keys = true
	        end
	    end
	    if stream then
	        return serialize_fn(val, stream, kwargs, simplifier, {}, 1)
	    else
	        local t = {}
	        local ret, err = serialize_fn(val, function(out)
	            t[#t + 1] = out end, kwargs, simplifier, {}, 1)
	        if not ret then
	            return nil, err
	        else
	            return tconc(t)
	        end
	    end
	end
end

do
	local floor = math.floor
	
	local function shiftr(x, n)
		return floor(x / 2^n)
	end
	local function shiftl(x, n)
		return x * 2^n
	end
	local function keep(x, n)
		return x % 2^n
	end
	
	local e_int8 = string.char
	local function e_int32(n)
		local str = ''
		for i = 1, 4 do
			str = str .. e_int8(keep(n, 8))
			n = shiftr(n, 8)
		end
		return str
	end
	local function e_int64(n)
		return e_int32(n % 2^32) .. e_int32(shiftr(n, 32))
	end
	local function e_float64(x)
		-- TODO redo
		local function grab_byte(v)
			return floor(v / 256), e_int8(floor(v) % 256)
		end
		local sign = 0
		if x < 0 then sign = 1; x = -x end
		local mantissa, exponent = math.frexp(x)
		if x == 0 then -- zero
		mantissa, exponent = 0, 0
		elseif x == 1/0 then
		mantissa, exponent = 0, 2047
		else
		mantissa = (mantissa * 2 - 1) * math.ldexp(0.5, 53)
		exponent = exponent + 1022
		end
		local v, byte = "" -- convert to bytes
		x = mantissa
		for i = 1,6 do
		x, byte = grab_byte(x)
		v = v..byte -- 47:0
		end
		x, byte = grab_byte(exponent * 16 + x)
		v = v..byte -- 55:48
		x, byte = grab_byte(sign * 128 + x)
		v = v..byte -- 63:56
		return v
	end
	
	local d_int8 = string.byte
	local function d_int32(s)
		
	end
	local function d_int64()
	end
	
	M.bit = {
		shiftr = shiftr,
		shiftl = shiftl,
		keep = keep,
		encode = {
			int8 = e_int8,
			int32 = e_int32,
			int64 = e_int64,
			float64 = e_float64,
		},
		decode = {
			int8 = d_int8,
			--int32 = d_int32,
			--int64 = d_int64,
		},
	}
end
return M