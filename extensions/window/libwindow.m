#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <CoreVideo/CoreVideo.h>
#import <os/lock.h>
#import <LuaSkin/LuaSkin.h>
#import "HSuicore.h"

static const char *USERDATA_TAG = "hs.window";
static LSRefTable refTable = LUA_NOREF;
#define get_objectFromUserdata(objType, L, idx, tag) (objType*)*((void**)luaL_checkudata(L, idx, tag))

#pragma mark - Helper functions

static AXUIElementRef system_wide_element() {
    static AXUIElementRef element;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        element = AXUIElementCreateSystemWide();
    });
    return element;
}

/// hs.window.list(allWindows) -> table
/// Function
/// Gets a table containing all the window data retrieved from `CGWindowListCreate`.
///
/// Parameters:
///  * allWindows - Get all the windows, even those "below" the Dock window.
///
/// Returns:
///  * `true` is succesful otherwise `false` if an error occurred.
///
/// Notes:
///  * This allows you to get window information without Accessibility Permissions.
static int window_list(lua_State* L) {
    // SOURCE: https://stackoverflow.com/a/15985829/6925202
    BOOL allWindows = lua_toboolean(L, 1);

    // Fetch all on screen windows
    CFArrayRef windowListArray = CGWindowListCreate(kCGWindowListOptionOnScreenOnly|kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    NSArray *windows = CFBridgingRelease(CGWindowListCreateDescriptionFromArray(windowListArray));

    if (!allWindows) {
        // Find window ID of "Dock" window
        NSNumber *dockWindowNumber = nil;
        for (NSDictionary *window in windows) {
            if ([(NSString *)window[(__bridge NSString *)kCGWindowName] isEqualToString:@"Dock"]) {
                dockWindowNumber = window[(__bridge NSString *)kCGWindowNumber];
                break;
            }
        }
        if (dockWindowNumber) {
            // Fetch on screen windows again, filtering to those "below" the Dock window
            // This filters out all but the "standard" application windows

            CFRelease(windowListArray);
            windowListArray = CGWindowListCreate(kCGWindowListOptionOnScreenBelowWindow|kCGWindowListExcludeDesktopElements, [dockWindowNumber unsignedIntValue]);
            windows = CFBridgingRelease(CGWindowListCreateDescriptionFromArray(windowListArray));
        }
    }
    CFRelease(windowListArray);

    [[LuaSkin sharedWithState:NULL] pushNSObject:windows] ;
    return 1 ;
}

/// hs.window.timeout(value) -> boolean
/// Function
/// Sets the timeout value used in the accessibility API.
///
/// Parameters:
///  * value - The number of seconds for the new timeout value.
///
/// Returns:
///  * `true` is succesful otherwise `false` if an error occurred.
static int window_timeout(lua_State* L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L] ;
    [skin checkArgs: LS_TNUMBER, LS_TBREAK] ;
    NSNumber *value = [skin toNSObjectAtIndex:1] ;
    float fvalue = [value floatValue];
    AXError result = AXUIElementSetMessagingTimeout(system_wide_element(), fvalue);
    if (result == kAXErrorIllegalArgument) {
        [LuaSkin logError:@"hs.window.timeout() - One or more of the arguments is an illegal value (timeout values must be positive)."];
        lua_pushboolean(L, false);
        return 1;
    }
    if (result == kAXErrorInvalidUIElement) {
        [LuaSkin logError:@"hs.window.timeout() - The AXUIElementRef is invalid."];
        lua_pushboolean(L, false);
        return 1;
    }
    lua_pushboolean(L, true);
    return 1;
}

/// hs.window.focusedWindow() -> window
/// Constructor
/// Returns the window that has keyboard/mouse focus
///
/// Parameters:
///  * None
///
/// Returns:
///  * An `hs.window` object representing the currently focused window
static int window_focusedwindow(lua_State* L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TBREAK];
    [skin pushNSObject:[HSwindow focusedWindow]];
    return 1;
}

/// hs.window:title() -> string
/// Method
/// Gets the title of the window
///
/// Parameters:
///  * None
///
/// Returns:
///  * A string containing the title of the window
static int window_title(lua_State* L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK];
    HSwindow *win = [skin toNSObjectAtIndex:1];
    [skin pushNSObject:win.title];
    return 1;
}

/// hs.window:subrole() -> string
/// Method
/// Gets the subrole of the window
///
/// Parameters:
///  * None
///
/// Returns:
///  * A string containing the subrole of the window
///
/// Notes:
///  * This typically helps to determine if a window is a special kind of window - such as a modal window, or a floating window
static int window_subrole(lua_State* L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK];
    HSwindow *win = [skin toNSObjectAtIndex:1];
    [skin pushNSObject:win.subRole];
    return 1;
}

/// hs.window:role() -> string
/// Method
/// Gets the role of the window
///
/// Parameters:
///  * None
///
/// Returns:
///  * A string containing the role of the window
static int window_role(lua_State* L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK];
    HSwindow *win = [skin toNSObjectAtIndex:1];
    [skin pushNSObject:win.role];
    return 1;
}

