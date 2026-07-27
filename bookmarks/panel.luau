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

local currentFolder = nil -- nil = root, else index into `bookmarks` of the open folder
local editMode = false -- when true, rows show reorder/edit/delete controls

local draftKind = "bookmark" -- "bookmark" | "folder", set when the form opens
local draftGlyph = "bookmark"
local draftLabel = ""
local draftCmd = ""
local draftError = nil
local editingIndex = nil -- nil = creating new, number = editing the entry at that index in the active list
local editingRoot = false -- true when editingIndex refers to `bookmarks` (root) instead of activeList()

-- Returns the array we're currently viewing/editing: root, or the open
-- folder's items. Falls back to root if currentFolder points at something
-- that's gone (e.g. deleted from under us).
local function activeList()
	if currentFolder == nil then
		return bookmarks
	end
	local folder = bookmarks[currentFolder]
	if folder == nil or folder.type ~= "folder" then
		currentFolder = nil
		return bookmarks
	end
	folder.items = folder.items or {}
	return folder.items
end

local function entryType(entry)
	return entry.type == "folder" and "folder" or "bookmark"
end

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
		listError = noctalia.tr("err_read_failed", { error = tostring(readErr) })
		return
	end
	local decoded, decodeErr = noctalia.json.decode(raw)
	if type(decoded) ~= "table" then
		bookmarks = {}
		listError = noctalia.tr("err_corrupt", { error = tostring(decodeErr) })
		return
	end
	bookmarks = decoded
	listError = nil
end

local function saveBookmarks()
	if path == nil then
		return false, noctalia.tr("err_no_data_dir")
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

-- Swaps the entry at `index` with its neighbor in `direction` (-1 up, 1
-- down) within the given list, then persists. No-ops silently at the
-- edges or on write failure (rolled back).
local function moveEntry(list, index, direction)
	local target = index + direction
	if target < 1 or target > #list then
		return
	end
	list[index], list[target] = list[target], list[index]
	local ok, err = saveBookmarks()
	if not ok then
		list[index], list[target] = list[target], list[index]
		noctalia.notifyError(
			noctalia.tr("title"),
			noctalia.tr("err_reorder_failed", { error = err })
		)
		return
	end
end

-- Runs a bookmark's command. Two distinct failure paths get a notification:
-- the shell couldn't even be spawned, or it ran and exited non-zero.
-- Success stays silent, same as file-search's xdg-open.
local function runBookmark(entry)
	local cmd = entry.cmd
	if type(cmd) ~= "string" or cmd == "" then
		noctalia.notifyError(noctalia.tr("title"), noctalia.tr("err_no_command"))
		return
	end
	local label = entry.label or cmd
	local ok = noctalia.runAsync(cmd, function(result)
		if result.exitCode ~= 0 then
			local detail = noctalia.string.trim(result.stderr or "")
			local msg =
				noctalia.tr("err_exit_code", { label = label, code = tostring(result.exitCode) })
			if detail ~= "" then
				msg = msg .. ": " .. detail
			end
			noctalia.notifyError(noctalia.tr("title"), msg)
		end
		-- exitCode == 0: succeeded, no notification
	end)
	if not ok then
		noctalia.notifyError(
			noctalia.tr("title"),
			noctalia.tr("err_launch_failed", { label = label })
		)
	end
end

local function reorderArrows(index, total)
	return ui.column({ gap = 2, width = 16 }, {
		ui.button({
			glyph = "chevron-up",
			variant = "ghost",
			glyphSize = 10,
			width = 16,
			height = 15,
			enabled = index > 1,
			tooltip = noctalia.tr("move_up_tooltip"),
			onClick = function()
				onMoveEntry(index, -1)
			end,
		}),
		ui.button({
			glyph = "chevron-down",
			variant = "ghost",
			glyphSize = 10,
			width = 16,
			height = 15,
			enabled = index < total,
			tooltip = noctalia.tr("move_down_tooltip"),
			onClick = function()
				onMoveEntry(index, 1)
			end,
		}),
	})
