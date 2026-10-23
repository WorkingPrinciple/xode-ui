-- SPDX-License-Identifier: GPL-3.0-only
on run arguments
    if (count of arguments) is not 2 then error "Usage: exact-owned-app-PID snapshot|Library|Discover|Downloads|Account|CheckStatus|CloseAccount|SearchHalo|More|InspectCancel"
    set ownedPID to (item 1 of arguments) as integer
    set requestedAction to item 2 of arguments
    if requestedAction is not in {"snapshot", "Library", "Discover", "Downloads", "Account", "CheckStatus", "CloseAccount", "SearchHalo", "More", "InspectCancel"} then error "Unsupported action."
    set navigationIDs to {"xodus.navigation.library", "xodus.navigation.discover", "xodus.navigation.downloads", "xodus.account", "xodus.account.checkStatus", "xodus.account.close", "xodus.catalog.search", "xodus.catalog.loadMore", "xodus.library.inspectFolder"}
    set safeLabels to {"Library", "Discover", "Downloads", "Account", "Your Library", "Registered on this Mac", "Live Xodus connection - development build", "Xodus for Mac - development build", "Connect your Xodus engine", "Check your saved sign-in or sign in with Microsoft. Public browsing does not read your Keychain.", "Sign in with Microsoft", "Sign-in needs attention", "Microsoft Store search results", "PC Game Pass discovery", "No Store matches", "Search stopped"}
    tell application "System Events"
        set ownedProcesses to every application process whose unix id is ownedPID
        if (count of ownedProcesses) is not 1 then error "Exact owned process unavailable."
        set ownedProcess to item 1 of ownedProcesses
        if bundle identifier of ownedProcess is not "io.github.dragoshont.xodus.development" then error "Unexpected bundle identity."
        set ownedWindows to every window of ownedProcess whose name is "Xodus"
        if (count of ownedWindows) is not 1 then error "Expected exactly one normal, non-fixture Xodus window."
        set ownedWindow to item 1 of ownedWindows
        set elements to entire contents of ownedWindow
        if (count of elements) > 3000 then error "Accessibility bound exceeded."
        set navigationMatches to {}
        repeat with element in elements
            set identifier to ""
            if exists attribute "AXIdentifier" of element then
                set identifier to value of attribute "AXIdentifier" of element
            end if
            if identifier is not in navigationIDs and role of element is "AXRadioButton" then
                set identifier to my nativeNavigationIdentifier(element)
            end if
            if identifier is in navigationIDs then
                if identifier is "xodus.catalog.search" then
                    if role of element is not "AXTextField" then error "Search identifier is not a native text field."
                else if identifier is in {"xodus.navigation.library", "xodus.navigation.discover", "xodus.navigation.downloads"} then
                    if role of element is not in {"AXButton", "AXRadioButton"} then error "Navigation target is not a native button or segment."
                else
                    if role of element is not "AXButton" then error "Navigation identifier is not an actionable button."
                end if
                log ("navigation=" & identifier & " role=" & role of element)
                if requestedAction is not "snapshot" and identifier is my targetIdentifier(requestedAction) then
                    set end of navigationMatches to contents of element
                end if
            end if
            repeat with fieldName in {"AXTitle", "AXDescription", "AXValue"}
                if exists attribute (fieldName as text) of element then
                    set labelValue to value of attribute (fieldName as text) of element
                    if class of labelValue is text and labelValue is in safeLabels then log ("safe-label=" & labelValue)
                end if
            end repeat
        end repeat
        if requestedAction is not "snapshot" then
            if requestedAction is "InspectCancel" and (count of navigationMatches) is 0 then
                set scrollAreas to {}
                repeat with element in elements
                    if role of element is "AXScrollArea" then set end of scrollAreas to contents of element
                end repeat
                if (count of scrollAreas) is not 1 then error "Exact owned Library scroll area unavailable."
                set ownedScrollArea to item 1 of scrollAreas
                if not (exists attribute "AXVerticalScrollBar" of ownedScrollArea) then error "Owned Library vertical scroll unavailable."
                set ownedScrollBar to value of attribute "AXVerticalScrollBar" of ownedScrollArea
                if ownedScrollBar is missing value then error "Owned Library vertical scroll unavailable."
                set value of attribute "AXValue" of ownedScrollBar to 1.0
                delay 0.2
                set elements to entire contents of ownedWindow
                if (count of elements) > 3000 then error "Accessibility bound exceeded after scroll."
                repeat with element in elements
                    if exists attribute "AXIdentifier" of element then
                        if value of attribute "AXIdentifier" of element is "xodus.library.inspectFolder" then
                            if role of element is not "AXButton" then error "Inspection identifier is not an actionable native button."
                            set end of navigationMatches to contents of element
                        end if
                    end if
                end repeat
            end if
            if (count of navigationMatches) is not 1 then error "Exact navigation target unavailable; refusing blind interaction."
            set navigationTarget to item 1 of navigationMatches
            if not enabled of navigationTarget then error "Navigation target is disabled."
            if requestedAction is "InspectCancel" then
                if (count of windows of ownedProcess) is not 1 or (count of sheets of ownedWindow) is not 0 then error "Refusing inspection while another window or sheet is open."
                click navigationTarget
                set pickerWindows to {}
                repeat 20 times
                    set pickerWindows to every window of ownedProcess whose name is "Inspect a game folder"
                    if (count of pickerWindows) is 1 then exit repeat
                    delay 0.1
                end repeat
                if (count of pickerWindows) is not 1 then error "Exact owned folder picker unavailable."
                set pickerWindow to item 1 of pickerWindows
                set pickerElements to entire contents of pickerWindow
                if (count of pickerElements) > 3000 then error "Folder picker accessibility bound exceeded."
                set cancelButtons to {}
                repeat with element in pickerElements
                    if my isNamedButton(element, "Cancel") then set end of cancelButtons to contents of element
                end repeat
                if (count of cancelButtons) is not 1 then error "Exact native cancellation unavailable; no directory will be selected."
                if not enabled of item 1 of cancelButtons then error "Native cancellation is disabled."
                click item 1 of cancelButtons
                repeat 20 times
                    if not (exists window "Inspect a game folder" of ownedProcess) then exit repeat
                    delay 0.1
                end repeat
                if exists window "Inspect a game folder" of ownedProcess then error "Native folder picker did not close."
            else if requestedAction is "SearchHalo" then
                if (count of sheets of ownedWindow) is not 0 then error "Refusing search while a modal sheet is open."
                if value of attribute "AXDescription" of navigationTarget is not "Search Microsoft Store games" then error "Expected public Store search scope."
                if value of attribute "AXValue" of navigationTarget is not "" then error "Refusing to replace a preexisting search."
                set frontmost of ownedProcess to true
                if not frontmost of ownedProcess then error "Exact owned app is not foreground."
                set value of attribute "AXFocused" of navigationTarget to true
                if value of attribute "AXFocused" of navigationTarget is not true then error "Exact native search field is not focused."
                keystroke "Halo"
            else
                click navigationTarget
            end if
            log ("clicked=" & requestedAction)
        end if
    end tell