/// hs.window:isStandard() -> bool
/// Method
/// Determines if the window is a standard window
///
/// Parameters:
///  * None
///
/// Returns:
///  * True if the window is standard, otherwise false
///
/// Notes:
///  * "Standard window" means that this is not an unusual popup window, a modal dialog, a floating window, etc.
static int window_isstandard(lua_State* L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK];
    HSwindow *win = [skin toNSObjectAtIndex:1];
    lua_pushboolean(L, win.isStandard);
    return 1;
}

/// hs.window:topLeft() -> point
/// Method
/// Gets the absolute co-ordinates of the top left of the window
///
/// Parameters:
///  * None
///
/// Returns:
///  * A point-table containing the absolute co-ordinates of the top left corner of the window
static int window__topleft(lua_State* L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK];
    HSwindow *win = [skin toNSObjectAtIndex:1];
    [skin pushNSPoint:win.topLeft];
    return 1;
}

/// hs.window:size() -> size
/// Method
/// Gets the size of the window
///
/// Parameters:
///  * None
///
/// Returns:
///  * A size-table containing the width and height of the window
static int window__size(lua_State* L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK];
    HSwindow *win = [skin toNSObjectAtIndex:1];
    [skin pushNSSize:win.size];
    return 1;
}

/// hs.window:setTopLeft(point) -> window
/// Method
/// Moves the window to a given point
///
/// Parameters:
///  * point - A point-table containing the absolute co-ordinates the window should be moved to
///
/// Returns:
///  * The `hs.window` object
static int window__settopleft(lua_State* L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TTABLE, LS_TBREAK];
    HSwindow *win = [skin toNSObjectAtIndex:1];
    win.topLeft = [skin tableToPointAtIndex:2];
    lua_pushvalue(L, 1);
    return 1;
}

//TODO window__setframe, but it's Yosemite only :/
//https://developer.apple.com/library/prerelease/mac/documentation/AppKit/Reference/NSAccessibility_Protocol_Reference/index.html#//apple_ref/occ/intfp/NSAccessibility/accessibilityFrame

/// hs.window:setSize(size) -> window
/// Method
/// Resizes the window
///
/// Parameters:
///  * size - A size-table containing the width and height the window should be resized to
///
/// Returns:
///  * The `hs.window` object
static int window__setsize(lua_State* L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TTABLE, LS_TBREAK];
    HSwindow *win = [skin toNSObjectAtIndex:1];
    win.size = [skin tableToSizeAtIndex:2];
    lua_pushvalue(L, 1);
    return 1;
}

/// hs.window:toggleZoom() -> window
/// Method
/// Toggles the zoom state of the window (this is effectively equivalent to clicking the green maximize/fullscreen button at the top left of a window)
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.window` object
static int window__togglezoom(lua_State* L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK];
    HSwindow *win = [skin toNSObjectAtIndex:1];
    [win toggleZoom];
    lua_pushvalue(L, 1);
    return 1;
}

/// hs.window:zoomButtonRect() -> rect-table or nil
/// Method
/// Gets a rect-table for the location of the zoom button (the green button typically found at the top left of a window)
///
/// Parameters:
///  * None
///
/// Returns:
///  * A rect-table containing the bounding frame of the zoom button, or nil if an error occurred
///
/// Notes:
///  * The co-ordinates in the rect-table (i.e. the `x` and `y` values) are in absolute co-ordinates, not relative to the window the button is part of, or the screen the window is on
///  * Although not perfect as such, this method can provide a useful way to find a region of the titlebar suitable for simulating mouse click events on, with `hs.eventtap`
static int window_getZoomButtonRect(lua_State* L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK];
    HSwindow *win = [skin toNSObjectAtIndex:1];
    [skin pushNSRect:win.zoomButtonRect];
    return 1;
}

/// hs.window:isMaximizable() -> bool or nil
/// Method
/// Determines if a window is maximizable
///
/// Parameters:
///  * None
///
/// Returns:
///  * True if the window is maximizable, False if it isn't, or nil if an error occurred
static int window_isMaximizable(lua_State *L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK];
    HSwindow *win = [skin toNSObjectAtIndex:1];

    AXUIElementRef button = nil;
    CFBooleanRef isEnabled;

    if (AXUIElementCopyAttributeValue(win.elementRef, kAXZoomButtonAttribute, (CFTypeRef*)&button) != noErr) goto cleanup;
    if (AXUIElementCopyAttributeValue(button, kAXEnabledAttribute, (CFTypeRef*)&isEnabled) != noErr) goto cleanup;

    lua_pushboolean(L, isEnabled == kCFBooleanTrue ? true : false);
    return 1;

cleanup:
    lua_pushnil(L);
    return 1;
}

/// hs.window:close() -> bool
/// Method
/// Closes the window
///
/// Parameters:
///  * None
///
/// Returns:
///  * True if the operation succeeded, false if not
static int window__close(lua_State* L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK];
    HSwindow *win = [skin toNSObjectAtIndex:1];
    lua_pushboolean(L, [win close]);
    return 1;
}

/// hs.window:focusTab(index) -> bool
/// Method
/// Focuses the tab in the window's tab group at index, or the last tab if index is out of bounds
///
/// Parameters:
///  * index - A number, a 1-based index of a tab to focus
///
/// Returns:
///  * true if the tab was successfully pressed, or false if there was a problem
///
/// Notes:
///  * This method works with document tab groups and some app tabs, like Chrome and Safari.
static int window_focustab(lua_State* L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER | LS_TINTEGER, LS_TBREAK];
    HSwindow *win = [skin toNSObjectAtIndex:1];
    int tabIndex = (int)lua_tointeger(L, 2);
    lua_pushboolean(L, [win focusTab:tabIndex]);
    return 1;
}

/// hs.window:tabCount() -> number or nil
/// Method
/// Gets the number of tabs in the window has
///
/// Parameters:
///  * None
///
/// Returns:
///  * A number containing the number of tabs, or nil if an error occurred
///
/// Notes:
///  * Intended for use with the focusTab method, if this returns a number, then focusTab can switch between that many tabs.
static int window_tabcount(lua_State* L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK];
    HSwindow *win = [skin toNSObjectAtIndex:1];
    lua_pushinteger(L, win.tabCount);
    return 1;
}

/// hs.window:setFullScreen(fullscreen) -> window
/// Method
/// Sets the fullscreen state of the window
///
/// Parameters:
///  * fullscreen - A boolean, true if the window should be set fullscreen, false if not
///
/// Returns:
///  * The `hs.window` object
static int window__setfullscreen(lua_State* L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN, LS_TBREAK];
    HSwindow *win = [skin toNSObjectAtIndex:1];
    win.fullscreen = lua_toboolean(L, 2);
    lua_pushvalue(L, 1);
    return 1;
}

/// hs.window:isFullScreen() -> bool or nil
/// Method
/// Gets the fullscreen state of the window
///
/// Parameters:
///  * None
///
/// Returns:
///  * True if the window is fullscreen, false if not. Nil if an error occurred
static int window_isfullscreen(lua_State* L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK];
    HSwindow *win = [skin toNSObjectAtIndex:1];
    lua_pushboolean(L, win.fullscreen);
    return 1;
}

/// hs.window:minimize() -> window
/// Method
/// Minimizes the window
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.window` object
///
/// Notes:
///  * This method will always animate per your system settings and is not affected by `hs.window.animationDuration`
static int window__minimize(lua_State* L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK];
    HSwindow *win = [skin toNSObjectAtIndex:1];
    win.minimized = YES;
    lua_pushvalue(L, 1);
    return 1;
}

