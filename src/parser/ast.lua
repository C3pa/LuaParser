local emmy = require 'parser.emmy'

local tonumber    = tonumber
local stringChar  = string.char
local utf8Char    = utf8.char
local tableUnpack = table.unpack
local mathType    = math.type
local tableRemove = table.remove

_ENV = nil

local State
local PushError

-- goto 单独处理
local RESERVED = {
    ['and']      = true,
    ['break']    = true,
    ['do']       = true,
    ['else']     = true,
    ['elseif']   = true,
    ['end']      = true,
    ['false']    = true,
    ['for']      = true,
    ['function'] = true,
    ['if']       = true,
    ['in']       = true,
    ['local']    = true,
    ['nil']      = true,
    ['not']      = true,
    ['or']       = true,
    ['repeat']   = true,
    ['return']   = true,
    ['then']     = true,
    ['true']     = true,
    ['until']    = true,
    ['while']    = true,
}

local VersionOp = {
    ['&']  = {'Lua 5.3', 'Lua 5.4'},
    ['~']  = {'Lua 5.3', 'Lua 5.4'},
    ['|']  = {'Lua 5.3', 'Lua 5.4'},
    ['<<'] = {'Lua 5.3', 'Lua 5.4'},
    ['>>'] = {'Lua 5.3', 'Lua 5.4'},
    ['//'] = {'Lua 5.3', 'Lua 5.4'},
}

local function checkOpVersion(op)
    local versions = VersionOp[op.type]
    if not versions then
        return
    end
    for i = 1, #versions do
        if versions[i] == State.version then
            return
        end
    end
    PushError {
        type    = 'UNSUPPORT_SYMBOL',
        start   = op.start,
        finish  = op.finish,
        version = versions,
        info    = {
            version = State.version,
        }
    }
end

local Exp

local function expSplit(list, start, finish, level)
    if start == finish then
        return list[start]
    end
    local info = Exp[level]
    if not info then
        return
    end
    local func = info[1]
    return func(list, start, finish, level)
end

local function binaryForward(list, start, finish, level)
    local info = Exp[level]
    for i = finish-1, start+1, -1 do
        local op = list[i]
        local opType = op.type
        if info[opType] then
            local e1 = expSplit(list, start, i-1, level)
            if not e1 then
                goto CONTINUE
            end
            local e2 = expSplit(list, i+1, finish, level+1)
            if not e2 then
                goto CONTINUE
            end
            checkOpVersion(op)
            return {
                type   = 'binary',
                op     = op,
                start  = e1.start,
                finish = e2.finish,
                [1]    = e1,
                [2]    = e2,
            }
        end
        ::CONTINUE::
    end
    return expSplit(list, start, finish, level+1)
end

local function binaryBackward(list, start, finish, level)
    local info = Exp[level]
    for i = start+1, finish-1 do
        local op = list[i]
        local opType = op.type
        if info[opType] then
            local e1 = expSplit(list, start, i-1, level+1)
            if not e1 then
                goto CONTINUE
            end
            local e2 = expSplit(list, i+1, finish, level)
            if not e2 then
                goto CONTINUE
            end
            checkOpVersion(op)
            return {
                type   = 'binary',
                op     = op,
                start  = e1.start,
                finish = e2.finish,
                [1]    = e1,
                [2]    = e2,
            }
        end
        ::CONTINUE::
    end
    return expSplit(list, start, finish, level+1)
end

local function unary(list, start, finish, level)
    local info = Exp[level]
    local op = list[start]
    local opType = op.type
    if info[opType] then
        local e1 = expSplit(list, start+1, finish, level)
        if e1 then
            checkOpVersion(op)
            return {
                type   = 'unary',
                op     = op,
                start  = op.start,
                finish = e1.finish,
                [1]    = e1,
            }
        end
    end
    return expSplit(list, start, finish, level+1)
end

local function checkMissEnd(start)
    if not State.MissEndErr then
        return
    end
    local err = State.MissEndErr
    State.MissEndErr = nil
    local _, finish = State.lua:find('[%w_]+', start)
    if not finish then
        return
    end
    err.info.related = { start, finish }
    PushError {
        type   = 'MISS_END',
        start  = start,
        finish = finish,
    }
end

local function getSelect(vararg, index)
    return {
        type   = 'select',
        vararg = vararg,
        index  = index,
    }
end

