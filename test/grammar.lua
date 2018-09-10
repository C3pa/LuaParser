require 'filesystem'
local grammar = require 'parser.grammar'

local function check_str(str, name, mode)
    local gram, err = grammar(str, mode)
    if err then
        local spc = ''
        for i = 1, err.pos - 1 do
            if err.code:sub(i, i) == '\t' then
                spc = spc .. '\t'
            else
                spc = spc .. ' '
            end
        end
        local text = ('%s\r\n%s^'):format(err.code, spc)
        local msg = ([[
%s

[%s] 第 %d 行：
===========================
%s
===========================
]]):format(err.err, err.file, err.line, text)

        error(([[
%s

[%s]测试失败:
%s
%s
%s
]]):format(
    msg,
    name,
    ('='):rep(30),
    str,
    ('='):rep(30)
))
    end
end

local function check(mode)
    return function (list)
        for i, str in ipairs(list) do
            if mode ~= 'Nl' then
                str = str:gsub('[\r\n]+$', '')
            end
            check_str(str, mode .. '-' .. i, mode)
        end
    end
end