/// hs.window:unminimize() -> window
/// Method
/// Un-minimizes the window
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.window` object
static int window__unminimize(lua_State* L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK];
    HSwindow *win = [skin toNSObjectAtIndex:1];
    win.minimized = NO;
    lua_pushvalue(L, 1);
    return 1;
}

/// hs.window:isMinimized() -> bool
/// Method
/// Gets the minimized state of the window
///
/// Parameters:
///  * None
///
/// Returns:
///  * True if the window is minimized, otherwise false
static int window_isminimized(lua_State* L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK];
    HSwindow *win = [skin toNSObjectAtIndex:1];
    lua_pushboolean(L, win.minimized);
    return 1;
}

// hs.window:pid()
static int window_pid(lua_State *L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK];
    HSwindow *win = [skin toNSObjectAtIndex:1];
    lua_pushinteger(L, win.pid);
    return 1;
}

/// hs.window:application() -> app or nil
/// Method
/// Gets the `hs.application` object the window belongs to
///
/// Parameters:
///  * None
///
/// Returns:
///  * An `hs.application` object representing the application that owns the window, or nil if an error occurred
static int window_application(lua_State* L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK];
    HSwindow *win = [skin toNSObjectAtIndex:1];
    HSapplication *app = [[HSapplication alloc] initWithPid:win.pid withState:L];
    [skin pushNSObject:app];
    return 1;
}

/// hs.window:becomeMain() -> window
/// Method
/// Makes the window the main window of its application
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.window` object
///
/// Notes:
///  * Make a window become the main window does not transfer focus to the application. See `hs.window.focus()`
static int window_becomemain(lua_State* L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK];
    HSwindow *win = [skin toNSObjectAtIndex:1];
    [win becomeMain];
    lua_pushvalue(L, 1);
    return 1;
}

