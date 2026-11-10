-- Drive umbilical through Accessibility. Invoked only on macOS by verify-umbilical.
-- Usage: osascript ui.applescript <command> [args...]

on run argv
	if (count of argv) is 0 then error "usage: ui.applescript read-text|click|fill|value|checkbox|enabled|choose-folder|menu|status|frame|quit-pid"
	set command to item 1 of argv
	if command is "read-text" then
		return describeProcess()
	else if command is "click" then
		clickNamed(item 2 of argv)
		return "clicked " & item 2 of argv
	else if command is "fill" then
		fillNamed(item 2 of argv, item 3 of argv)
		return "filled " & item 2 of argv
	else if command is "value" then
		return fieldValue(item 2 of argv)
	else if command is "checkbox" then
		return checkboxValue(item 2 of argv)
	else if command is "enabled" then
		return buttonEnabled(item 2 of argv)
	else if command is "choose-folder" then
		chooseFolder(item 2 of argv)
		return "chose " & item 2 of argv
	else if command is "menu" then
		clickStatusMenuItem(item 2 of argv)
		return "menu " & item 2 of argv
	else if command is "status" then
		return statusMenuText()
	else if command is "frame" then
		return windowFrame()
	else if command is "quit-pid" then
		quitByPid(item 2 of argv)
		return "quit pid " & item 2 of argv
	else
		error "unknown ui command: " & command
	end if
end run

on quitByPid(pidText)
	set pidNum to pidText as integer
	tell application "System Events"
		set matches to every process whose unix id is pidNum
		if (count of matches) is 0 then error "process pid not found: " & pidText
		tell item 1 of matches
			set frontmost to true
			set targetItem to missing value
			repeat with bar in menu bars
				repeat with itemRef in menu bar items of bar
					set descText to ""
					set nameText to ""
					try
						set descText to description of itemRef
					end try
					try
						set nameText to name of itemRef
					end try
					if descText is "umbilical" or nameText is "umbilical" then set targetItem to itemRef
				end repeat
			end repeat
			if targetItem is missing value then error "menu bar item umbilical was not found for pid " & pidText
			click targetItem
			delay 0.3
			click menu item "Quit umbilical" of menu 1 of targetItem
		end tell
	end tell
end quitByPid

on describeProcess()
	tell application "System Events"
		if not (exists process "umbilical") then error "process umbilical is not running"
		tell process "umbilical"
			set frontmost to true
			set rows to {}
			repeat with win in windows
				set rows to collectLines(win, rows)
			end repeat
			set AppleScript's text item delimiters to linefeed
			set rendered to rows as text
			set AppleScript's text item delimiters to ""
			return rendered
		end tell
	end tell
end describeProcess

on collectLines(element, rows)
	tell application "System Events"
		set roleText to ""
		set nameText to ""
		set valueText to ""
		set enabledText to true
		try
			set roleText to role of element as text
		end try
		try
			set nameText to name of element as text
		end try
		try
			set valueText to value of element as text
		end try
		try
			set enabledText to enabled of element
		end try
		set end of rows to lineFor(roleText, nameText, valueText, enabledText)
		try
			repeat with sheetRef in (sheets of element)
				set rows to collectLines(sheetRef, rows)
			end repeat
		end try
		try
			repeat with child in (UI elements of element)
				set rows to collectLines(child, rows)
			end repeat
		end try
		return rows
	end tell
end collectLines

on lineFor(roleText, nameText, valueText, enabledText)
	set enabledWord to "enabled"
	if enabledText is false then set enabledWord to "disabled"
	return roleText & tab & nameText & tab & valueText & tab & enabledWord
end lineFor

on clickNamed(itemName)
	tell application "System Events"
		if not (exists process "umbilical") then error "process umbilical is not running"
		tell process "umbilical"
			set frontmost to true
			if (count of windows) is 0 then error "button not found: " & itemName
			if clickIn(window 1, "AXButton", itemName) then return
			error "button not found: " & itemName
		end tell
	end tell
end clickNamed

on clickIn(element, wantedRole, itemName)
	tell application "System Events"
		try
			if (role of element as text) is wantedRole then
				if (name of element as text) is itemName then
					click element
					return true
				end if
			end if
		end try
		-- Sheets sit in front of the window that owns them. A confirmation
		-- button named Remove must win over the row button of the same name.
		try
			repeat with sheetRef in (sheets of element)
				if clickIn(sheetRef, wantedRole, itemName) then return true
			end repeat
		end try
		try
			repeat with child in (UI elements of element)
				if clickIn(child, wantedRole, itemName) then return true
			end repeat
		end try
		return false
	end tell
end clickIn

on fillNamed(itemName, newValue)
	tell application "System Events"
		if not (exists process "umbilical") then error "process umbilical is not running"
		tell process "umbilical"
			set frontmost to true
			if (count of windows) is 0 then error "text field not found: " & itemName
			if writeIn(window 1, "AXTextField", itemName, newValue) then return
			if writeIn(window 1, "AXTextArea", itemName, newValue) then return
			error "text field not found: " & itemName
		end tell
	end tell
end fillNamed

