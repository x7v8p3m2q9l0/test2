-- minimal CC:Tweaked API shim, just enough to exercise supervisor/automation.lua's
-- load() and validate_rule() logic outside of an actual CC:Tweaked environment

os.epoch = function(kind) return 1700000000000 + math.floor(os.clock() * 1000) end

rs = {
    getSides = function() return { "top", "bottom", "left", "right", "front", "back" } end,
}

bit = {
    band = function(a, b) return a & b end,
    bor = function(a, b) return a | b end,
    bxor = function(a, b) return a ~ b end,
    bnot = function(a) return ~a end,
    blshift = function(a, b) return a << b end,
    brshift = function(a, b) return a >> b end,
}

package.preload["cc.strings"] = function()
    return {
        ensure_width = function(s, w) return s end,
        wrap = function(s, w) return { s } end,
    }
end

fs = {}
function fs.exists(path)
    local p = io.popen('test -e "' .. path .. '" && echo yes || echo no')
    local result = p:read("l")
    p:close()
    return result == "yes"
end

function fs.isDir(path)
    local p = io.popen('test -d "' .. path .. '" && echo yes || echo no')
    local result = p:read("l")
    p:close()
    return result == "yes"
end

function fs.list(path)
    local p = io.popen('ls -1 "' .. path .. '" 2>/dev/null')
    local items = {}
    for line in p:lines() do table.insert(items, line) end
    p:close()
    return items
end

function fs.combine(a, b)
    return a .. "/" .. b
end

function fs.open(path, mode)
    local f = io.open(path, mode == "r" and "r" or "w")
    if f == nil then return nil end
    return {
        readAll = function() local c = f:read("a"); return c end,
        writeLine = function(s) f:write(s, "\n") end,
        write = function(s) f:write(s) end,
        close = function() f:close() end
    }
end

textutils = {}
function textutils.unserialiseJSON(s)
    -- extremely small JSON parser sufficient for this test (arrays/objects/
    -- strings/numbers/booleans/null only, no unicode escapes) - NOT a general
    -- purpose parser, just enough to validate our example file's shape
    local pos = 1

    local function skip_ws() while pos <= #s and s:sub(pos,pos):match("%s") do pos = pos + 1 end end

    local parse_value

    local function parse_string()
        pos = pos + 1
        local start = pos
        local buf = {}
        while s:sub(pos,pos) ~= '"' do
            if s:sub(pos,pos) == "\\" then
                pos = pos + 1
                table.insert(buf, s:sub(pos,pos))
            else
                table.insert(buf, s:sub(pos,pos))
            end
            pos = pos + 1
        end
        pos = pos + 1
        return table.concat(buf)
    end

    local function parse_number()
        local start = pos
        while s:sub(pos,pos):match("[%d%.%-eE%+]") do pos = pos + 1 end
        return tonumber(s:sub(start, pos-1))
    end

    local function parse_array()
        pos = pos + 1
        local arr = {}
        skip_ws()
        if s:sub(pos,pos) == "]" then pos = pos + 1; return arr end
        while true do
            skip_ws()
            table.insert(arr, parse_value())
            skip_ws()
            if s:sub(pos,pos) == "," then pos = pos + 1
            else break end
        end
        skip_ws()
        pos = pos + 1 -- skip ]
        return arr
    end

    local function parse_object()
        pos = pos + 1
        local obj = {}
        skip_ws()
        if s:sub(pos,pos) == "}" then pos = pos + 1; return obj end
        while true do
            skip_ws()
            local key = parse_string()
            skip_ws()
            pos = pos + 1 -- skip :
            skip_ws()
            obj[key] = parse_value()
            skip_ws()
            if s:sub(pos,pos) == "," then pos = pos + 1
            else break end
        end
        skip_ws()
        pos = pos + 1 -- skip }
        return obj
    end

    parse_value = function()
        skip_ws()
        local c = s:sub(pos,pos)
        if c == '"' then return parse_string()
        elseif c == "{" then return parse_object()
        elseif c == "[" then return parse_array()
        elseif s:sub(pos,pos+3) == "true" then pos = pos + 4; return true
        elseif s:sub(pos,pos+4) == "false" then pos = pos + 5; return false
        elseif s:sub(pos,pos+3) == "null" then pos = pos + 4; return nil
        else return parse_number() end
    end

    local ok, result = pcall(parse_value)
    if not ok then return nil end
    return result
end