/// hs.window:raise() -> window
/// Method
/// Brings a window to the front of the screen without focussing it
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.window` object
static int window_raise(lua_State* L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK];
    HSwindow *win = [skin toNSObjectAtIndex:1];
    [win raise];
    lua_pushvalue(L, 1);
    return 1;
}

static int window__orderedwinids(lua_State* L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TBREAK];
    [skin pushNSObject:[HSwindow orderedWindowIDs]];
    return 1;
}

/// hs.window:id() -> number or nil
/// Method
/// Gets the unique identifier of the window
///
/// Parameters:
///  * None
///
/// Returns:
///  * A number containing the unique identifier of the window, or nil if an error occurred
static int window_id(lua_State* L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK];
    HSwindow *win = [skin toNSObjectAtIndex:1];
    lua_pushinteger(L, win.winID);
    return 1;
}

/// hs.window.setShadows(shadows)
/// Function
/// Enables/Disables window shadows
///
/// Parameters:
///  * shadows - A boolean, true to show window shadows, false to hide window shadows
///
/// Returns:
///  * None
///
/// Notes:
///  * This function uses a private, undocumented OS X API call, so it is not guaranteed to work in any future OS X release
static int window_setShadows(lua_State* L) {
    luaL_checktype(L, 1, LUA_TBOOLEAN);
    BOOL shadows = lua_toboolean(L, 1);

    // CoreGraphics private API for window shadows
    #define kCGSDebugOptionNormal    0
    #define kCGSDebugOptionNoShadows 16384
    void CGSSetDebugOptions(int);

    CGSSetDebugOptions(shadows ? kCGSDebugOptionNormal : kCGSDebugOptionNoShadows);

    return 0;
}

/// hs.window.snapshotForID(ID [, keepTransparency]) -> hs.image-object
/// Function
/// Returns a snapshot of the window specified by the ID as an `hs.image` object
///
/// Parameters:
///  * ID - Window ID of the window to take a snapshot of.
///  * keepTransparency - optional boolean value indicating if the windows alpha value (transparency) should be maintained in the resulting image or if it should be fully opaque (default).
///
/// Returns:
///  * `hs.image` object of the window snapshot or nil if unable to create a snapshot
///
/// Notes:
///  * See also method `hs.window:snapshot()`
///  * Because the window ID cannot always be dynamically determined, this function will allow you to provide the ID of a window that was cached earlier.
static int window_snapshotForID(lua_State* L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TNUMBER|LS_TSTRING, LS_TBOOLEAN|LS_TOPTIONAL, LS_TBREAK];
    CGWindowID windowID = (CGWindowID)lua_tointeger(L, 1);
    [skin pushNSObject:[HSwindow snapshotForID:windowID keepTransparency:lua_toboolean(L, 2)]];
    return 1;
}

/// hs.window:snapshot([keepTransparency]) -> hs.image-object
/// Method
/// Returns a snapshot of the window as an `hs.image` object
///
/// Parameters:
///  * keepTransparency - optional boolean value indicating if the windows alpha value (transparency) should be maintained in the resulting image or if it should be fully opaque (default).
///
/// Returns:
///  * `hs.image` object of the window snapshot or nil if unable to create a snapshot
///
/// Notes:
///  * See also function `hs.window.snapshotForID()`
static int window_snapshot(lua_State* L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN|LS_TOPTIONAL, LS_TBREAK];
    HSwindow *win = [skin toNSObjectAtIndex:1];
    [skin pushNSObject:[win snapshot:lua_toboolean(L, 2)]];
    return 1;
}

#pragma mark - hs.uielement methods

static int window_uielement_isApplication(lua_State *L) {
    // This method is a clone of what happens in hs.uielement:isApplication(), since hs.window objects have to conform to hs.uielement methods
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK];
    HSapplication *app = [skin toNSObjectAtIndex:1];
    HSuielement *uiElement = app.uiElement;
    lua_pushboolean(L, [uiElement.role isEqualToString:@"AXApplication"]);

    return 1;
}

static int window_uielement_isWindow(lua_State *L) {
    // This method is a clone of what happens in hs.uielement:isWindow(), since hs.window objects have to conform to hs.uielement methods
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK];
    HSapplication *app = [skin toNSObjectAtIndex:1];
    HSuielement *uiElement = app.uiElement;
    lua_pushboolean(L, uiElement.isWindow);

    return 1;
}

static int window_uielement_role(lua_State *L) {
    // This method is a clone of what happens in hs.uielement:role(), since hs.window objects have to conform to hs.uielement methods
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK];
    HSapplication *app = [skin toNSObjectAtIndex:1];
    HSuielement *uiElement = app.uiElement;
    [skin pushNSObject:uiElement.role];

    return 1;
}

static int window_uielement_selectedText(lua_State *L) {
    // This method is a clone of what happens in hs.uielement:selectedText(), since hs.window objects have to conform to hs.uielement methods
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK];
    HSapplication *app = [skin toNSObjectAtIndex:1];
    HSuielement *uiElement = app.uiElement;
    [skin pushNSObject:uiElement.selectedText];

    return 1;
}

static int window_uielement_newWatcher(lua_State *L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TFUNCTION, LS_TANY|LS_TOPTIONAL, LS_TBREAK];

    HSwindow *win = [skin toNSObjectAtIndex:1];
    HSuielement *uiElement = win.uiElement;
    HSuielementWatcher *watcher = [uiElement newWatcherAtIndex:2 withUserdataAtIndex:3 withLuaState:L];
    [skin pushNSObject:watcher];

    return 1;
}

#pragma mark - Lua<->NSObject Conversion Functions
// These must not throw a lua error to ensure LuaSkin can safely be used from Objective-C
// delegates and blocks.

static int pushHSwindow(lua_State *L, id obj) {
    HSwindow *value = obj;
    value.selfRefCount++;
    void** valuePtr = lua_newuserdata(L, sizeof(HSwindow *));
    *valuePtr = (__bridge_retained void *)value;
    luaL_getmetatable(L, USERDATA_TAG);
    lua_setmetatable(L, -2);
    return 1;
}

static id toHSwindowFromLua(lua_State *L, int idx) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    HSwindow *value;
    if (luaL_testudata(L, idx, USERDATA_TAG)) {
        value = get_objectFromUserdata(__bridge HSwindow, L, idx, USERDATA_TAG);
    } else {
        [skin logError:[NSString stringWithFormat:@"expected %s object, found %s", USERDATA_TAG,
                        lua_typename(L, lua_type(L, idx))]];
    }
    return value;
}

#pragma mark - Hammerspoon/Lua Infrastructure

static int userdata_tostring(lua_State* L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK];
    HSwindow *win = [skin toNSObjectAtIndex:1];
    lua_pushstring(L, [NSString stringWithFormat:@"%s: %@ (%p)", USERDATA_TAG, win.title, lua_topointer(L, 1)].UTF8String);
    return 1 ;
}

static int userdata_eq(lua_State *L) {
    BOOL isEqual = NO;
    if (luaL_testudata(L, 1, USERDATA_TAG) && luaL_testudata(L, 2, USERDATA_TAG)) {
        LuaSkin *skin = [LuaSkin sharedWithState:L];
        HSwindow *win1 = [skin toNSObjectAtIndex:1];
        HSwindow *win2 = [skin toNSObjectAtIndex:2];
        isEqual = CFEqual(win1.elementRef, win2.elementRef);
    }
    lua_pushboolean(L, isEqual);
    return 1;
}

static int userdata_gc(lua_State *L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TUSERDATA, USERDATA_TAG, LS_TBREAK];
    HSwindow *win = get_objectFromUserdata(__bridge_transfer HSwindow, L, 1, USERDATA_TAG);
    if (win) {
        win.selfRefCount--;
        if (win.selfRefCount == 0) {
            win = nil;
        }
    }

    // Remove the Metatable so future use of the variable in Lua won't think it's valid
    lua_pushnil(L);
    lua_setmetatable(L, 1);
    return 0;
}

#pragma mark - custom: off-main-thread, display-link paced animation driver
//
// 为什么：窗口动画原本由 Lua 在主线程上用 17ms 的 hs.timer 逐帧插值 + 逐帧写 AX。后果是
//   · PaperWM 的重排（一次 ≈8ms，单是 visibleWindows() 就 7.77ms）、窗口事件回调、
//     Lua GC 都会推迟动画步进；
//   · 17ms 与 60Hz 的 16.67ms 不同源，步进落在刷新的哪个相位不固定 —— 这本身就是
//     「不流畅」里最容易被看见的那部分。
// 现在插值和 AX 写都跑在 CVDisplayLink 的回调线程上，按显示器刷新节拍驱动；主线程一个
// 像素都不碰。动画全部落地后再 dispatch_async 回主线程，通知 Lua 做善后。
//
// 线程模型（要点：不让主线程等 AX）：
//   · _items 只归 display link 回调线程所有；
//   · 主线程只做两件轻活：_animSync 交一份新表、_animCancel 记一个「立刻失效」的 id；
//   · 两个容器共用一把短锁 _lock，而回调线程在**同一把锁里**做每个窗口的 AX 写 ——
//     主线程因此最多等一次 AX 写（实测 ~0.4ms），换来的是「取消之后绝不会再写这个窗口」
//     这个确定语义（stopAnimation(snap=true) 紧接着要写终帧，不能被打回）。

@interface HSAnimItem : NSObject
@property (nonatomic, assign) AXUIElementRef element;
@property (nonatomic, assign) int windowID;
@property (nonatomic, assign) NSRect from;
@property (nonatomic, assign) NSRect to;
@property (nonatomic, assign) double elapsed;
@property (nonatomic, assign) double duration;
@property (nonatomic, assign) BOOL sizeChanges;
@end

@implementation HSAnimItem
- (void)dealloc {
    if (_element) { CFRelease(_element); }
}
@end

@interface HSAnimDriver : NSObject
@property (nonatomic, assign) CVDisplayLinkRef link;
@property (nonatomic, strong) NSMutableArray<HSAnimItem *> *items;
@property (nonatomic, strong) NSMutableArray<HSAnimItem *> *incoming;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *cancelled;
@property (nonatomic, assign) os_unfair_lock lock;
@property (nonatomic, assign) double lastTick;
@property (nonatomic, assign) BOOL freshList;
@property (nonatomic, assign) int32_t activeCount;
@property (nonatomic, assign) int32_t generation;
@property (nonatomic, assign) lua_State *L;
@property (nonatomic, assign) int finishRef;
- (void)syncWith:(NSMutableArray<HSAnimItem *> *)list;
- (void)cancel:(int)windowID;
- (int)activeCount;
- (void)step;
@end

static double hsAnimNow(void) {
    double freq = (double)CVGetHostClockFrequency();
    return (freq > 0.0) ? ((double)CVGetCurrentHostTime() / freq) : 0.0;
}

// 与上游 Lua 那版完全一致的缓出曲线：l = 1 - t/len; r = 1 - l*l
static double hsAnimQuadOut(double elapsed, double duration) {
    if (duration <= 0.0) { return 1.0; }
    double l = 1.0 - fmin(fmax(elapsed / duration, 0.0), 1.0);
    return 1.0 - l * l;
}

static void hsAnimWritePos(AXUIElementRef el, NSRect f) {
    CGPoint p = CGPointMake(f.origin.x, f.origin.y);
    CFTypeRef v = AXValueCreate(kAXValueCGPointType, &p);
    if (v) {
        AXUIElementSetAttributeValue(el, (CFStringRef)NSAccessibilityPositionAttribute, v);
        CFRelease(v);
    }
}

static void hsAnimWriteSize(AXUIElementRef el, NSRect f) {
    CGSize s = CGSizeMake(f.size.width, f.size.height);
    CFTypeRef v = AXValueCreate(kAXValueCGSizeType, &s);
    if (v) {
        AXUIElementSetAttributeValue(el, (CFStringRef)NSAccessibilitySizeAttribute, v);
        CFRelease(v);
    }
}

// full = 上游那套 size → position → size 三步（终帧，以及宽高会变的动画）；
// 否则只写位置：宽高不变的纯位移动画，每拍 AX 往返能从 3 次降到 1 次。
static void hsAnimWriteFrame(AXUIElementRef el, NSRect f, BOOL full) {
    if (!el) { return; }
    if (full) { hsAnimWriteSize(el, f); }
    hsAnimWritePos(el, f);
    if (full) { hsAnimWriteSize(el, f); }
}

static CVReturn hsAnimDisplayLinkCallback(CVDisplayLinkRef link, const CVTimeStamp *now,
                                         const CVTimeStamp *outputTime, CVOptionFlags flagsIn,
                                         CVOptionFlags *flagsOut, void *context) {
    (void)link; (void)now; (void)outputTime; (void)flagsIn; (void)flagsOut;
    @autoreleasepool {
        [(__bridge HSAnimDriver *)context step];
    }
    return kCVReturnSuccess;
}

@implementation HSAnimDriver

- (instancetype)init {
    self = [super init];
    if (self) {
        _items = [NSMutableArray array];
        _cancelled = [NSMutableSet set];
        _lock = OS_UNFAIR_LOCK_INIT;
        _finishRef = LUA_NOREF;
        _L = NULL;
    }
    return self;
}

- (int)activeCount {
    return (int)__atomic_load_n(&_activeCount, __ATOMIC_SEQ_CST);
}

- (void)ensureRunning {
    if (!_link) {
        if (CVDisplayLinkCreateWithActiveCGDisplays(&_link) != kCVReturnSuccess) {
            _link = NULL;
            NSLog(@"hs.window custom: CVDisplayLink 创建失败，动画将不推进");
            return;
        }
        CVDisplayLinkSetOutputCallback(_link, hsAnimDisplayLinkCallback, (__bridge void *)self);
    }
    if (!CVDisplayLinkIsRunning(_link)) {
        _lastTick = 0.0;
        CVDisplayLinkStart(_link);
    }
}

- (void)syncWith:(NSMutableArray<HSAnimItem *> *)list {
    os_unfair_lock_lock(&_lock);
    _incoming = list;
    [_cancelled removeAllObjects];   // 新表是权威的：不在表里的动画自然消失
    os_unfair_lock_unlock(&_lock);

    __atomic_add_fetch(&_generation, 1, __ATOMIC_SEQ_CST);
    [self ensureRunning];
}

- (void)cancel:(int)windowID {
    // 只加一个标记；回调线程在每次写之前都会看它，所以取消对「后续任何一帧」立刻生效
    os_unfair_lock_lock(&_lock);
    [_cancelled addObject:@(windowID)];
    os_unfair_lock_unlock(&_lock);
}

- (void)stopIfGenerationUnchanged:(int32_t)gen {
    // 只有在「期间没有新动画」时才停；否则会把刚起来的动画掐掉
    if (__atomic_load_n(&_generation, __ATOMIC_SEQ_CST) != gen) { return; }
    if (_link && CVDisplayLinkIsRunning(_link)) { CVDisplayLinkStop(_link); }
}

- (void)deliverFinished:(NSArray<NSNumber *> *)finished {
    if (finished.count == 0) { return; }
    HSAnimDriver *d = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        lua_State *L = d.L;
        if (!L || d.finishRef == LUA_NOREF) { return; }
        int top = lua_gettop(L);
        lua_rawgeti(L, LUA_REGISTRYINDEX, d.finishRef);
        if (lua_isfunction(L, -1)) {
            lua_newtable(L);
            int i = 1;
            for (NSNumber *n in finished) {
                lua_pushinteger(L, (lua_Integer)n.intValue);
                lua_rawseti(L, -2, i++);
            }
            LuaSkin *skin = [LuaSkin sharedWithState:L];
            [skin protectedCallAndTraceback:1 nresults:0];
        }
        lua_settop(L, top);
    });
}

- (void)step {
    NSMutableArray<HSAnimItem *> *newList = nil;
    os_unfair_lock_lock(&_lock);
    if (_incoming) {
        newList = _incoming;
        _incoming = nil;
        [_cancelled removeAllObjects];
    }
    os_unfair_lock_unlock(&_lock);
    if (newList) {
        _items = newList;
        _freshList = YES;
    }

    if (_items.count == 0) {
        __atomic_store_n(&_activeCount, 0, __ATOMIC_SEQ_CST);
        int32_t gen = __atomic_load_n(&_generation, __ATOMIC_SEQ_CST);
        HSAnimDriver *d = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [d stopIfGenerationUnchanged:gen]; });
        return;
    }

    // 进度用「自己量的 delta」推进，不跨时钟假设 Lua 的时间基准
    double now = hsAnimNow();
    double delta = (_lastTick > 0.0) ? (now - _lastTick) : 0.0;
    if (delta < 0.0 || delta > 0.1) { delta = 0.0; }
    _lastTick = now;
    if (_freshList) { delta = 0.0; _freshList = NO; }   // 新表刚由 Lua 摆好，这一拍不推进

    NSMutableArray<HSAnimItem *> *keep = [NSMutableArray array];
    NSMutableArray<NSNumber *> *finished = nil;

    for (HSAnimItem *it in _items) {
        it.elapsed += delta;
        double r = hsAnimQuadOut(it.elapsed, it.duration);
        NSRect target;
        BOOL finalFrame = (r >= 1.0);
        if (finalFrame) {
            target = it.to;
        } else {
            target.origin.x = it.from.origin.x + (it.to.origin.x - it.from.origin.x) * r;
            target.origin.y = it.from.origin.y + (it.to.origin.y - it.from.origin.y) * r;
            target.size.width  = it.from.size.width  + (it.to.size.width  - it.from.size.width)  * r;
            target.size.height = it.from.size.height + (it.to.size.height - it.from.size.height) * r;
        }

        os_unfair_lock_lock(&_lock);
        BOOL skip = [_cancelled containsObject:@(it.windowID)];
        if (!skip) { hsAnimWriteFrame(it.element, target, finalFrame || it.sizeChanges); }
        os_unfair_lock_unlock(&_lock);

        if (skip) { continue; }
        if (finalFrame) {
            if (!finished) { finished = [NSMutableArray array]; }
            [finished addObject:@(it.windowID)];
        } else {
            [keep addObject:it];
        }
    }

    _items = keep;
    __atomic_store_n(&_activeCount, (int32_t)_items.count, __ATOMIC_SEQ_CST);

    if (finished) { [self deliverFinished:finished]; }

    if (_items.count == 0) {
        int32_t gen = __atomic_load_n(&_generation, __ATOMIC_SEQ_CST);
        HSAnimDriver *d = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [d stopIfGenerationUnchanged:gen]; });
    }
}

@end

static HSAnimDriver *hsAnimDriverShared(void) {
    static HSAnimDriver *driver = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ driver = [[HSAnimDriver alloc] init]; });
    return driver;
}

// 从一个 rect 表里读 x/y/w/h（geometry 表里还有 x1/y1/x2/y2，这里只认前者）
static NSRect hsAnimRectAt(lua_State *L, int tableIndex, const char *field) {
    NSRect r = NSMakeRect(0.0, 0.0, 0.0, 0.0);
    lua_getfield(L, tableIndex, field);
    if (lua_istable(L, -1)) {
        int t = lua_gettop(L);
        lua_getfield(L, t, "x"); if (lua_isnumber(L, -1)) { r.origin.x = lua_tonumber(L, -1); } lua_pop(L, 1);
        lua_getfield(L, t, "y"); if (lua_isnumber(L, -1)) { r.origin.y = lua_tonumber(L, -1); } lua_pop(L, 1);
        lua_getfield(L, t, "w"); if (lua_isnumber(L, -1)) { r.size.width = lua_tonumber(L, -1); } lua_pop(L, 1);
        lua_getfield(L, t, "h"); if (lua_isnumber(L, -1)) { r.size.height = lua_tonumber(L, -1); } lua_pop(L, 1);
    }
    lua_pop(L, 1);
    return r;
}

static double hsAnimNumberAt(lua_State *L, int tableIndex, const char *field, double dflt) {
    double v = dflt;
    lua_getfield(L, tableIndex, field);
    if (lua_isnumber(L, -1)) { v = lua_tonumber(L, -1); }
    lua_pop(L, 1);
    return v;
}

/// hs.window._animSync(list) -> none
/// Function
/// Hands the complete set of in-flight window animations to the display-link driver
///
/// Parameters:
///  * list - An array of tables, each with `window`, `id`, `from`, `to`, `elapsed` and `duration`
///
/// Returns:
///  * None
static int window__animsync(lua_State *L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TTABLE, LS_TBREAK];

    NSMutableArray<HSAnimItem *> *list = [NSMutableArray array];
    lua_Integer n = (lua_Integer)lua_rawlen(L, 1);
    for (lua_Integer i = 1; i <= n; i++) {
        lua_rawgeti(L, 1, (int)i);
        int elem = lua_gettop(L);
        if (lua_istable(L, elem)) {
            lua_getfield(L, elem, "window");
            id obj = [skin toNSObjectAtIndex:(elem + 1)];
            lua_pop(L, 1);
            if ([obj isKindOfClass:[HSwindow class]]) {
                HSwindow *win = (HSwindow *)obj;
                AXUIElementRef el = win.elementRef;
                if (el) {
                    HSAnimItem *it = [[HSAnimItem alloc] init];
                    it.element = (AXUIElementRef)CFRetain(el);
                    it.windowID = (int)win.winID;
                    it.from = hsAnimRectAt(L, elem, "from");
                    it.to = hsAnimRectAt(L, elem, "to");
                    it.elapsed = hsAnimNumberAt(L, elem, "elapsed", 0.0);
                    it.duration = hsAnimNumberAt(L, elem, "duration", 0.0);
                    it.sizeChanges = (it.from.size.width != it.to.size.width) ||
                                     (it.from.size.height != it.to.size.height);
                    [list addObject:it];
                }
            }
        }
        lua_pop(L, 1);
    }

    [hsAnimDriverShared() syncWith:list];
    return 0;
}

/// hs.window._animCancel(id) -> none
/// Function
/// Marks a window's in-flight animation as cancelled so no further frame is written for it
///
/// Parameters:
///  * id - The `hs.window:id()` of the window whose animation should stop
///
/// Returns:
///  * None
static int window__animcancel(lua_State *L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TNUMBER, LS_TBREAK];
    [hsAnimDriverShared() cancel:(int)luaL_checkinteger(L, 1)];
    return 0;
}

/// hs.window._animActive() -> number
/// Function
/// Number of animations the display-link driver is still running
///
/// Parameters:
///  * None
///
/// Returns:
///  * The number of in-flight animations as seen by the driver thread
static int window__animactive(lua_State *L) {
    lua_pushinteger(L, (lua_Integer)[hsAnimDriverShared() activeCount]);
    return 1;
}

/// hs.window._animOnFinish(fn) -> none
/// Function
/// Registers the callback the driver calls (on the main thread) with the ids of animations that finished
///
/// Parameters:
///  * fn - A function receiving one argument: an array of finished window ids
///
/// Returns:
///  * None
static int window__animonfinish(lua_State *L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TFUNCTION, LS_TBREAK];
    HSAnimDriver *d = hsAnimDriverShared();
    if (d.finishRef != LUA_NOREF) { luaL_unref(L, LUA_REGISTRYINDEX, d.finishRef); }
    lua_pushvalue(L, 1);
    d.finishRef = luaL_ref(L, LUA_REGISTRYINDEX);
    d.L = L;
    return 0;
}

// Module functions
static const luaL_Reg moduleLib[] = {
    {"focusedWindow", window_focusedwindow},
    {"_orderedwinids", window__orderedwinids},
    {"setShadows", window_setShadows},
    {"snapshotForID", window_snapshotForID},
    {"timeout", window_timeout},
    {"list", window_list},
    {"_animSync", window__animsync},
    {"_animCancel", window__animcancel},
    {"_animActive", window__animactive},
    {"_animOnFinish", window__animonfinish},

    {NULL, NULL}
};

static const luaL_Reg module_metaLib[] = {
    {NULL, NULL}
};

// Metatable for userdata objects
static const luaL_Reg userdata_metaLib[] = {
    {"title", window_title},
    {"subrole", window_subrole},
    {"role", window_role},
    {"isStandard", window_isstandard},
    {"_topLeft", window__topleft},
    {"_size", window__size},
    {"_setTopLeft", window__settopleft},
    {"_setSize", window__setsize},
    {"_minimize", window__minimize},
    {"_unminimize", window__unminimize},
    {"isMinimized", window_isminimized},
    {"isMaximizable", window_isMaximizable},
    {"pid", window_pid},
    {"application", window_application},
    {"focusTab", window_focustab},
    {"tabCount", window_tabcount},
    {"becomeMain", window_becomemain},
    {"raise", window_raise},
    {"id", window_id},
    {"_toggleZoom", window__togglezoom},
    {"zoomButtonRect", window_getZoomButtonRect},
    {"_close", window__close},
    {"_setFullScreen", window__setfullscreen},
    {"isFullScreen", window_isfullscreen},
    {"snapshot", window_snapshot},

    // hs.uielement methods
    {"isApplication", window_uielement_isApplication},
    {"isWindow", window_uielement_isWindow},
    {"role", window_uielement_role},
    {"selectedText", window_uielement_selectedText},
    {"newWatcher", window_uielement_newWatcher},

    {"__tostring", userdata_tostring},
    {"__eq", userdata_eq},
    {"__gc", userdata_gc},

    {NULL, NULL}
};

int luaopen_hs_libwindow(lua_State* L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    refTable = [skin registerLibrary:USERDATA_TAG functions:moduleLib metaFunctions:module_metaLib];
    [skin registerObject:USERDATA_TAG objectFunctions:userdata_metaLib];

    [skin registerPushNSHelper:pushHSwindow         forClass:"HSwindow"];
    [skin registerLuaObjectHelper:toHSwindowFromLua forClass:"HSwindow"
                                         withUserdataMapping:USERDATA_TAG];
    return 1;
}