end

local function entryRow(entry, index, total)
	local isFolder = entryType(entry) == "folder"

	local trailing = {}
	if isFolder then
		table.insert(
			trailing,
			ui.button({
				glyph = "chevron-right",
				variant = "ghost",
				controlSize = "sm",
				tooltip = noctalia.tr("open_tooltip"),
				onClick = function()
					onOpenFolder(index)
				end,
			})
		)
	elseif editMode then
		trailing = {
			ui.button({
				glyph = "pencil",
				variant = "secondary",
				controlSize = "sm",
				tooltip = noctalia.tr("edit_tooltip"),
				onClick = function()
					onEditEntry(index)
				end,
			}),
			ui.button({
				glyph = "trash",
				variant = "destructive",
				controlSize = "sm",
				tooltip = noctalia.tr("delete_tooltip"),
				onClick = function()
					onDeleteEntry(index)
				end,
			}),
		}
	end

	local rowChildren = {}
	if editMode then
		table.insert(rowChildren, reorderArrows(index, total))
	end

	table.insert(
		rowChildren,
		ui.row({
			gap = 8,
			align = "center",
			flexGrow = 1,
			onClick = function()
				if isFolder then
					onOpenFolder(index)
				else
					runBookmark(entry)
					onClose()
					noctalia.togglePanel(PANEL_ID)
				end
			end,
		}, {
			ui.glyph({
				name = entry.glyph or (isFolder and "folder" or "bookmark"),
				size = 16,
				color = "on_surface",
			}),
			ui.label({
				text = entry.label or "",
				fontSize = 13,
				color = "on_surface",
				flexGrow = 1,
				maxLines = 1,
			}),
		})
	)

	for _, node in ipairs(trailing) do
		table.insert(rowChildren, node)
	end

	return ui.row({ key = "bm-" .. index, gap = 8, align = "center" }, rowChildren)
end

local function listView()
	local list = activeList()
	local children = {}

	if currentFolder ~= nil then
		local folder = bookmarks[currentFolder]
		table.insert(
			children,
			ui.row({ gap = 8, align = "center" }, {
				ui.button({
					glyph = "chevron-left",
					variant = "ghost",
					controlSize = "sm",
					tooltip = noctalia.tr("back_button"),
					onClick = "onBackToRoot",
				}),
				ui.row({
					gap = 6,
					align = "center",
					flexGrow = 1,
					onClick = "onEditFolderHeader",
				}, {
					ui.glyph({
						name = "pencil",
						size = 13,
						color = "on_surface_variant",
					}),
					ui.label({
						text = (folder and folder.label) or "",
						fontSize = 13,
						fontWeight = "bold",
						color = "on_surface",
						flexGrow = 1,
						maxLines = 1,
					}),
				}),
			})
		)
	end

	local topButtons = {
		ui.button({
			key = "new-bookmark",
			text = noctalia.tr("new_bookmark"),
			glyph = "plus",
			variant = "primary",
			flexGrow = 1,
			enabled = path ~= nil,
			onClick = "onNewBookmark",
		}),
	}
	-- Folders can only be created at root: one level of nesting only. The
	-- button is omitted entirely inside a folder, rather than just disabled,
	-- since nesting isn't a supported concept here at all.
	if currentFolder == nil then
		table.insert(
			topButtons,
			ui.button({
				key = "new-folder",
				text = noctalia.tr("new_folder"),
				glyph = "folder-plus",
				variant = "secondary",
				flexGrow = 1,
				enabled = path ~= nil,
				onClick = "onNewFolder",
			})
		)
	end
	table.insert(
		topButtons,
		ui.button({
			key = "toggle-edit-mode",
			glyph = editMode and "eye" or "eye-off",
			variant = "ghost",
			controlSize = "sm",
			width = 32,
			tooltip = noctalia.tr(editMode and "hide_controls_tooltip" or "show_controls_tooltip"),
			onClick = "onToggleEditMode",
		})
	)
	table.insert(children, ui.row({ gap = 8 }, topButtons))

	if listError ~= nil then
		table.insert(children, ui.label({ text = listError, color = "error", fontSize = 12 }))
	elseif #list == 0 then
		table.insert(
			children,
			ui.label({
				text = noctalia.tr("no_bookmarks"),
				color = "on_surface_variant",
				fontSize = 12,
			})
		)
	else
		local rows = {}
		for index, entry in ipairs(list) do
			table.insert(rows, entryRow(entry, index, #list))
		end
		table.insert(children, ui.scroll({ flexGrow = 1, gap = 4 }, rows))
	end

	if currentFolder ~= nil then
		table.insert(
			children,
			ui.button({
				key = "delete-folder",
				text = noctalia.tr("delete_folder_button"),
				glyph = "trash",
				variant = "destructive",
				onClick = "onDeleteFolder",
			})
		)
	end

	return ui.column({ gap = 10, padding = 14, flexGrow = 1 }, children)
end

local function formView()
	local isFolder = draftKind == "folder"
	local title
	if editingIndex ~= nil then
		title = isFolder and noctalia.tr("edit_folder") or noctalia.tr("edit_bookmark")
	else
		title = isFolder and noctalia.tr("new_folder") or noctalia.tr("new_bookmark")
	end

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
				name = draftGlyph ~= "" and draftGlyph or (isFolder and "folder" or "bookmark"),
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
			placeholder = isFolder and noctalia.tr("folder_name_field")
				or noctalia.tr("label_field"),
			controlSize = "sm",
			focus = true,
			onChange = "onLabelChange",
		}),
	}

	if not isFolder then
		table.insert(
			children,
			ui.input({
				key = "cmd-input-" .. formRev,
				value = draftCmd,
				placeholder = noctalia.tr("cmd_field"),
				controlSize = "sm",
				onChange = "onCmdChange",
			})
		)
	end

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

