local micro = import("micro")
local config = import("micro/config")
local buffer = import("micro/buffer")

-- Track reader state and original settings per buffer
local readerState = {}
local origRulerState = {}
local isPrompting = {}

local function getBufKey(buf)
    if not buf then
        return nil
    end
    if buf.Path and buf.Path ~= "" then
        return buf.Path
    end
    return tostring(buf)
end

local function isMarkdown(buf)
    if not buf then
        return false
    end
    local ft = buf:FileType()
    if ft == "markdown" then
        return true
    end
    local path = buf.Path
    if path and (path:match("%.md$") or path:match("%.markdown$") or path:match("%.mkd$") or path:match("%.livemd$")) then
        return true
    end
    return false
end

local function enterReaderMode(bp)
    if not bp or not bp.Buf then
        return
    end
    local buf = bp.Buf
    local key = getBufKey(buf)

    if origRulerState[key] == nil then
        origRulerState[key] = buf.Settings["ruler"]
    end

    readerState[key] = true
    buf.Settings["readonly"] = true
    buf.Settings["ruler"] = false
    micro.InfoBar():Message("Markdown Reader Mode active (press any key to edit, or run 'readermode')")
end

local function exitReaderMode(bp)
    if not bp or not bp.Buf then
        return
    end
    local buf = bp.Buf
    local key = getBufKey(buf)

    readerState[key] = false
    buf.Settings["readonly"] = false
    if origRulerState[key] ~= nil then
        buf.Settings["ruler"] = origRulerState[key]
    else
        buf.Settings["ruler"] = true
    end
    micro.InfoBar():Message("Switched to Edit Mode")
end

local function toggleReaderMode(bp, args)
    if not bp or not bp.Buf then
        return
    end
    local buf = bp.Buf
    local key = getBufKey(buf)

    if readerState[key] then
        exitReaderMode(bp)
    else
        enterReaderMode(bp)
    end
end

local function promptExitReaderMode(bp)
    if not bp or not bp.Buf then
        return
    end
    local buf = bp.Buf
    local key = getBufKey(buf)

    if isPrompting[key] then
        return
    end
    isPrompting[key] = true

    micro.InfoBar():YNPrompt("Exit reader mode? (y/n) ", function(yes, canceled)
        isPrompting[key] = false
        if not canceled and yes then
            exitReaderMode(bp)
        end
    end)
end

function onBufPaneOpen(bp)
    if not bp or not bp.Buf then
        return
    end
    local buf = bp.Buf
    if isMarkdown(buf) then
        local autoReader = config.GetGlobalOption("markdown-reader.autoreader")
        if autoReader == nil or autoReader == true then
            enterReaderMode(bp)
        end
    end
end

function onBufferOpen(buf)
    if not buf then
        return
    end
    if isMarkdown(buf) then
        local autoReader = config.GetGlobalOption("markdown-reader.autoreader")
        if autoReader == nil or autoReader == true then
            local key = getBufKey(buf)
            readerState[key] = true
            buf.Settings["readonly"] = true
        end
    end
end

function preRune(bp, rune)
    if not bp or not bp.Buf then
        return false
    end
    local buf = bp.Buf
    local key = getBufKey(buf)
    if readerState[key] then
        promptExitReaderMode(bp)
        return true
    end
    return false
end

local function checkEditAction(bp)
    if not bp or not bp.Buf then
        return false
    end
    local buf = bp.Buf
    local key = getBufKey(buf)
    if readerState[key] then
        promptExitReaderMode(bp)
        return true
    end
    return false
end

function preInsertNewline(bp)
    return checkEditAction(bp)
end

function preBackspace(bp)
    return checkEditAction(bp)
end

function preDelete(bp)
    return checkEditAction(bp)
end

function preCut(bp)
    return checkEditAction(bp)
end

function preCutLine(bp)
    return checkEditAction(bp)
end

function prePaste(bp)
    return checkEditAction(bp)
end

function preInsertTab(bp)
    return checkEditAction(bp)
end

function preIndentSelection(bp)
    return checkEditAction(bp)
end

function preOutdentSelection(bp)
    return checkEditAction(bp)
end

function preOutdentLine(bp)
    return checkEditAction(bp)
end

function statusInfo(buf)
    if not buf then
        return ""
    end
    local key = getBufKey(buf)
    if readerState[key] then
        return "[READER]"
    end
    if isMarkdown(buf) then
        return "[EDIT]"
    end
    return ""
end

function init()
    config.RegisterCommonOption("markdown-reader", "autoreader", true)
    config.MakeCommand("readermode", toggleReaderMode, buffer.NoComplete)
    config.MakeCommand("reader", toggleReaderMode, buffer.NoComplete)
    config.SetStatusInfoFn("markdown-reader.statusInfo")
end
