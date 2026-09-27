VERSION = "1.0.1"

local micro = import("micro")
local config = import("micro/config")
local shell = import("micro/shell")
local filepath = import("path/filepath")

-- Must be registered at top-level so defaults apply before buffers are created
config.RegisterCommonOption("autofmt", "onsave", true)

local binCache = {}

local function isInstalled(bin)
	if binCache[bin] ~= nil then
		return binCache[bin]
	end
	local _, err = shell.ExecCommand("which", bin)
	local installed = err == nil
	binCache[bin] = installed
	return installed
end

local function canRun(cmdItem)
	if type(cmdItem) == "table" then
		for _, subcmd in ipairs(cmdItem) do
			local bin = subcmd:match("%S+")
			if not isInstalled(bin) then
				return false
			end
		end
		return true
	end
	local bin = cmdItem:match("%S+")
	return isInstalled(bin)
end

local function resolveTool(filetype, settings)
	local opt = settings["autofmt.for-" .. filetype]
	if opt == nil then
		opt = config.GetGlobalOption("autofmt.for-" .. filetype)
	end
	if opt == "off" then
		return nil
	end
	if opt and opt ~= "" and opt ~= "auto" then
		return opt
	end

	local candidates = defaultTools[filetype]
	if not candidates then
		return nil
	end

	for _, cand in ipairs(candidates) do
		if canRun(cand) then
			return cand
		end
	end
	return nil
end

local function runSingleCmd(dirPath, filePath, cmdStr)
	local shCmd = string.format("cd %q && %s %q", dirPath, cmdStr, filePath)
	local out, err = shell.ExecCommand("sh", "-c", shCmd)
	if err ~= nil then
		local msg = out ~= "" and out or tostring(err)
		micro.InfoBar():Error("autofmt: " .. msg)
		return false
	end
	return true
end

local function executeFormat(bp, tool)
	bp:Save()
	local filePath = bp.Buf.AbsPath
	if filePath == nil or filePath == "" then
		filePath = bp.Buf.Path
	end
	local dirPath, _ = filepath.Split(filePath)
	if dirPath == "" then
		dirPath = "."
	end

	local ok = true
	if type(tool) == "table" then
		for _, cmdStr in ipairs(tool) do
			if not runSingleCmd(dirPath, filePath, cmdStr) then
				ok = false
				break
			end
		end
	else
		ok = runSingleCmd(dirPath, filePath, tool)
	end

	if ok then
		bp.Buf:ReOpen()
	end
end

local function shouldFormatOnSave(settings)
	local opt = settings["autofmt.onsave"]
	if opt == nil then
		opt = config.GetGlobalOption("autofmt.onsave")
	end
	return opt ~= false
end

function onSave(bp)
	if not shouldFormatOnSave(bp.Buf.Settings) then
		return true
	end
	local filetype = bp.Buf:FileType()
	local tool = resolveTool(filetype, bp.Buf.Settings)
	if tool then
		executeFormat(bp, tool)
	end
	return true
end

function fmtCommand(bp, args)
	local filetype = bp.Buf:FileType()
	if #args > 0 then
		executeFormat(bp, table.concat(args, " "))
		return
	end
	local tool = resolveTool(filetype, bp.Buf.Settings)
	if not tool then
		micro.InfoBar():Message("autofmt: no supported formatter found for " .. filetype)
		return
	end
	executeFormat(bp, tool)
end

function init()
	config.MakeCommand("fmt", fmtCommand, config.NoComplete)
	config.AddRuntimeFile("autofmt", config.RTHelp, "help/autofmt.md")
end
