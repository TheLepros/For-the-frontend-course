-- Minimal JSON decoder for Lua
-- Usage: local json = require("json"); local t = json.decode(str)

local json = {}

local function skip_ws(s, i)
    local l = #s
    while i <= l do
        local c = s:sub(i, i)
        if c ~= ' ' and c ~= '\t' and c ~= '\r' and c ~= '\n' then
            break
        end
        i = i + 1
    end
    return i
end

local function parse_error(msg, s, i)
    error(("JSON decode error at char %d: %s"):format(i or -1, msg), 2)
end

local function parse_value(s, i)

    i = skip_ws(s, i)
    if i > #s then
        return parse_error("unexpected end of input", s, i)
    end

    local c = s:sub(i, i)

    if c == "n" then
        if s:sub(i, i+3) == "null" then
            return nil, i + 4
        end
        return parse_error("invalid literal 'null'", s, i)

    elseif c == "t" then
        if s:sub(i, i+3) == "true" then
            return true, i + 4
        end
        return parse_error("invalid literal 'true'", s, i)

    elseif c == "f" then
        if s:sub(i, i+4) == "false" then
            return false, i + 5
        end
        return parse_error("invalid literal 'false'", s, i)

    elseif c == '"' then
        -- string
        local res = {}
        i = i + 1
        while i <= #s do
            c = s:sub(i, i)
            if c == '"' then
                return table.concat(res), i + 1
            elseif c == "\\" then
                local n = s:sub(i+1, i+1)
                if n == '"' or n == "\\" or n == "/" then
                    res[#res+1] = n
                    i = i + 2
                elseif n == "b" then
                    res[#res+1] = "\b"; i = i + 2
                elseif n == "f" then
                    res[#res+1] = "\f"; i = i + 2
                elseif n == "n" then
                    res[#res+1] = "\n"; i = i + 2
                elseif n == "r" then
                    res[#res+1] = "\r"; i = i + 2
                elseif n == "t" then
                    res[#res+1] = "\t"; i = i + 2
                elseif n == "u" then
                    -- basic \uXXXX support for BMP only
                    local hex = s:sub(i+2, i+5)
                    if not hex:match("^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$") then
                        return parse_error("invalid unicode escape", s, i)
                    end
                    local code = tonumber(hex, 16)
                    if code <= 0x7F then
                        res[#res+1] = string.char(code)
                    elseif code <= 0x7FF then
                        local b1 = 0xC0 + math.floor(code / 0x40)
                        local b2 = 0x80 + (code % 0x40)
                        res[#res+1] = string.char(b1, b2)
                    else
                        local b1 = 0xE0 + math.floor(code / 0x1000)
                        local b2 = 0x80 + (math.floor(code / 0x40) % 0x40)
                        local b3 = 0x80 + (code % 0x40)
                        res[#res+1] = string.char(b1, b2, b3)
                    end
                    i = i + 6
                else
                    return parse_error("invalid escape sequence", s, i)
                end
            else
                res[#res+1] = c
                i = i + 1
            end
        end
        return parse_error("unterminated string", s, i)

    elseif (c == "-") or (c >= "0" and c <= "9") then
        -- number
        local j = i
        local l = #s
        while j <= l do
            local ch = s:sub(j, j)
            if (ch < "0" or ch > "9") and ch ~= "+" and ch ~= "-" and
               ch ~= "." and ch ~= "e" and ch ~= "E" then
                break
            end
            j = j + 1
        end
        local num_str = s:sub(i, j-1)
        local num = tonumber(num_str)
        if not num then
            return parse_error("invalid number", s, i)
        end
        return num, j

    elseif c == "[" then
        -- array
        local res = {}
        i = i + 1
        i = skip_ws(s, i)
        if s:sub(i, i) == "]" then
            return res, i + 1
        end
        local idx = 1
        while true do
            local val
            val, i = parse_value(s, i)
            res[idx] = val
            idx = idx + 1
            i = skip_ws(s, i)
            local ch = s:sub(i, i)
            if ch == "]" then
                return res, i + 1
            elseif ch ~= "," then
                return parse_error("expected ',' or ']'", s, i)
            end
            i = i + 1
        end

    elseif c == "{" then
        -- object
        local obj = {}
        i = i + 1
        i = skip_ws(s, i)
        if s:sub(i, i) == "}" then
            return obj, i + 1
        end
        while true do
            i = skip_ws(s, i)
            if s:sub(i, i) ~= '"' then
                return parse_error("expected string key", s, i)
            end
            local key
            key, i = parse_value(s, i)  -- reuse string parser
            i = skip_ws(s, i)
            if s:sub(i, i) ~= ":" then
                return parse_error("expected ':' after key", s, i)
            end
            i = skip_ws(s, i + 1)
            local val
            val, i = parse_value(s, i)
            obj[key] = val

            i = skip_ws(s, i)
            local ch = s:sub(i, i)
            if ch == "}" then
                return obj, i + 1
            elseif ch ~= "," then
                return parse_error("expected ',' or '}'", s, i)
            end
            i = i + 1
        end
    end

    return parse_error("unexpected character '" .. c .. "'", s, i)
end

function json.decode(str)
    if type(str) ~= "string" then
        error("json.decode expects a string", 2)
    end
    local res, i = parse_value(str, 1)
    i = skip_ws(str, i)
    if i <= #str then
        parse_error("trailing data", str, i)
    end
    return res
end

return json