function onNewBookmark()
	editingIndex = nil
	editingRoot = false
	draftKind = "bookmark"
	draftGlyph = "bookmark"
	draftLabel = ""
	draftCmd = ""
	draftError = nil
	formRev += 1
	view = "new"
	render()
end

function onNewFolder()
	-- Folders are root-only (one level of nesting), so this should be
	-- unreachable while inside a folder, but guard anyway since it's
	-- reached via a button click, not just render-time gating.
	if currentFolder ~= nil then
		return
	end
	editingIndex = nil
	editingRoot = false
	draftKind = "folder"
	draftGlyph = "folder"
	draftLabel = ""
	draftCmd = ""
	draftError = nil
	formRev += 1
	view = "new"
	render()
end

function onOpenFolder(index)
	local list = activeList()
	local entry = list[index]
	if entry == nil or entryType(entry) ~= "folder" then
		return
	end
	-- currentFolder is only ever set from root (folders are one level deep),
	-- so `index` here is always an index into the root `bookmarks` array.
	currentFolder = index
	render()
end

function onBackToRoot()
	currentFolder = nil
	render()
end

-- Editing the currently open folder's own name/glyph: the folder entry
-- lives in root `bookmarks` at `currentFolder`, not in activeList() (which
-- is the folder's *contents*), so this goes through root explicitly.
function onEditFolderHeader()
	if currentFolder == nil then
		return
	end
	local entry = bookmarks[currentFolder]
	if entry == nil then
		return
	end
	editingIndex = currentFolder
	editingRoot = true
	draftKind = "folder"
	draftGlyph = entry.glyph or "folder"
	draftLabel = entry.label or ""
	draftCmd = ""
	draftError = nil
	formRev += 1
	view = "new"
	render()
end

function onDeleteFolder()
	if currentFolder == nil then
		return
	end
	local entry = bookmarks[currentFolder]
	if entry == nil or entryType(entry) ~= "folder" then
		return
	end

	local removed = table.remove(bookmarks, currentFolder)
	if removed == nil then
		return
	end
	local ok, err = saveBookmarks()
	if not ok then
		table.insert(bookmarks, currentFolder, removed)
		noctalia.notifyError(
			noctalia.tr("title"),
			noctalia.tr("err_delete_failed", { error = err })
		)
		render()
		return
	end

	noctalia.notify(
		noctalia.tr("title"),
		noctalia.tr("folder_deleted", { label = removed.label or "" })
	)
	currentFolder = nil
	render()
end

function onEditEntry(index)
	local list = activeList()
	editingRoot = false
	local entry = list[index]
	if entry == nil then
		return
	end
	editingIndex = index
	draftKind = entryType(entry)
	draftGlyph = entry.glyph or (draftKind == "folder" and "folder" or "bookmark")
	draftLabel = entry.label or ""
	draftCmd = entry.cmd or ""
	draftError = nil
	formRev += 1
	view = "new"
	render()
end

function onCancelBookmark()
	editingIndex = nil
	editingRoot = false
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
	local glyph = noctalia.string.trim(draftGlyph)
	local isFolder = draftKind == "folder"

	if label == "" then
		draftError = noctalia.tr(isFolder and "err_label_required" or "err_label_cmd_required")
		render()
		return
	end

	local cmd = nil
	if not isFolder then
		cmd = noctalia.string.trim(draftCmd)
		if cmd == "" then
			draftError = noctalia.tr("err_label_cmd_required")
			render()
			return
		end
	end

	if glyph == "" then
		glyph = isFolder and "folder" or "bookmark"
	end

	local list = editingRoot and bookmarks or activeList()
	local newEntry
	if isFolder then
		local previousItems = nil
		if editingIndex ~= nil then
			local existing = list[editingIndex]
			previousItems = existing and existing.items or nil
		end
		newEntry = { type = "folder", glyph = glyph, label = label, items = previousItems or {} }
	else
		newEntry = { type = "bookmark", glyph = glyph, label = label, cmd = cmd }
	end

	local previous = nil
	if editingIndex ~= nil then
		previous = list[editingIndex]
		list[editingIndex] = newEntry
	else
		table.insert(list, newEntry)
	end

	local ok, err = saveBookmarks()
	if not ok then
		-- roll back the in-memory change on write failure
		if editingIndex ~= nil then
			list[editingIndex] = previous
		else
			table.remove(list)
		end
		draftError = noctalia.tr("err_save_failed", { error = err })
		render()
		return
	end

	noctalia.notify(
		noctalia.tr("title"),
		noctalia.tr(editingIndex ~= nil and "entry_updated" or "entry_saved", { label = label })
	)
	editingIndex = nil
	editingRoot = false
	view = "list"
	render()
end

function onToggleEditMode()
	editMode = not editMode
	render()
end

function onMoveEntry(index, direction)
	local list = activeList()
	moveEntry(list, index, direction)
	render()
end

function onDeleteEntry(index)
	local list = activeList()
	local entry = list[index]
	if entry == nil then
		return
	end
	if entryType(entry) == "folder" and #(entry.items or {}) > 0 then
		-- Deleting a non-empty folder takes its contents with it; the row's
		-- delete button has no separate confirm dialog available (panels
		-- have no native modal), so this is a same-click destructive action
		-- same as bookmark delete. Surfaced via notification after the fact
		-- rather than blocking, to stay consistent with existing delete UX.
		noctalia.notify(
			noctalia.tr("title"),
			noctalia.tr("folder_deleted", { label = entry.label or "" })
		)
	end

	local removed = table.remove(list, index)
	if removed == nil then
		return
	end
	local ok, err = saveBookmarks()
	if not ok then
		table.insert(list, index, removed)
		noctalia.notifyError(
			noctalia.tr("title"),
			noctalia.tr("err_delete_failed", { error = err })
		)
		render()
		return
	end
	render()
end

function onOpen(_context)
	view = "list"
	editingIndex = nil
	editingRoot = false
	editMode = false
	currentFolder = nil
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
