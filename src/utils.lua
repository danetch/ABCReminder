-- This file contains utility functions that can be used throughout the addon.

local Utils = {}

function Utils.splitString(input, delimiter)
    if not input or not delimiter then return {} end
    local result = {}
    for match in (input..delimiter):gmatch("(.-)"..delimiter) do
        table.insert(result, match)
    end
    return result
end

function Utils.trimString(input)
    if not input then return nil end
    return input:match("^%s*(.-)%s*$")
end

function Utils.tableContains(table, value)
    for _, v in ipairs(table) do
        if v == value then
            return true
        end
    end
    return false
end




return Utils