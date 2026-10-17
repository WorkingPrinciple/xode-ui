-- SPDX-License-Identifier: GPL-3.0-only
on run arguments
    if (count of arguments) is not 1 then error "Usage: exact-owned-app-PID"
    set ownedPID to (item 1 of arguments) as integer
    tell application "System Events"
        set ownedProcesses to every application process whose unix id is ownedPID
        if (count of ownedProcesses) is not 1 then error "Exact owned process unavailable."
        set ownedProcess to item 1 of ownedProcesses
        if bundle identifier of ownedProcess is not "io.github.dragoshont.xodus.development" then error "Unexpected bundle identity."
        if (count of windows of ownedProcess) is not 1 then error "Refusing Settings while another owned window is open."
        set mainWindow to window "Xodus" of ownedProcess
        if (count of sheets of mainWindow) is not 0 then error "Refusing Settings during a modal flow."
        set frontmost of ownedProcess to true
        if not frontmost of ownedProcess then error "Exact owned app is not foreground."
        keystroke "," using command down
        set settingsWindows to {}
        repeat 30 times
            set settingsWindows to every window of ownedProcess whose name is "Xodus Settings" or name is "Settings"
            if (count of settingsWindows) is 1 then exit repeat
            delay 0.1
        end repeat
        if (count of settingsWindows) is not 1 then error "Exact native Settings window unavailable."
        set settingsWindow to item 1 of settingsWindows
        set previewButton to my identifiedButton(settingsWindow, "xodus.diagnostics.preview")
        if not enabled of previewButton then error "Diagnostic preview is disabled."
        click previewButton
        set saveButton to missing value
        repeat 50 times
            set saveButton to my optionalIdentifiedButton(settingsWindow, "xodus.diagnostics.save")
            if saveButton is not missing value then exit repeat
            delay 0.1
        end repeat
        if saveButton is missing value then error "Reviewed diagnostic summary did not arrive."
        if not enabled of saveButton then error "Diagnostic save is disabled."
        click saveButton
        set saveWindows to {}
        repeat 20 times
            set saveWindows to every window of ownedProcess whose name is "Save reviewed diagnostic summary"
            if (count of saveWindows) is 1 then exit repeat
            delay 0.1
        end repeat
        if (count of saveWindows) is not 1 then error "Exact owned diagnostic save panel unavailable."
        set saveWindow to item 1 of saveWindows
        set elements to entire contents of saveWindow
        if (count of elements) > 3000 then error "Diagnostic save panel accessibility bound exceeded."
        set cancelButtons to {}
        repeat with element in elements
            if role of element is "AXButton" then
                repeat with fieldName in {"AXTitle", "AXDescription"}
                    if exists attribute (fieldName as text) of element then
                        if value of attribute (fieldName as text) of element is "Cancel" then
                            set end of cancelButtons to contents of element
                            exit repeat
                        end if
                    end if
                end repeat
            end if
        end repeat
        if (count of cancelButtons) is not 1 then error "Exact native save cancellation unavailable."
        click item 1 of cancelButtons
        repeat 20 times
            if not (exists window "Save reviewed diagnostic summary" of ownedProcess) then exit repeat
            delay 0.1
        end repeat
        if exists window "Save reviewed diagnostic summary" of ownedProcess then error "Diagnostic save panel did not close."
        if not (exists attribute "AXCloseButton" of settingsWindow) then error "Exact Settings close control unavailable."
        click (value of attribute "AXCloseButton" of settingsWindow)
        log "Reviewed counts-only summary/save-panel cancellation passed; no destination selected."
    end tell
end run

on identifiedButton(ownedWindow, identifier)
    set matchedButton to my optionalIdentifiedButton(ownedWindow, identifier)
    if matchedButton is missing value then error "Exact native diagnostic control unavailable."
    return matchedButton
end identifiedButton

on optionalIdentifiedButton(ownedWindow, identifier)
    tell application "System Events"
        set elements to entire contents of ownedWindow
        if (count of elements) > 3000 then error "Settings accessibility bound exceeded."
        set matches to {}
        repeat with element in elements
            if exists attribute "AXIdentifier" of element then
                if value of attribute "AXIdentifier" of element is identifier then
                    if role of element is not "AXButton" then error "Diagnostic identifier is not an actionable button."
                    set end of matches to contents of element
                end if
            end if
        end repeat
        if (count of matches) > 1 then error "Ambiguous native diagnostic control."
        if (count of matches) is 1 then return item 1 of matches
    end tell
    return missing value
end optionalIdentifiedButton