local function getValue(values, i)
    if not values then
        return nil, nil
    end
    local value = values[i]
    if not value then
        local last = values[#values]
        if not last then
            return nil, nil
        end
        if last.type == 'call' or last.type == 'varargs' then
            return getSelect(last, i - #values + 1)
        end
        return nil, nil
    end
    if value.type == 'call' or value.type == 'varargs' then
        value = getSelect(value, 1)
    end
    return value
end

local function createLocal(key, effect, value, attrs)
    if not key then
        return nil
    end
    key.type   = 'local'
    key.effect = effect
    key.value  = value
    key.attrs  = attrs
    return key
end

local function createCall(args, start, finish)
    if args then
        args.type    = 'callargs'
        args.start   = start
        args.finish  = finish
    end
    return {
        type   = 'call',
        start  = start,
        finish = finish,
        args   = args,
    }
end

local function packList(start, list, finish)
    local lastFinish = start
    local wantName = true
    local count = 0
    for i = 1, #list do
        local ast = list[i]
        if ast.type == ',' then
            if wantName or i == #list then
                PushError {
                    type   = 'UNEXPECT_SYMBOL',
                    start  = ast.start,
                    finish = ast.finish,
                    info = {
                        symbol = ',',
                    }
                }
            end
            wantName = true
        else
            if not wantName then
                PushError {
                    type   = 'MISS_SYMBOL',
                    start  = lastFinish,
                    finish = ast.start - 1,
                    info = {
                        symbol = ',',
                    }
                }
            end
            wantName = false
            count = count + 1
            list[count] = list[i]
        end
        lastFinish = ast.finish + 1
    end
    for i = count + 1, #list do
        list[i] = nil
    end
    list.start = start
    list.finish = finish - 1
    return list
end

Exp = {
    {
        ['or'] = true,
        binaryForward,
    },
    {
        ['and'] = true,
        binaryForward,
    },
    {
        ['<='] = true,
        ['>='] = true,
        ['<']  = true,
        ['>']  = true,
        ['~='] = true,
        ['=='] = true,
        binaryForward,
    },
    {
        ['|'] = true,
        binaryForward,
    },
    {
        ['~'] = true,
        binaryForward,
    },
    {
        ['&'] = true,
        binaryForward,
    },
    {
        ['<<'] = true,
        ['>>'] = true,
        binaryForward,
    },
    {
        ['..'] = true,
        binaryBackward,
    },
    {
        ['+'] = true,
        ['-'] = true,
        binaryForward,
    },
    {
        ['*']  = true,
        ['//'] = true,
        ['/']  = true,
        ['%']  = true,
        binaryForward,
    },
    {
        ['^'] = true,
        binaryBackward,
    },
    {
        ['not'] = true,
        ['#']   = true,
        ['~']   = true,
        ['-']   = true,
        unary,
    },
}

local Defs = {
    Nil = function (pos)
        return {
            type   = 'nil',
            start  = pos,
            finish = pos + 2,
        }
    end,
    True = function (pos)
        return {
            type   = 'boolean',
            start  = pos,
            finish = pos + 3,
            [1]    = true,
        }
    end,
    False = function (pos)
        return {
            type   = 'boolean',
            start  = pos,
            finish = pos + 4,
            [1]    = false,
        }
    end,
    LongComment = function (beforeEq, afterEq, str, missPos)
        if missPos then
            local endSymbol = ']' .. ('='):rep(afterEq-beforeEq) .. ']'
            local s, _, w = str:find('(%][%=]*%])[%c%s]*$')
            if s then
                PushError {
                    type   = 'ERR_LCOMMENT_END',
                    start  = missPos - #str + s - 1,
                    finish = missPos - #str + s + #w - 2,
                    info   = {
                        symbol = endSymbol,
                    },
                    fix    = {
                        title = 'FIX_LCOMMENT_END',
                        {
                            start  = missPos - #str + s - 1,
                            finish = missPos - #str + s + #w - 2,
                            text   = endSymbol,
                        }
                    },
                }
            end
            PushError {
                type   = 'MISS_SYMBOL',
                start  = missPos,
                finish = missPos,
                info   = {
                    symbol = endSymbol,
                },
                fix    = {
                    title = 'ADD_LCOMMENT_END',
                    {
                        start  = missPos,
                        finish = missPos,
                        text   = endSymbol,
                    }
                },
            }
        end
    end,
    CLongComment = function (start1, finish1, start2, finish2)
        PushError {
            type   = 'ERR_C_LONG_COMMENT',
            start  = start1,
            finish = finish2 - 1,
            fix    = {
                title = 'FIX_C_LONG_COMMENT',
                {
                    start  = start1,
                    finish = finish1 - 1,
                    text   = '--[[',
                },
                {
                    start  = start2,
                    finish = finish2 - 1,
                    text   =  '--]]'
                },
            }
        }
    end,
    CCommentPrefix = function (start, finish)
        PushError {
            type   = 'ERR_COMMENT_PREFIX',
            start  = start,
            finish = finish - 1,
            fix    = {
                title = 'FIX_COMMENT_PREFIX',
                {
                    start  = start,
                    finish = finish - 1,
                    text   = '--',
                },
            }
        }
    end,
    String = function (start, quote, str, finish)
        return {
            type   = 'string',
            start  = start,
            finish = finish - 1,
            [1]    = str,
            [2]    = quote,
        }
    end,
    LongString = function (beforeEq, afterEq, str, missPos)
        if missPos then
            local endSymbol = ']' .. ('='):rep(afterEq-beforeEq) .. ']'
            local s, _, w = str:find('(%][%=]*%])[%c%s]*$')
            if s then
                PushError {
                    type   = 'ERR_LSTRING_END',
                    start  = missPos - #str + s - 1,
                    finish = missPos - #str + s + #w - 2,
                    info   = {
                        symbol = endSymbol,
                    },
                    fix    = {
                        title = 'FIX_LSTRING_END',
                        {
                            start  = missPos - #str + s - 1,
                            finish = missPos - #str + s + #w - 2,
                            text   = endSymbol,
                        }
                    },
                }
            end
            PushError {
                type   = 'MISS_SYMBOL',
                start  = missPos,
                finish = missPos,
                info   = {
                    symbol = endSymbol,
                },
                fix    = {
                    title = 'ADD_LSTRING_END',
                    {
                        start  = missPos,
                        finish = missPos,
                        text   = endSymbol,
                    }
                },
            }
        end
        return '[' .. ('='):rep(afterEq-beforeEq) .. '[', str
    end,
    Char10 = function (char)
        char = tonumber(char)
        if not char or char < 0 or char > 255 then
            return ''
        end
        return stringChar(char)
    end,
    Char16 = function (pos, char)
        if State.version == 'Lua 5.1' then
            PushError {
                type = 'ERR_ESC',
                start = pos-1,
                finish = pos,
                version = {'Lua 5.2', 'Lua 5.3', 'Lua 5.4', 'LuaJIT'},
                info = {
                    version = State.version,
                }
            }
            return char
        end
        return stringChar(tonumber(char, 16))
    end,
    CharUtf8 = function (pos, char)
        if  State.version ~= 'Lua 5.3'
        and State.version ~= 'Lua 5.4'
        and State.version ~= 'LuaJIT'
        then
            PushError {
                type = 'ERR_ESC',
                start = pos-3,
                finish = pos-2,
                version = {'Lua 5.3', 'Lua 5.4', 'LuaJIT'},
                info = {
                    version = State.version,
                }
            }
            return char
        end
        if #char == 0 then
            PushError {
                type = 'UTF8_SMALL',
                start = pos-3,
                finish = pos,
            }
            return ''
        end
        local v = tonumber(char, 16)
        if not v then
            for i = 1, #char do
                if not tonumber(char:sub(i, i), 16) then
                    PushError {
                        type = 'MUST_X16',
                        start = pos + i - 1,
                        finish = pos + i - 1,
                    }
                end
            end
            return ''
        end
        if State.version == 'Lua 5.4' then
            if v < 0 or v > 0x7FFFFFFF then
                PushError {
                    type = 'UTF8_MAX',
                    start = pos-3,
                    finish = pos+#char,
                    info = {
                        min = '00000000',
                        max = '7FFFFFFF',
                    }
                }
            end
        else
            if v < 0 or v > 0x10FFFF then
                PushError {
                    type = 'UTF8_MAX',
                    start = pos-3,
                    finish = pos+#char,
                    version = v <= 0x7FFFFFFF and 'Lua 5.4' or nil,
                    info = {
                        min = '000000',
                        max = '10FFFF',
                    }
                }
            end
        end
        if v >= 0 and v <= 0x10FFFF then
            return utf8Char(v)
        end
        return ''
    end,
    Number = function (start, number, finish)
        local n = tonumber(number)
        if n then
            State.LastNumber = {
                type   = 'number',
                start  = start,
                finish = finish - 1,
                [1]    = n,
            }
            return State.LastNumber
        else
            PushError {
                type   = 'MALFORMED_NUMBER',
                start  = start,
                finish = finish - 1,
            }
            State.LastNumber = {
                type   = 'number',
                start  = start,
                finish = finish - 1,
                [1]    = 0,
            }
            return State.LastNumber
        end
    end,
    FFINumber = function (start, symbol)
        local lastNumber = State.LastNumber
        if mathType(lastNumber[1]) == 'float' then
            PushError {
                type = 'UNKNOWN_SYMBOL',
                start = start,
                finish = start + #symbol - 1,
                info = {
                    symbol = symbol,
                }
            }
            lastNumber[1] = 0
            return
        end
        if State.version ~= 'LuaJIT' then
            PushError {
                type = 'UNSUPPORT_SYMBOL',
                start = start,
                finish = start + #symbol - 1,
                version = 'LuaJIT',
                info = {
                    version = State.version,
                }
            }
            lastNumber[1] = 0
        end
    end,
    ImaginaryNumber = function (start, symbol)
        local lastNumber = State.LastNumber
        if State.version ~= 'LuaJIT' then
            PushError {
                type = 'UNSUPPORT_SYMBOL',
                start = start,
                finish = start + #symbol - 1,
                version = 'LuaJIT',
                info = {
                    version = State.version,
                }
            }
        end
        lastNumber[1] = 0
    end,
    Name = function (start, str, finish)
        local isKeyWord
        if RESERVED[str] then
            isKeyWord = true
        elseif str == 'goto' then
            if State.version ~= 'Lua 5.1' and State.version ~= 'LuaJIT' then
                isKeyWord = true
            end
        end
        if isKeyWord then
            PushError {
                type = 'KEYWORD',
                start = start,
                finish = finish - 1,
            }
        end
        return {
            type   = 'name',
            start  = start,
            finish = finish - 1,
            [1]    = str,
        }
    end,
    GetField = function (dot, field)
        if field then
            field.type = 'field'
        end
        return {
            type   = 'getfield',
            field  = field,
            dot    = dot,
            start  = dot.start,
            finish = (field or dot).finish,
        }
    end,
    GetIndex = function (start, index, finish)
        return {
            type   = 'getindex',
            start  = start,
            finish = finish - 1,
            index  = index,
        }
    end,
    GetMethod = function (colon, method)
        if method then
            method.type = 'method'
        end
        return {
            type   = 'getmethod',
            method = method,
            colon  = colon,
            start  = colon.start,
            finish = (method or colon).finish,
        }
    end,
    Single = function (unit)
        unit.type  = 'getname'
        return unit
    end,
    Simple = function (units)
        local last = units[1]
        for i = 2, #units do
            local current  = units[i]
            current.node = last
            current.start  = last.start
            last = units[i]
        end
        return last
    end,
    SimpleCall = function (call)
        if call.type ~= 'call' and call.type ~= 'getmethod' then
            PushError {
                type   = 'EXP_IN_ACTION',
                start  = call.start,
                finish = call.finish,
            }
        end
        return call
    end,
    BinaryOp = function (start, op)
        return {
            type   = op,
            start  = start,
            finish = start + #op - 1,
        }
    end,
    UnaryOp = function (start, op)
        return {
            type   = op,
            start  = start,
            finish = start + #op - 1,
        }
    end,
    Exp = function (first, ...)
        if not ... then
            return first
        end
        local list = {first, ...}
        return expSplit(list, 1, #list, 1)
    end,
    Paren = function (start, exp, finish)
        if exp and exp.type == 'paren' then
            exp.start  = start
            exp.finish = finish - 1
            return exp
        end
        return {
            type   = 'paren',
            start  = start,
            finish = finish - 1,
            exp    = exp
        }
    end,
    VarArgs = function (dots)
        dots.type = 'varargs'
        return dots
    end,
    PackLoopArgs = function (start, list, finish)
        local list = packList(start, list, finish)
        if #list == 0 then
            PushError {
                type   = 'MISS_LOOP_MIN',
                start  = finish,
                finish = finish,
            }
        elseif #list == 1 then
            PushError {
                type   = 'MISS_LOOP_MAX',
                start  = finish,
                finish = finish,
            }
        end
        return list
    end,
    PackInNameList = function (start, list, finish)
        local list = packList(start, list, finish)
        if #list == 0 then
            PushError {
                type   = 'MISS_NAME',
                start  = start,
                finish = finish,
            }
        end
        return list
    end,
    PackInExpList = function (start, list, finish)
        local list = packList(start, list, finish)
        if #list == 0 then
            PushError {
                type   = 'MISS_EXP',
                start  = start,
                finish = finish,
            }
        end
        return list
    end,
    PackExpList = function (start, list, finish)
        local list = packList(start, list, finish)
        return list
    end,
    PackNameList = function (start, list, finish)
        local list = packList(start, list, finish)
        return list
    end,
    Call = function (start, args, finish)
        return createCall(args, start, finish-1)
    end,
    COMMA = function (start)
        return {
            type   = ',',
            start  = start,
            finish = start,
        }
    end,
    SEMICOLON = function (start)
        return {
            type   = ';',
            start  = start,
            finish = start,
        }
    end,
    DOTS = function (start)
        return {
            type   = '...',
            start  = start,
            finish = start + 2,
        }
    end,
    COLON = function (start)
        return {
            type   = ':',
            start  = start,
            finish = start,
        }
    end,
    DOT = function (start)
        return {
            type   = '.',
            start  = start,
            finish = start,
        }
    end,
    Function = function (start, args, actions, finish)
        actions.type   = 'function'
        actions.start  = start
        actions.finish = finish - 1
        actions.args   = args
        checkMissEnd(start)
        return actions
    end,
    NamedFunction = function (start, name, args, actions, finish)
        actions.type   = 'function'
        actions.start  = start
        actions.finish = finish - 1
        actions.args   = args
        checkMissEnd(start)
        if not name then
            return
        end
        if name.type == 'getname' then
            name.type = 'setname'
            name.value = actions
            return name
        elseif name.type == 'getfield' then
            name.type = 'setfield'
            name.value = actions
            return name
        elseif name.type == 'getmethod' then
            name.type = 'setmethod'
            name.value = actions
            return name
        end
    end,
    LocalFunction = function (start, name, args, actions, finish)
        actions.type   = 'function'
        actions.start  = start
        actions.finish = finish - 1
        actions.args   = args
        checkMissEnd(start)

        if not name then
            return
        end

        if name.type ~= 'getname' then
            PushError {
                type = 'UNEXPECT_LFUNC_NAME',
                start = name.start,
                finish = name.finish,
            }
            return
        end

        local loc = createLocal(name, start, actions)

        return loc
    end,
    Table = function (start, tbl, finish)
        tbl.type   = 'table'
        tbl.start  = start
        tbl.finish = finish - 1
        local wantField = true
        local lastStart = start + 1
        local fieldCount = 0
        for i = 1, #tbl do
            local field = tbl[i]
            if field.type == ',' or field.type == ';' then
                if wantField then
                    PushError {
                        type = 'MISS_EXP',
                        start = lastStart,
                        finish = field.start - 1,
                    }
                end
                wantField = true
                lastStart = field.finish + 1
            else
                if not wantField then
                    PushError {
                        type = 'MISS_SEP_IN_TABLE',
                        start = lastStart,
                        finish = field.start - 1,
                    }
                end
                wantField = false
                lastStart = field.finish + 1
                fieldCount = fieldCount + 1
                tbl[fieldCount] = field
            end
        end
        for i = fieldCount + 1, #tbl do
            tbl[i] = nil
        end
        return tbl
    end,
    NewField = function (start, field, value, finish)
        field.type = 'field'
        return {
            type   = 'tablefield',
            start  = start,
            finish = finish-1,
            field  = field,
            value  = value,
        }
    end,
    Index = function (start, index, finish)
        return {
            type   = 'index',
            start  = start,
            finish = finish - 1,
            index  = index,
        }
    end,
    NewIndex = function (start, index, value, finish)
        return {
            type   = 'tableindex',
            start  = start,
            finish = finish-1,
            index  = index,
            value  = value,
        }
    end,
    FuncArgs = function (start, args, finish)
        args.type   = 'funcargs'
        args.start  = start
        args.finish = finish - 1
        local lastStart = start + 1
        local wantName = true
        local argCount = 0
        for i = 1, #args do
            local arg = args[i]
            local argAst = arg
            if argAst.type == ',' then
                if wantName then
                    PushError {
                        type = 'MISS_NAME',
                        start = lastStart,
                        finish = argAst.start-1,
                    }
                end
                wantName = true
            else
                if not wantName then
                    PushError {
                        type = 'MISS_SYMBOL',
                        start = lastStart-1,
                        finish = argAst.start-1,
                        info = {
                            symbol = ',',
                        }
                    }
                end
                wantName = false
                argCount = argCount + 1

                if argAst.type == '...' then
                    args[argCount] = arg
                    if i < #args then
                        local a = args[i+1]
                        local b = args[#args]
                        PushError {
                            type   = 'ARGS_AFTER_DOTS',
                            start  = a.start,
                            finish = b.finish,
                        }
                    end
                    break
                else
                    args[argCount] = createLocal(arg, arg.start)
                end
            end
            lastStart = argAst.finish + 1
        end
        for i = argCount + 1, #args do
            args[i] = nil
        end
        if wantName and argCount > 0 then
            PushError {
                type   = 'MISS_NAME',
                start  = lastStart,
                finish = finish - 1,
            }
        end
        return args
    end,
    Set = function (start, keys, values, finish)
        for i = 1, #keys do
            local key = keys[i]
            if key.type == 'getname' then
                key.type = 'setname'
                key.value = getValue(values, i)
            elseif key.type == 'getfield' then
                key.type = 'setfield'
                key.value = getValue(values, i)
            end
        end
        return tableUnpack(keys)
    end,
    LocalAttr = function (attrs)
        for i = 1, #attrs do
            local attr = attrs[i]
            local attrAst = attr
            attrAst.type = 'localattr'
            if State.version ~= 'Lua 5.4' then
                PushError {
                    type    = 'UNSUPPORT_SYMBOL',
                    start   = attrAst.start,
                    finish  = attrAst.finish,
                    version = 'Lua 5.4',
                    info    = {
                        version = State.version,
                    }
                }
            elseif attrAst[1] ~= 'const' and attrAst[1] ~= 'close' then
                PushError {
                    type   = 'UNKNOWN_TAG',
                    start  = attrAst.start,
                    finish = attrAst.finish,
                    info   = {
                        tag = attrAst[1],
                    }
                }
            elseif i > 1 then
                PushError {
                    type   = 'MULTI_TAG',
                    start  = attrAst.start,
                    finish = attrAst.finish,
                    info   = {
                        tag = attrAst[1],
                    }
                }
            end
        end
        return attrs
    end,
    LocalName = function (name, attrs)
        if not name then
            return name
        end
        name.attrs = attrs
        return name
    end,
    Local = function (start, keys, values, finish)
        for i = 1, #keys do
            local key = keys[i]
            local attrs = key.attrs
            key.attrs = nil
            local value = getValue(values, i)
            createLocal(key, finish, value, attrs)
        end
        return tableUnpack(keys)
    end,
    Do = function (start, actions, finish)
        actions.type = 'do'
        actions.start  = start
        actions.finish = finish - 1
        checkMissEnd(start)
        return actions
    end,
    Break = function (start, finish)
        return {
            type   = 'break',
            start  = start,
            finish = finish - 1,
        }
    end,
    Return = function (start, exps, finish)
        exps.type   = 'return'
        exps.start  = start
        exps.finish = finish - 1
        return exps
    end,
    Label = function (start, name, finish)
        if State.version == 'Lua 5.1' then
            PushError {
                type   = 'UNSUPPORT_SYMBOL',
                start  = start,
                finish = finish - 1,
                version = {'Lua 5.2', 'Lua 5.3', 'Lua 5.4', 'LuaJIT'},
                info = {
                    version = State.version,
                }
            }
            return
        end
        if not name then
            return nil
        end
        name.type = 'label'
        return name
    end,
    GoTo = function (start, name, finish)
        if State.version == 'Lua 5.1' then
            PushError {
                type    = 'UNSUPPORT_SYMBOL',
                start   = start,
                finish  = finish - 1,
                version = {'Lua 5.2', 'Lua 5.3', 'Lua 5.4', 'LuaJIT'},
                info = {
                    version = State.version,
                }
            }
            return
        end
        if not name then
            return nil
        end
        name.type = 'goto'
        return name
    end,
    IfBlock = function (start, exp, actions, finish)
        actions.type   = 'ifblock'
        actions.start  = start
        actions.finish = finish - 1
        actions.filter = exp
        return actions
    end,
    ElseIfBlock = function (start, exp, actions, finish)
        actions.type   = 'elseifblock'
        actions.start  = start
        actions.finish = finish - 1
        actions.filter = exp
        return actions
    end,
    ElseBlock = function (start, actions, finish)
        actions.type   = 'elseblock'
        actions.start  = start
        actions.finish = finish - 1
        return actions
    end,
    If = function (start, blocks, finish)
        blocks.type   = 'if'
        blocks.start  = start
        blocks.finish = finish - 1
        local hasElse
        for i = 1, #blocks do
            local block = blocks[i]
            if i == 1 and block.type ~= 'ifblock' then
                PushError {
                    type = 'MISS_SYMBOL',
                    start = block.start,
                    finish = block.start,
                    info = {
                        symbol = 'if',
                    }
                }
            end
            if hasElse then
                PushError {
                    type   = 'BLOCK_AFTER_ELSE',
                    start  = block.start,
                    finish = block.finish,
                }
            end
            if block.type == 'elseblock' then
                hasElse = true
            end
        end
        checkMissEnd(start)
        return blocks
    end,
    Loop = function (start, arg, steps, blockStart, block, finish)
        local loc = createLocal(arg, blockStart, steps[1])
        block.type   = 'loop'
        block.start  = start
        block.finish = finish - 1
        block.loc    = loc
        block.max    = steps[2]
        block.step   = steps[3]
        checkMissEnd(start)
        return block
    end,
    In = function (start, keys, exp, blockStart, block, finish)
        local func = tableRemove(exp, 1)
        block.type   = 'in'
        block.start  = start
        block.finish = finish - 1
        block.keys = {}

        local values
        if func then
            local call = createCall(exp, func.finish + 1, exp.finish)
            call.node = func
            values = { call }
        end
        for i = 1, #keys do
            local loc = keys[i]
            if values then
                block.keys[i] = createLocal(loc, blockStart, getValue(values, i))
            else
                block.keys[i] = createLocal(loc, blockStart)
            end
        end
        checkMissEnd(start)
        return block
    end,
    While = function (start, filter, block, finish)
        block.type   = 'while'
        block.start  = start
        block.finish = finish - 1
        block.filter = filter
        checkMissEnd(start)
        return block
    end,
    Repeat = function (start, block, filter, finish)
        block.type   = 'repeat'
        block.start  = start
        block.finish = finish
        block.filter = filter
        return block
    end,
    Lua = function (start, actions, finish)
        actions.type   = 'main'
        actions.start  = start
        actions.finish = finish - 1
        return actions
    end,

    -- 捕获错误
    UnknownSymbol = function (start, symbol)
        PushError {
            type = 'UNKNOWN_SYMBOL',
            start = start,
            finish = start + #symbol - 1,
            info = {
                symbol = symbol,
            }
        }
        return
    end,
    UnknownAction = function (start, symbol)
        PushError {
            type = 'UNKNOWN_SYMBOL',
            start = start,
            finish = start + #symbol - 1,
            info = {
                symbol = symbol,
            }
        }
    end,
    DirtyName = function (pos)
        PushError {
            type = 'MISS_NAME',
            start = pos,
            finish = pos,
        }
        return nil
    end,
    DirtyExp = function (pos)
        PushError {
            type = 'MISS_EXP',
            start = pos,
            finish = pos,
        }
        return nil
    end,
    MissExp = function (pos)
        PushError {
            type = 'MISS_EXP',
            start = pos,
            finish = pos,
        }
    end,
    MissExponent = function (start, finish)
        PushError {
            type = 'MISS_EXPONENT',
            start = start,
            finish = finish - 1,
        }
    end,
    MissQuote1 = function (pos)
        PushError {
            type = 'MISS_SYMBOL',
            start = pos,
            finish = pos,
            info = {
                symbol = '"'
            }
        }
    end,
    MissQuote2 = function (pos)
        PushError {
            type = 'MISS_SYMBOL',
            start = pos,
            finish = pos,
            info = {
                symbol = "'"
            }
        }
    end,
    MissEscX = function (pos)
        PushError {
            type = 'MISS_ESC_X',
            start = pos-2,
            finish = pos+1,
        }
    end,
    MissTL = function (pos)
        PushError {
            type = 'MISS_SYMBOL',
            start = pos,
            finish = pos,
            info = {
                symbol = '{',
            }
        }
    end,
    MissTR = function (pos)
        PushError {
            type = 'MISS_SYMBOL',
            start = pos,
            finish = pos,
            info = {
                symbol = '}',
            }
        }
    end,
    MissBR = function (pos)
        PushError {
            type = 'MISS_SYMBOL',
            start = pos,
            finish = pos,
            info = {
                symbol = ']',
            }
        }
    end,
    MissPL = function (pos)
        PushError {
            type = 'MISS_SYMBOL',
            start = pos,
            finish = pos,
            info = {
                symbol = '(',
            }
        }
    end,
    MissPR = function (pos)
        PushError {
            type = 'MISS_SYMBOL',
            start = pos,
            finish = pos,
            info = {
                symbol = ')',
            }
        }
    end,
    ErrEsc = function (pos)
        PushError {
            type = 'ERR_ESC',
            start = pos-1,
            finish = pos,
        }
    end,
    MustX16 = function (pos, str)
        PushError {
            type = 'MUST_X16',
            start = pos,
            finish = pos + #str - 1,
        }
    end,
    MissAssign = function (pos)
        PushError {
            type = 'MISS_SYMBOL',
            start = pos,
            finish = pos,
            info = {
                symbol = '=',
            }
        }
    end,
    MissTableSep = function (pos)
        PushError {
            type = 'MISS_SYMBOL',
            start = pos,
            finish = pos,
            info = {
                symbol = ','
            }
        }
    end,
    MissField = function (pos)
        PushError {
            type = 'MISS_FIELD',
            start = pos,
            finish = pos,
        }
    end,
    MissMethod = function (pos)
        PushError {
            type = 'MISS_METHOD',
            start = pos,
            finish = pos,
        }
    end,
    MissLabel = function (pos)
        PushError {
            type = 'MISS_SYMBOL',
            start = pos,
            finish = pos,
            info = {
                symbol = '::',
            }
        }
    end,
    MissEnd = function (pos)
        State.MissEndErr = PushError {
            type = 'MISS_SYMBOL',
            start = pos,
            finish = pos,
            info = {
                symbol = 'end',
            }
        }
    end,
    MissDo = function (pos)
        PushError {
            type = 'MISS_SYMBOL',
            start = pos,
            finish = pos,
            info = {
                symbol = 'do',
            }
        }
    end,
    MissComma = function (pos)
        PushError {
            type = 'MISS_SYMBOL',
            start = pos,
            finish = pos,
            info = {
                symbol = ',',
            }
        }
    end,
    MissIn = function (pos)
        PushError {
            type = 'MISS_SYMBOL',
            start = pos,
            finish = pos,
            info = {
                symbol = 'in',
            }
        }
    end,
    MissUntil = function (pos)
        PushError {
            type = 'MISS_SYMBOL',
            start = pos,
            finish = pos,
            info = {
                symbol = 'until',
            }
        }
    end,
    MissThen = function (pos)
        PushError {
            type = 'MISS_SYMBOL',
            start = pos,
            finish = pos,
            info = {
                symbol = 'then',
            }
        }
    end,
    MissName = function (pos)
        PushError {
            type = 'MISS_NAME',
            start = pos,
            finish = pos,
        }
    end,
    ExpInAction = function (start, exp, finish)
        PushError {
            type = 'EXP_IN_ACTION',
            start = start,
            finish = finish - 1,
        }
        return exp
    end,
    MissIf = function (start, block)
        PushError {
            type = 'MISS_SYMBOL',
            start = start,
            finish = start,
            info = {
                symbol = 'if',
            }
        }
        return block
    end,
    MissGT = function (start)
        PushError {
            type = 'MISS_SYMBOL',
            start = start,
            finish = start,
            info = {
                symbol = '>'
            }
        }
    end,
    ErrAssign = function (start, finish)
        PushError {
            type = 'ERR_ASSIGN_AS_EQ',
            start = start,
            finish = finish - 1,
            fix = {
                title = 'FIX_ASSIGN_AS_EQ',
                {
                    start   = start,
                    finish  = finish - 1,
                    text    = '=',
                }
            }
        }
    end,
    ErrEQ = function (start, finish)
        PushError {
            type   = 'ERR_EQ_AS_ASSIGN',
            start  = start,
            finish = finish - 1,
            fix = {
                title = 'FIX_EQ_AS_ASSIGN',
                {
                    start  = start,
                    finish = finish - 1,
                    text   = '==',
                }
            }
        }
        return '=='
    end,
    ErrUEQ = function (start, finish)
        PushError {
            type   = 'ERR_UEQ',
            start  = start,
            finish = finish - 1,
            fix = {
                title = 'FIX_UEQ',
                {
                    start  = start,
                    finish = finish - 1,
                    text   = '~=',
                }
            }
        }
        return '=='
    end,
    ErrThen = function (start, finish)
        PushError {
            type = 'ERR_THEN_AS_DO',
            start = start,
            finish = finish - 1,
            fix = {
                title = 'FIX_THEN_AS_DO',
                {
                    start   = start,
                    finish  = finish - 1,
                    text    = 'then',
                }
            }
        }
    end,
    ErrDo = function (start, finish)
        PushError {
            type = 'ERR_DO_AS_THEN',
            start = start,
            finish = finish - 1,
            fix = {
                title = 'FIX_DO_AS_THEN',
                {
                    start   = start,
                    finish  = finish - 1,
                    text    = 'do',
                }
            }
        }
    end,
}

--for k, v in pairs(emmy.ast) do
--    Defs[k] = v
--end

local function init(state)
    State     = state
    PushError = state.pushError
    emmy.init(State)
end

local function close()
    State     = nil
    PushError = nil
end

return {
    defs  = Defs,
    init  = init,
    close = close,
}
