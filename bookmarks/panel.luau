local PANEL_ID = "dunarand/bookmarks:panel"

local dataDir, dataDirErr = noctalia.pluginDataDir()
if dataDir == nil then
	noctalia.log("bookmarks: pluginDataDir failed: " .. tostring(dataDirErr))
end
local path = dataDir and (dataDir .. "/data.json") or nil

local view = "list" -- "list" | "new"
local formRev = 0

local bookmarks = {}
local listError = nil

local draftGlyph = "bookmark"
local draftLabel = ""
local draftCmd = ""
local draftError = nil
local editingIndex = nil -- nil = creating new, number = editing bookmarks[editingIndex]

local function loadBookmarks()
	if path == nil then
		bookmarks = {}
		return
	end
	if not noctalia.fileExists(path) then
		bookmarks = {}
		listError = nil
		return
	end
	local raw, readErr = noctalia.readFile(path)
	if raw == nil then
		bookmarks = {}
		listError = "Failed to read bookmarks: " .. tostring(readErr)
		return
	end
	local decoded, decodeErr = noctalia.json.decode(raw)
	if type(decoded) ~= "table" then
		bookmarks = {}
		listError = "Bookmarks file is corrupt: " .. tostring(decodeErr)
		return
	end
	bookmarks = decoded
	listError = nil
end

local function saveBookmarks()
	if path == nil then
		return false, "No data directory available"
	end
	local encoded, encodeErr = noctalia.json.encode(bookmarks)
	if encoded == nil then
		return false, tostring(encodeErr)
	end
	local ok, writeErr = noctalia.writeFile(path, encoded)
	if not ok then
		return false, tostring(writeErr)
	end
	return true, nil
end

function onKey(chord, _)
	if chord == "enter" then
		execCmd()
	elseif chord == "up" or chord == "ctrl+p" then
		prevItem()
	elseif chord == "down" or chord == "ctrl+n" then
		nextItem()
	end
end

function execCmd() end

function nextItem() end

function prevItem() end

-- Runs a bookmark's command. Two distinct failure paths get a notification:
-- the shell couldn't even be spawned, or it ran and exited non-zero/timed out.
-- Success stays silent, same as file-search's xdg-open.
local function runBookmark(entry)
	local cmd = entry.cmd
	if type(cmd) ~= "string" or cmd == "" then
		noctalia.notifyError("Bookmarks", "This bookmark has no command")
		return
	end
	local label = entry.label or cmd
	local ok = noctalia.runAsync(cmd, function(result)
		if result.exitCode ~= 0 then
			local detail = noctalia.string.trim(result.stderr or "")
			local msg = '"' .. label .. '" exited with code ' .. tostring(result.exitCode)
			if detail ~= "" then
				msg = msg .. ": " .. detail
			end
			noctalia.notifyError("Bookmarks", msg)
		end
		-- exitCode == 0: succeeded, no notification
	end)
	if not ok then
		noctalia.notifyError("Bookmarks", 'Failed to launch "' .. label .. '"')
	end
end

local function bookmarkRow(entry, index)
	return ui.row({ key = "bm-" .. index, gap = 8, align = "center" }, {
		ui.row({
			gap = 8,
			align = "center",
			flexGrow = 1,
			onClick = function()
				runBookmark(entry)
				onClose()
				noctalia.togglePanel(PANEL_ID)
			end,
			onRightClick = function()
				noctalia.notify(tostring(index), "")
			end,
			onMiddleClick = function()
				onDeleteBookmark(index)
			end,
		}, {
			ui.glyph({ name = entry.glyph or "bookmark", size = 16, color = "on_surface" }),
			ui.label({
				text = entry.label or "",
				fontSize = 13,
				color = "on_surface",
				flexGrow = 1,
				maxLines = 1,
			}),
		}),
		ui.button({
			glyph = "pencil",
			variant = "secondary",
			controlSize = "sm",
			tooltip = noctalia.tr("edit_tooltip"),
			onClick = function()
				onEditBookmark(index)
			end,
		}),
		ui.button({
			glyph = "trash",
			variant = "destructive",
			controlSize = "sm",
			tooltip = noctalia.tr("delete_tooltip"),
			onClick = function()
				onDeleteBookmark(index)
			end,
		}),
	})
end

local function listView()
	local children = {
		ui.button({
			key = "new-bookmark",
			text = noctalia.tr("new_bookmark"),
			glyph = "plus",
			variant = "primary",
			enabled = path ~= nil,
			onClick = "_onNewBookmark",
		}),
	}

	if listError ~= nil then
		table.insert(children, ui.label({ text = listError, color = "error", fontSize = 12 }))
	elseif #bookmarks == 0 then
		table.insert(
			children,
			ui.label({
				text = "No bookmarks yet",
				color = "on_surface_variant",
				fontSize = 12,
			})
		)
	else
		local rows = {}
		for index, entry in ipairs(bookmarks) do
			table.insert(rows, bookmarkRow(entry, index))
		end
		table.insert(children, ui.scroll({ flexGrow = 1, gap = 4 }, rows))
	end

	return ui.column({ gap = 10, padding = 14, flexGrow = 1 }, children)
