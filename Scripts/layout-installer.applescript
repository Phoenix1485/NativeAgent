on run arguments
    set mountedFolder to POSIX file (item 1 of arguments) as alias
    tell application "Finder"
        open mountedFolder
        set installerWindow to container window of mountedFolder
        set current view of installerWindow to icon view
        set toolbar visible of installerWindow to false
        set statusbar visible of installerWindow to false
        set bounds of installerWindow to {180, 160, 820, 570}
        set options to icon view options of installerWindow
        set arrangement of options to not arranged
        set icon size of options to 96
        set text size of options to 14
        set position of item "NativeAgent.app" of mountedFolder to {160, 130}
        set position of item "Applications" of mountedFolder to {480, 130}
        set position of item "How to install.txt" of mountedFolder to {320, 295}
        update mountedFolder without registering applications
        delay 2
        close installerWindow
        delay 1
    end tell
end run