on fieldValue(itemName)
	set found to readInFront("AXTextField", itemName, "value")
	if found is "MISSING" then set found to readInFront("AXTextArea", itemName, "value")
	if found is "MISSING" then error "text field not found: " & itemName
	return found
end fieldValue

on checkboxValue(itemName)
	set found to readInFront("AXCheckBox", itemName, "value")
	if found is "MISSING" then set found to readInFront("AXSwitch", itemName, "value")
	if found is "MISSING" then error "checkbox not found: " & itemName
	return found
end checkboxValue

on buttonEnabled(itemName)
	set found to readInFront("AXButton", itemName, "enabled")
	if found is "MISSING" then error "button not found: " & itemName
	return found
end buttonEnabled

on readInFront(wantedRole, itemName, mode)
	tell application "System Events"
		if not (exists process "umbilical") then error "process umbilical is not running"
		tell process "umbilical"
			set frontmost to true
			if (count of windows) is 0 then return "MISSING"
			return readIn(window 1, wantedRole, itemName, mode)
		end tell
	end tell
end readInFront

on writeIn(element, wantedRole, itemName, newValue)
	tell application "System Events"
		try
			if (role of element as text) is wantedRole then
				if (name of element as text) is itemName then
					set focused of element to true
					set value of element to newValue
					return true
				end if
			end if
		end try
		try
			repeat with sheetRef in (sheets of element)
				if writeIn(sheetRef, wantedRole, itemName, newValue) then return true
			end repeat
		end try
		try
			repeat with child in (UI elements of element)
				if writeIn(child, wantedRole, itemName, newValue) then return true
			end repeat
		end try
		return false
	end tell
end writeIn

on readIn(element, wantedRole, itemName, mode)
	tell application "System Events"
		try
			if (role of element as text) is wantedRole then
				if (name of element as text) is itemName then
					if mode is "enabled" then
						if enabled of element then return "true"
						return "false"
					end if
					return value of element as text
				end if
			end if
		end try
		try
			repeat with sheetRef in (sheets of element)
				set hit to readIn(sheetRef, wantedRole, itemName, mode)
				if hit is not "MISSING" then return hit
			end repeat
		end try
		try
			repeat with child in (UI elements of element)
				set hit to readIn(child, wantedRole, itemName, mode)
				if hit is not "MISSING" then return hit
			end repeat
		end try
		return "MISSING"
	end tell
end readIn

on chooseFolder(folderPath)
	clickNamed("Choose Folder…")
	set deadline to (current date) + 8
	repeat
		if buttonExists("Choose") then exit repeat
		if (current date) is greater than deadline then error "open panel did not show Choose"
		delay 0.2
	end repeat
	tell application "System Events"
		tell process "umbilical"
			set frontmost to true
			keystroke "g" using {command down, shift down}
			delay 0.4
			keystroke folderPath
			keystroke return
			delay 0.6
		end tell
	end tell
	clickNamed("Choose")
end chooseFolder

on buttonExists(itemName)
	set found to readInFront("AXButton", itemName, "enabled")
	if found is "MISSING" then return false
	return true
end buttonExists

on clickStatusMenuItem(itemName)
	tell application "System Events"
		if not (exists process "umbilical") then error "process umbilical is not running"
		tell process "umbilical"
			set frontmost to true
			set targetItem to missing value
			repeat with bar in menu bars
				repeat with itemRef in menu bar items of bar
					set descText to ""
					set nameText to ""
					try
						set descText to description of itemRef
					end try
					try
						set nameText to name of itemRef
					end try
					if descText is "umbilical" or nameText is "umbilical" then set targetItem to itemRef
				end repeat
			end repeat
			if targetItem is missing value then error "menu bar item umbilical was not found"
			click targetItem
			delay 0.3
			click menu item itemName of menu 1 of targetItem
		end tell
	end tell
end clickStatusMenuItem

on statusMenuText()
	tell application "System Events"
		if not (exists process "umbilical") then error "process umbilical is not running"
		tell process "umbilical"
			set frontmost to true
			set targetItem to missing value
			repeat with bar in menu bars
				repeat with itemRef in menu bar items of bar
					set descText to ""
					set nameText to ""
					try
						set descText to description of itemRef
					end try
					try
						set nameText to name of itemRef
					end try
					if descText is "umbilical" or nameText is "umbilical" then set targetItem to itemRef
				end repeat
			end repeat
			if targetItem is missing value then error "menu bar item umbilical was not found"
			click targetItem
			delay 0.3
			set rows to {}
			repeat with menuItem in menu items of menu 1 of targetItem
				try
					set end of rows to name of menuItem as text
				end try
			end repeat
			set AppleScript's text item delimiters to linefeed
			set rendered to rows as text
			set AppleScript's text item delimiters to ""
			try
				click targetItem
			end try
			return rendered
		end tell
	end tell
end statusMenuText

on windowFrame()
	tell application "System Events"
		if not (exists process "umbilical") then error "process umbilical is not running"
		tell process "umbilical"
			set frontmost to true
			set win to first window whose title is "umbilical"
			set pos to position of win
			set siz to size of win
			return (item 1 of pos as text) & "," & (item 2 of pos as text) & "," & (item 1 of siz as text) & "," & (item 2 of siz as text)
		end tell
	end tell
end windowFrame