end

local function formView()
	local title = (editingIndex ~= nil and noctalia.tr("edit_bookmark"))
		or noctalia.tr("new_bookmark")
	local children = {
		ui.row({ align = "center", justify = "space_between" }, {
			ui.label({
				text = title,
				fontSize = 15,
				fontWeight = "bold",
				color = "on_surface",
				flexGrow = 1,
			}),
			ui.button({
				glyph = "close",
				variant = "ghost",
				tooltip = noctalia.tr("cancel_button"),
				onClick = "onCancelBookmark",
			}),
		}),

		ui.row({ gap = 8, align = "center" }, {
			ui.glyph({
				name = draftGlyph ~= "" and draftGlyph or "bookmark",
				size = 18,
				color = "primary",
			}),
			ui.input({
				key = "glyph-input-" .. formRev,
				value = draftGlyph,
				placeholder = noctalia.tr("glyph_field"),
				controlSize = "sm",
				flexGrow = 1,
				onChange = "onGlyphChange",
			}),
		}),

		ui.input({
			key = "label-input-" .. formRev,
			value = draftLabel,
			placeholder = noctalia.tr("label_field"),
			controlSize = "sm",
			focus = true,
			onChange = "onLabelChange",
		}),

		ui.input({
			key = "cmd-input-" .. formRev,
			value = draftCmd,
			placeholder = noctalia.tr("cmd_field"),
			controlSize = "sm",
			onChange = "onCmdChange",
		}),
	}

	if draftError ~= nil then
		table.insert(children, ui.label({ text = draftError, color = "error", fontSize = 12 }))
	end

	table.insert(
		children,
		ui.row({ gap = 8, justify = "end" }, {
			ui.button({
				text = noctalia.tr("save_button"),
				variant = "primary",
				onClick = "onSaveBookmark",
			}),
            ui.button({
                text = noctalia.tr("cancel_button"),
                variant = "destructive",
                onClick = "onCancelBookmark",
            }),
		})
	)

	return ui.column({ gap = 10, padding = 14 }, children)
end

function render()
	if view == "new" then
		panel.render(formView())
	else
		panel.render(listView())
	end
end

function _onNewBookmark()
	editingIndex = nil
	draftGlyph = "bookmark"
	draftLabel = ""
	draftCmd = ""
	draftError = nil
	formRev += 1
	view = "new"
	render()
end

function onEditBookmark(index)
	local entry = bookmarks[index]
	if entry == nil then
		return
	end
	editingIndex = index
	draftGlyph = entry.glyph or "bookmark"
	draftLabel = entry.label or ""
	draftCmd = entry.cmd or ""
	draftError = nil
	formRev += 1
	view = "new"
	render()
end

function onCancelBookmark()
	editingIndex = nil
	view = "list"
	render()
end

function onGlyphChange(value)
	draftGlyph = value
end

function onLabelChange(value)
	draftLabel = value
end

function onCmdChange(value)
	draftCmd = value
end

function onSaveBookmark()
	local label = noctalia.string.trim(draftLabel)
	local cmd = noctalia.string.trim(draftCmd)
	local glyph = noctalia.string.trim(draftGlyph)

	if label == "" or cmd == "" then
		draftError = "Label and command are required"
		render()
		return
	end
	if glyph == "" then
		glyph = "bookmark"
	end

	local newEntry = { glyph = glyph, label = label, cmd = cmd }
	local previous = nil

	if editingIndex ~= nil then
		previous = bookmarks[editingIndex]
		bookmarks[editingIndex] = newEntry
	else
		table.insert(bookmarks, newEntry)
	end

	local ok, err = saveBookmarks()
	if not ok then
		-- roll back the in-memory change on write failure
		if editingIndex ~= nil then
			bookmarks[editingIndex] = previous
		else
			table.remove(bookmarks)
		end
		draftError = "Failed to save: " .. err
		render()
		return
	end

	noctalia.notify(
		"Bookmarks",
		(editingIndex ~= nil and "Updated" or "Saved") .. ' bookmark "' .. label .. '"'
	)
	editingIndex = nil
	view = "list"
	render()
end

function onDeleteBookmark(index)
	local removed = table.remove(bookmarks, index)
	if removed == nil then
		return
	end
	local ok, err = saveBookmarks()
	if not ok then
		table.insert(bookmarks, index, removed)
		noctalia.notifyError("Bookmarks", "Failed to delete: " .. err)
		render()
		return
	end
	render()
end

function onOpen(_context)
	view = "list"
	editingIndex = nil
	loadBookmarks()
	noctalia.state.set("bookmarks_open", true)
	render()
end

function onClose()
	noctalia.state.set("bookmarks_open", false)
end

function update()
	render()
end