end run

on nativeNavigationIdentifier(element)
    tell application "System Events"
        if role of element is not "AXRadioButton" then return ""
        repeat with fieldName in {"AXTitle", "AXDescription"}
            if exists attribute (fieldName as text) of element then
                set labelValue to value of attribute (fieldName as text) of element
                if labelValue is "Library" then return "xodus.navigation.library"
                if labelValue is "Discover" then return "xodus.navigation.discover"
                if labelValue is "Downloads" then return "xodus.navigation.downloads"
            end if
        end repeat
    end tell
    return ""
end nativeNavigationIdentifier

on isNamedButton(element, expectedName)
    tell application "System Events"
        if role of element is not "AXButton" then return false
        repeat with fieldName in {"AXTitle", "AXDescription"}
            if exists attribute (fieldName as text) of element then
                if value of attribute (fieldName as text) of element is expectedName then return true
            end if
        end repeat
    end tell
    return false
end isNamedButton

on targetIdentifier(destination)
    if destination is "Library" then return "xodus.navigation.library"
    if destination is "Discover" then return "xodus.navigation.discover"
    if destination is "Downloads" then return "xodus.navigation.downloads"
    if destination is "Account" then return "xodus.account"
    if destination is "CheckStatus" then return "xodus.account.checkStatus"
    if destination is "CloseAccount" then return "xodus.account.close"
    if destination is "SearchHalo" then return "xodus.catalog.search"
    if destination is "More" then return "xodus.catalog.loadMore"
    if destination is "InspectCancel" then return "xodus.library.inspectFolder"
    error "Unknown destination."
end targetIdentifier
