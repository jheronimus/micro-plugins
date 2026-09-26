VERSION = "0.6.4"

local micro = import("micro")
local config = import("micro/config")
local shell = import("micro/shell")
local util = import("micro/util")
local fmt = import("fmt")
local go_os = import("os")

cmd = {}
currentAction = {}
capabilities = {}
rootUri = ""
splitBP = nil

local id = {}

function init()
	-- register all configuration options
	config.RegisterCommonOption("lsp", "server", "")
	config.RegisterCommonOption("lsp", "formatOnSave", false)
	config.RegisterCommonOption("lsp", "autocompleteDetails", false)
	config.RegisterCommonOption("lsp", "ignoreMessages", "")
	config.RegisterCommonOption("lsp", "tabcompletion", true)
	config.RegisterCommonOption("lsp", "ignoreTriggerCharacters", "completion")

	-- example to ignore all LSP server message starting with these strings:
	-- "lsp.ignoreMessages": "Skipping analyzing |See https://"

	-- define all commands added to Micro
	defineActions()

	-- add help documentation
	config.AddRuntimeFile("lsp", config.RTHelp, "help/lsp.md")
end

function parseOptions(inputstr)
	return mysplit(inputstr, ",")
end

local binCache = {}

local function isBinaryInstalled(bin)
	if binCache[bin] ~= nil then
		return binCache[bin]
	end
	local _, err = shell.ExecCommand("which", bin)
	local installed = err == nil
	binCache[bin] = installed
	return installed
end

local function pickServerFromCandidates(filetype)
	local candidates = defaultServers[filetype]
	if not candidates then
		return nil
	end
	for _, cand in ipairs(candidates) do
		local run = mysplit(cand, "%s")
		local runCmd = run[1]
		if runCmd and isBinaryInstalled(runCmd) then
			return cand
		end
	end
	return nil
end

local function findExplicitServer(filetype)
	local envSettings, _ = go_os.Getenv("MICRO_LSP")
	local settings = envSettings or config.GetGlobalOption("lsp.server")
	if settings and #settings > 0 then
		for _, entry in ipairs(parseOptions(settings)) do
			local part = mysplit(entry, "=")
			if filetype == part[1] then
				return part
			end
		end
	end
	return nil
end

local function decodeArgs(args)
	for idx, narg in ipairs(args) do
		args[idx] = narg:gsub("%%[a-zA-Z0-9][a-zA-Z0-9]", function(entry)
			return string.char(tonumber(entry:sub(2), 16))
		end)
	end
	return args
end

local function launchServer(part, filetype, callback, targetBuf)
	local run = mysplit(part[2] or "", "%s")
	local initOptions = config.GetGlobalOption("lsp." .. part[1]) or part[3] or "{}"
	local runCmd = table.remove(run, 1)
	local args = decodeArgs(run)
	local send = withSend(part[1])
	if cmd[part[1]] ~= nil then
		return
	end
	id[part[1]] = 0
	micro.Log("Starting server", part[1])
	cmd[part[1]] = shell.JobSpawn(runCmd, args, onStdout(part[1]), onStderr, onExit(part[1]), {})
	currentAction[part[1]] = {
		method = "initialize",
		response = function(bp, data)
			send("initialized", "{}", true)
			capabilities[filetype] = data.result and data.result.capabilities or {}
			local b = targetBuf
			if b == nil and bp ~= nil then
				b = bp.Buf
			end
			if b ~= nil then
				callback(b, filetype)
			end
		end,
	}
	send(
		currentAction[part[1]].method,
		fmt.Sprintf(
			'{"processId": %.0f, "rootUri": "%s", "workspaceFolders": [{"name": "root", "uri": "%s"}], "initializationOptions": %s, "capabilities": {"textDocument": {"hover": {"contentFormat": ["plaintext", "markdown"]}, "publishDiagnostics": {"relatedInformation": false, "versionSupport": false, "codeDescriptionSupport": true, "dataSupport": true}, "signatureHelp": {"signatureInformation": {"documentationFormat": ["plaintext", "markdown"]}}}}}',
			go_os.Getpid(),
			rootUri,
			rootUri,
			initOptions
		)
	)
end

function startServer(filetype, callback, targetBuf)
	local wd, _ = go_os.Getwd()
	rootUri = fmt.Sprintf("file://%s", wd)

	local explicit = findExplicitServer(filetype)
	if explicit then
		launchServer(explicit, filetype, callback, targetBuf)
		return
	end

	local detected = pickServerFromCandidates(filetype)
	if detected then
		launchServer({ filetype, detected }, filetype, callback, targetBuf)
	end
end

function withSend(filetype)
	return function(method, params, isNotification)
		if cmd[filetype] == nil then
			return
		end

		micro.Log(filetype .. ">>> " .. method)
		local msg = fmt.Sprintf(
			'{"jsonrpc": "2.0", %s"method": "%s", "params": %s}',
			not isNotification and fmt.Sprintf('"id": %.0f, ', id[filetype]) or "",
			method,
			params
		)
		id[filetype] = id[filetype] + 1
		msg = fmt.Sprintf("Content-Length: %.0f\r\n\r\n%s", #msg, msg)
		micro.Log(msg)
		shell.JobSend(cmd[filetype], msg)
	end
end

function handleInitialized(buf, filetype)
	if cmd[filetype] == nil then
		return
	end
	micro.Log("Found running lsp server for ", filetype, "firing textDocument/didOpen...")
	local send = withSend(filetype)
	local uri = getUriFromBuf(buf)
	local content = util.String(buf:Bytes())
		:gsub("\\", "\\\\")
		:gsub("\n", "\\n")
		:gsub("\r", "\\r")
		:gsub('"', '\\"')
		:gsub("\t", "\\t")
	send(
		"textDocument/didOpen",
		fmt.Sprintf(
			'{"textDocument": {"uri": "%s", "languageId": "%s", "version": 1, "text": "%s"}}',
			uri,
			filetype,
			content
		),
		true
	)
end

function isIgnoredMessage(msg)
	-- Return true if msg matches one of the ignored starts of messages
	-- Useful for linters that show spurious, hard to disable warnings
	local ignoreList = mysplit(config.GetGlobalOption("lsp.ignoreMessages"), "|")
	for _, ignore in pairs(ignoreList) do
		if string.match(msg, ignore) then -- match from start of string
			micro.Log("Ignore message: '", msg, "', because it matched: '", ignore, "'.")
			return true -- ignore this message, dont show to user
		end
	end
	return false -- show this message to user
end
