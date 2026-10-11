//! Hand-written Win32 declarations used by the Windows backend (user32, kernel32, gdi32,
//! imm32, dwmapi, advapi32, shell32). Only what palette needs; no external binding package.
//!
//! Types and constants compile on every OS (the pure translation code and its Linux unit
//! tests use them). The `extern` functions are only referenced from Windows-only code.
const std = @import("std");
const builtin = @import("builtin");

pub const WINAPI: std.builtin.CallingConvention = if (builtin.os.tag == .windows) .winapi else .c;

pub const BOOL = i32;
pub const UINT = u32;
pub const DWORD = u32;
pub const WORD = u16;
pub const LONG = i32;
pub const ATOM = u16;
pub const WCHAR = u16;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const HRESULT = i32;
pub const HANDLE = *anyopaque;
pub const HWND = *opaque {};
pub const HINSTANCE = *opaque {};
pub const HMODULE = HINSTANCE;
pub const HICON = *opaque {};
pub const HCURSOR = HICON;
pub const HBRUSH = *opaque {};
pub const HMENU = *opaque {};
pub const HMONITOR = *opaque {};
pub const HIMC = *opaque {};
pub const HKEY = *opaque {};
pub const HDC = *opaque {};
pub const HGLOBAL = *anyopaque;

pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;

pub const POINT = extern struct { x: LONG = 0, y: LONG = 0 };
pub const RECT = extern struct {
    left: LONG = 0,
    top: LONG = 0,
    right: LONG = 0,
    bottom: LONG = 0,

    pub fn width(r: RECT) i32 {
        return r.right - r.left;
    }
    pub fn height(r: RECT) i32 {
        return r.bottom - r.top;
    }
};

pub const MSG = extern struct {
    hwnd: ?HWND = null,
    message: UINT = 0,
    wParam: WPARAM = 0,
    lParam: LPARAM = 0,
    time: DWORD = 0,
    pt: POINT = .{},
    lPrivate: DWORD = 0,
};

pub const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(WINAPI) LRESULT;

pub const WNDCLASSEXW = extern struct {
    cbSize: UINT = @sizeOf(WNDCLASSEXW),
    style: UINT = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?HINSTANCE = null,
    hIcon: ?HICON = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?HBRUSH = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: ?HICON = null,
};

pub const MINMAXINFO = extern struct {
    ptReserved: POINT,
    ptMaxSize: POINT,
    ptMaxPosition: POINT,
    ptMinTrackSize: POINT,
    ptMaxTrackSize: POINT,
};

pub const MONITORINFO = extern struct {
    cbSize: DWORD = @sizeOf(MONITORINFO),
    rcMonitor: RECT = .{},
    rcWork: RECT = .{},
    dwFlags: DWORD = 0,
};

pub const WINDOWPLACEMENT = extern struct {
    length: UINT = @sizeOf(WINDOWPLACEMENT),
    flags: UINT = 0,
    showCmd: UINT = 0,
    ptMinPosition: POINT = .{},
    ptMaxPosition: POINT = .{},
    rcNormalPosition: RECT = .{},
};

pub const TRACKMOUSEEVENT = extern struct {
    cbSize: DWORD = @sizeOf(TRACKMOUSEEVENT),
    dwFlags: DWORD,
    hwndTrack: HWND,
    dwHoverTime: DWORD = 0,
};

pub const COMPOSITIONFORM = extern struct {
    dwStyle: DWORD,
    ptCurrentPos: POINT = .{},
    rcArea: RECT = .{},
};

pub const CANDIDATEFORM = extern struct {
    dwIndex: DWORD = 0,
    dwStyle: DWORD,
    ptCurrentPos: POINT = .{},
    rcArea: RECT = .{},
};

pub const FLASHWINFO = extern struct {
    cbSize: UINT = @sizeOf(FLASHWINFO),
    hwnd: HWND,
    dwFlags: DWORD,
    uCount: UINT,
    dwTimeout: DWORD = 0,
};

pub const SIZE = extern struct { cx: LONG = 0, cy: LONG = 0 };

pub const CREATESTRUCTW = extern struct {
    lpCreateParams: ?*anyopaque,
    hInstance: ?HINSTANCE,
    hMenu: ?HMENU,
    hwndParent: ?HWND,
    cy: i32,
    cx: i32,
    y: i32,
    x: i32,
    style: LONG,
    lpszName: ?[*:0]const u16,
    lpszClass: ?[*:0]const u16,
    dwExStyle: DWORD,
};

pub const PAINTSTRUCT = extern struct {
    hdc: ?HDC = null,
    fErase: BOOL = 0,
    rcPaint: RECT = .{},
    fRestore: BOOL = 0,
    fIncUpdate: BOOL = 0,
    rgbReserved: [32]u8 = @splat(0),
};

// -- messages -------------------------------------------------------------------------------

pub const WM_NULL = 0x0000;
pub const WM_CREATE = 0x0001;
pub const WM_DESTROY = 0x0002;
pub const WM_MOVE = 0x0003;
pub const WM_SIZE = 0x0005;
pub const WM_ACTIVATE = 0x0006;
pub const WM_SETFOCUS = 0x0007;
pub const WM_KILLFOCUS = 0x0008;
pub const WM_PAINT = 0x000F;
pub const WM_CLOSE = 0x0010;
pub const WM_QUIT = 0x0012;
pub const WM_ERASEBKGND = 0x0014;
pub const WM_SHOWWINDOW = 0x0018;
pub const WM_SETTINGCHANGE = 0x001A;
pub const WM_SETCURSOR = 0x0020;
pub const WM_GETMINMAXINFO = 0x0024;
pub const WM_WINDOWPOSCHANGED = 0x0047;
pub const WM_NCCREATE = 0x0081;
pub const WM_NCDESTROY = 0x0082;
pub const WM_KEYFIRST = 0x0100;
pub const WM_KEYLAST = 0x0109;
pub const WM_KEYDOWN = 0x0100;
pub const WM_KEYUP = 0x0101;
pub const WM_CHAR = 0x0102;
pub const WM_DEADCHAR = 0x0103;
pub const WM_SYSKEYDOWN = 0x0104;
pub const WM_SYSKEYUP = 0x0105;
pub const WM_SYSCHAR = 0x0106;
pub const WM_SYSDEADCHAR = 0x0107;
pub const WM_UNICHAR = 0x0109;
pub const WM_IME_STARTCOMPOSITION = 0x010D;
pub const WM_IME_ENDCOMPOSITION = 0x010E;
pub const WM_IME_COMPOSITION = 0x010F;
pub const WM_SYSCOMMAND = 0x0112;
pub const WM_TIMER = 0x0113;
pub const WM_MOUSEMOVE = 0x0200;
pub const WM_LBUTTONDOWN = 0x0201;
pub const WM_LBUTTONUP = 0x0202;
pub const WM_LBUTTONDBLCLK = 0x0203;
pub const WM_RBUTTONDOWN = 0x0204;
pub const WM_RBUTTONUP = 0x0205;
pub const WM_RBUTTONDBLCLK = 0x0206;
pub const WM_MBUTTONDOWN = 0x0207;
pub const WM_MBUTTONUP = 0x0208;
pub const WM_MBUTTONDBLCLK = 0x0209;
pub const WM_MOUSEWHEEL = 0x020A;
pub const WM_XBUTTONDOWN = 0x020B;
pub const WM_XBUTTONUP = 0x020C;
pub const WM_XBUTTONDBLCLK = 0x020D;
pub const WM_MOUSEHWHEEL = 0x020E;
pub const WM_CAPTURECHANGED = 0x0215;
pub const WM_ENTERSIZEMOVE = 0x0231;
pub const WM_EXITSIZEMOVE = 0x0232;
pub const WM_IME_SETCONTEXT = 0x0281;
pub const WM_IME_NOTIFY = 0x0282;
pub const WM_IME_CHAR = 0x0286;
pub const WM_MOUSELEAVE = 0x02A3;
pub const WM_DPICHANGED = 0x02E0;
pub const WM_GETDPISCALEDSIZE = 0x02E4;
pub const WM_CLIPBOARDUPDATE = 0x031D;
pub const WM_DWMCOMPOSITIONCHANGED = 0x031E;
pub const WM_APP = 0x8000;
pub const WM_ENTERMENULOOP = 0x0211;
pub const WM_EXITMENULOOP = 0x0212;

pub const UNICODE_NOCHAR: WPARAM = 0xFFFF;

// wParam of WM_SIZE
pub const SIZE_RESTORED = 0;
pub const SIZE_MINIMIZED = 1;
pub const SIZE_MAXIMIZED = 2;

// WM_ACTIVATE
pub const WA_INACTIVE = 0;

// mouse key state (wParam)
pub const MK_LBUTTON = 0x0001;
pub const MK_RBUTTON = 0x0002;
pub const MK_SHIFT = 0x0004;
pub const MK_CONTROL = 0x0008;
pub const MK_MBUTTON = 0x0010;
pub const MK_XBUTTON1 = 0x0020;
pub const MK_XBUTTON2 = 0x0040;
pub const XBUTTON1 = 0x0001;
pub const XBUTTON2 = 0x0002;
pub const WHEEL_DELTA = 120;

pub const HTCLIENT = 1;

pub const TME_LEAVE = 0x00000002;
pub const TME_CANCEL = 0x80000000;

// keystroke flags (HIWORD(lParam))
pub const KF_EXTENDED = 0x0100;
pub const KF_REPEAT = 0x4000;
pub const KF_UP = 0x8000;

// -- window styles ----------------------------------------------------------------------------

pub const WS_OVERLAPPED = 0x00000000;
pub const WS_POPUP = 0x80000000;
pub const WS_CHILD = 0x40000000;
pub const WS_MINIMIZE = 0x20000000;
pub const WS_VISIBLE = 0x10000000;
pub const WS_CLIPSIBLINGS = 0x04000000;
pub const WS_CLIPCHILDREN = 0x02000000;
pub const WS_MAXIMIZE = 0x01000000;
pub const WS_CAPTION = 0x00C00000;
pub const WS_SYSMENU = 0x00080000;
pub const WS_THICKFRAME = 0x00040000;
pub const WS_MINIMIZEBOX = 0x00020000;
pub const WS_MAXIMIZEBOX = 0x00010000;
pub const WS_OVERLAPPEDWINDOW = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX;
pub const WS_EX_APPWINDOW = 0x00040000;
pub const WS_EX_NOREDIRECTIONBITMAP = 0x00200000;

pub const CS_VREDRAW = 0x0001;
pub const CS_HREDRAW = 0x0002;
pub const CS_OWNDC = 0x0020;

pub const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));

pub const GWL_STYLE: i32 = -16;
pub const GWL_EXSTYLE: i32 = -20;
pub const GWLP_USERDATA: i32 = -21;

pub const SW_HIDE = 0;
pub const SW_SHOWNORMAL = 1;
pub const SW_SHOWMINIMIZED = 2;
pub const SW_MAXIMIZE = 3;
pub const SW_SHOWNOACTIVATE = 4;
pub const SW_SHOW = 5;
pub const SW_MINIMIZE = 6;
pub const SW_SHOWNA = 8;
pub const SW_RESTORE = 9;

pub const SWP_NOSIZE = 0x0001;
pub const SWP_NOMOVE = 0x0002;
pub const SWP_NOZORDER = 0x0004;
pub const SWP_NOACTIVATE = 0x0010;
pub const SWP_FRAMECHANGED = 0x0020;
pub const SWP_NOOWNERZORDER = 0x0200;

pub const HWND_TOP: ?HWND = null;
/// Parent for message-only windows.
pub const HWND_MESSAGE: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));

pub const MONITOR_DEFAULTTONULL = 0;
pub const MONITOR_DEFAULTTOPRIMARY = 1;
pub const MONITOR_DEFAULTTONEAREST = 2;

pub const PM_NOREMOVE = 0x0000;
pub const PM_REMOVE = 0x0001;

pub const QS_ALLINPUT = 0x04FF;
pub const MWMO_INPUTAVAILABLE = 0x0004;
pub const WAIT_OBJECT_0 = 0;
pub const WAIT_TIMEOUT = 258;
pub const WAIT_FAILED = 0xFFFFFFFF;
pub const INFINITE = 0xFFFFFFFF;

pub const FLASHW_ALL = 0x00000003;
pub const FLASHW_TIMERNOFG = 0x0000000C;

pub const SM_CXDOUBLECLK = 36;
pub const SM_CYDOUBLECLK = 37;

pub const USER_TIMER_MINIMUM = 0x0000000A;

// -- DPI -------------------------------------------------------------------------------------

pub const DPI_AWARENESS_CONTEXT = ?*opaque {};
pub const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: DPI_AWARENESS_CONTEXT = @ptrFromInt(@as(usize, @bitCast(@as(isize, -4))));
pub const USER_DEFAULT_SCREEN_DPI = 96;

// -- cursors (MAKEINTRESOURCE ids) -------------------------------------------------------------

pub const IDC_ARROW: usize = 32512;
pub const IDC_IBEAM: usize = 32513;
pub const IDC_WAIT: usize = 32514;
pub const IDC_CROSS: usize = 32515;
pub const IDC_UPARROW: usize = 32516;
pub const IDC_SIZENWSE: usize = 32642;
pub const IDC_SIZENESW: usize = 32643;
pub const IDC_SIZEWE: usize = 32644;
pub const IDC_SIZENS: usize = 32645;
pub const IDC_SIZEALL: usize = 32646;
pub const IDC_NO: usize = 32648;
pub const IDC_HAND: usize = 32649;
pub const IDC_APPSTARTING: usize = 32650;
pub const IDC_HELP: usize = 32651;

// -- virtual keys ------------------------------------------------------------------------------

pub const VK_LBUTTON = 0x01;
pub const VK_CANCEL = 0x03;
pub const VK_BACK = 0x08;
pub const VK_TAB = 0x09;
pub const VK_CLEAR = 0x0C;
pub const VK_RETURN = 0x0D;
pub const VK_SHIFT = 0x10;
pub const VK_CONTROL = 0x11;
pub const VK_MENU = 0x12;
pub const VK_PAUSE = 0x13;
pub const VK_CAPITAL = 0x14;
pub const VK_KANA = 0x15;
pub const VK_JUNJA = 0x17;
pub const VK_FINAL = 0x18;
pub const VK_KANJI = 0x19;
pub const VK_ESCAPE = 0x1B;
pub const VK_CONVERT = 0x1C;
pub const VK_NONCONVERT = 0x1D;
pub const VK_ACCEPT = 0x1E;
pub const VK_MODECHANGE = 0x1F;
pub const VK_SPACE = 0x20;
pub const VK_PRIOR = 0x21;
pub const VK_NEXT = 0x22;
pub const VK_END = 0x23;
pub const VK_HOME = 0x24;
pub const VK_LEFT = 0x25;
pub const VK_UP = 0x26;
pub const VK_RIGHT = 0x27;
pub const VK_DOWN = 0x28;
pub const VK_SELECT = 0x29;
pub const VK_PRINT = 0x2A;
pub const VK_EXECUTE = 0x2B;
pub const VK_SNAPSHOT = 0x2C;
pub const VK_INSERT = 0x2D;
pub const VK_DELETE = 0x2E;
pub const VK_HELP = 0x2F;
pub const VK_LWIN = 0x5B;
pub const VK_RWIN = 0x5C;
pub const VK_APPS = 0x5D;
pub const VK_SLEEP = 0x5F;
pub const VK_NUMPAD0 = 0x60;
pub const VK_NUMPAD1 = 0x61;
pub const VK_NUMPAD2 = 0x62;
pub const VK_NUMPAD3 = 0x63;
pub const VK_NUMPAD4 = 0x64;
pub const VK_NUMPAD5 = 0x65;
pub const VK_NUMPAD6 = 0x66;
pub const VK_NUMPAD7 = 0x67;
pub const VK_NUMPAD8 = 0x68;
pub const VK_NUMPAD9 = 0x69;
pub const VK_MULTIPLY = 0x6A;
pub const VK_ADD = 0x6B;
pub const VK_SEPARATOR = 0x6C;
pub const VK_SUBTRACT = 0x6D;
pub const VK_DECIMAL = 0x6E;
pub const VK_DIVIDE = 0x6F;
pub const VK_F1 = 0x70;
pub const VK_F2 = 0x71;
pub const VK_F3 = 0x72;
pub const VK_F4 = 0x73;
pub const VK_F5 = 0x74;
pub const VK_F6 = 0x75;
pub const VK_F7 = 0x76;
pub const VK_F8 = 0x77;
pub const VK_F9 = 0x78;
pub const VK_F10 = 0x79;
pub const VK_F11 = 0x7A;
pub const VK_F12 = 0x7B;
pub const VK_F13 = 0x7C;
pub const VK_F24 = 0x87;
pub const VK_NUMLOCK = 0x90;
pub const VK_SCROLL = 0x91;
pub const VK_OEM_NEC_EQUAL = 0x92;
pub const VK_LSHIFT = 0xA0;
pub const VK_RSHIFT = 0xA1;
pub const VK_LCONTROL = 0xA2;
pub const VK_RCONTROL = 0xA3;
pub const VK_LMENU = 0xA4;
pub const VK_RMENU = 0xA5;
pub const VK_BROWSER_BACK = 0xA6;
pub const VK_BROWSER_FORWARD = 0xA7;
pub const VK_BROWSER_REFRESH = 0xA8;
pub const VK_BROWSER_STOP = 0xA9;
pub const VK_BROWSER_SEARCH = 0xAA;
pub const VK_BROWSER_FAVORITES = 0xAB;
pub const VK_BROWSER_HOME = 0xAC;
pub const VK_VOLUME_MUTE = 0xAD;
pub const VK_VOLUME_DOWN = 0xAE;
pub const VK_VOLUME_UP = 0xAF;
pub const VK_MEDIA_NEXT_TRACK = 0xB0;
pub const VK_MEDIA_PREV_TRACK = 0xB1;
pub const VK_MEDIA_STOP = 0xB2;
pub const VK_MEDIA_PLAY_PAUSE = 0xB3;
pub const VK_OEM_1 = 0xBA;
pub const VK_OEM_PLUS = 0xBB;
pub const VK_OEM_COMMA = 0xBC;
pub const VK_OEM_MINUS = 0xBD;
pub const VK_OEM_PERIOD = 0xBE;
pub const VK_OEM_2 = 0xBF;
pub const VK_OEM_3 = 0xC0;
pub const VK_OEM_4 = 0xDB;
pub const VK_OEM_5 = 0xDC;
pub const VK_OEM_6 = 0xDD;
pub const VK_OEM_7 = 0xDE;
pub const VK_OEM_8 = 0xDF;
pub const VK_OEM_102 = 0xE2;
pub const VK_PROCESSKEY = 0xE5;
pub const VK_PACKET = 0xE7;
pub const VK_ATTN = 0xF6;
pub const VK_CRSEL = 0xF7;
pub const VK_EXSEL = 0xF8;
pub const VK_PLAY = 0xFA;
pub const VK_ZOOM = 0xFB;
pub const VK_OEM_CLEAR = 0xFE;

pub const MAPVK_VK_TO_VSC = 0;
pub const MAPVK_VSC_TO_VK = 1;
pub const MAPVK_VK_TO_CHAR = 2;
pub const MAPVK_VSC_TO_VK_EX = 3;
pub const MAPVK_VK_TO_VSC_EX = 4;

// -- IME (imm32) --------------------------------------------------------------------------------

pub const GCS_COMPSTR = 0x0008;
pub const GCS_CURSORPOS = 0x0080;
pub const GCS_RESULTSTR = 0x0800;
pub const CFS_RECT = 0x0001;
pub const CFS_POINT = 0x0002;
pub const CFS_FORCE_POSITION = 0x0020;
pub const CFS_CANDIDATEPOS = 0x0040;
pub const CFS_EXCLUDE = 0x0080;
pub const ISC_SHOWUICOMPOSITIONWINDOW: LPARAM = 0x80000000;
pub const NI_COMPOSITIONSTR = 0x0015;
pub const CPS_COMPLETE = 0x0001;
pub const CPS_CANCEL = 0x0004;
pub const IACE_DEFAULT = 0x0010;

// -- clipboard ---------------------------------------------------------------------------------

pub const CF_UNICODETEXT = 13;
pub const GMEM_MOVEABLE = 0x0002;

// -- registry ----------------------------------------------------------------------------------

pub const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
pub const RRF_RT_REG_DWORD = 0x00000010;
pub const ERROR_SUCCESS = 0;
pub const ERROR_ALREADY_EXISTS = 183;
pub const ERROR_ACCESS_DENIED = 5;

// -- DWM ---------------------------------------------------------------------------------------

pub const DWMWA_USE_IMMERSIVE_DARK_MODE = 20;

// -- console -----------------------------------------------------------------------------------

pub const CTRL_C_EVENT = 0;
pub const CTRL_BREAK_EVENT = 1;
pub const CTRL_CLOSE_EVENT = 2;
pub const HANDLER_ROUTINE = *const fn (DWORD) callconv(WINAPI) BOOL;

pub const MONITORINFOF_PRIMARY = 0x00000001;
pub const MDT_EFFECTIVE_DPI = 0;

// -- shell -------------------------------------------------------------------------------------

pub const CSIDL_APPDATA = 0x001a;
pub const CSIDL_LOCAL_APPDATA = 0x001c;
pub const CSIDL_FLAG_CREATE = 0x8000;
pub const MAX_PATH = 260;

// -- helpers -----------------------------------------------------------------------------------

pub inline fn loword(v: anytype) u16 {
    return @truncate(@as(usize, @bitCast(@as(isize, @intCast(v)))));
}
pub inline fn hiword(v: anytype) u16 {
    return @truncate(@as(usize, @bitCast(@as(isize, @intCast(v)))) >> 16);
}
/// GET_X_LPARAM: signed low word.
pub inline fn xParam(lp: LPARAM) i32 {
    return @as(i16, @bitCast(loword(lp)));
}
/// GET_Y_LPARAM: signed high word.
pub inline fn yParam(lp: LPARAM) i32 {
    return @as(i16, @bitCast(hiword(lp)));
}
pub inline fn wheelDelta(wp: WPARAM) i16 {
    return @bitCast(hiword(wp));
}
pub inline fn makeLparam(lo: i32, hi: i32) LPARAM {
    const l: u32 = @as(u16, @bitCast(@as(i16, @truncate(lo))));
    const h: u32 = @as(u16, @bitCast(@as(i16, @truncate(hi))));
    return @as(i32, @bitCast(l | (h << 16)));
}
/// MAKEINTRESOURCEW: an integer id in a pointer slot. Odd ids (IDC_HAND = 32649) are not
/// u16-aligned, hence align(1).
pub const IntResource = [*:0]align(1) const u16;
pub inline fn makeIntResource(id: usize) IntResource {
    return @ptrFromInt(id);
}

pub fn succeeded(hr: HRESULT) bool {
    return hr >= 0;
}

// -- functions ---------------------------------------------------------------------------------

// user32
pub extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(WINAPI) ATOM;
pub extern "user32" fn UnregisterClassW([*:0]const u16, ?HINSTANCE) callconv(WINAPI) BOOL;
pub extern "user32" fn CreateWindowExW(ex: DWORD, class: [*:0]const u16, name: [*:0]const u16, style: DWORD, x: i32, y: i32, w: i32, h: i32, parent: ?HWND, menu: ?HMENU, inst: ?HINSTANCE, param: ?*anyopaque) callconv(WINAPI) ?HWND;
pub extern "user32" fn DestroyWindow(HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn DefWindowProcW(HWND, UINT, WPARAM, LPARAM) callconv(WINAPI) LRESULT;
pub extern "user32" fn ShowWindow(HWND, i32) callconv(WINAPI) BOOL;
pub extern "user32" fn IsWindowVisible(HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn IsIconic(HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn IsZoomed(HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn SetWindowTextW(HWND, [*:0]const u16) callconv(WINAPI) BOOL;
pub extern "user32" fn GetClientRect(HWND, *RECT) callconv(WINAPI) BOOL;
pub extern "user32" fn GetWindowRect(HWND, *RECT) callconv(WINAPI) BOOL;
pub extern "user32" fn SetWindowPos(HWND, ?HWND, i32, i32, i32, i32, UINT) callconv(WINAPI) BOOL;
pub extern "user32" fn AdjustWindowRectExForDpi(*RECT, DWORD, BOOL, DWORD, UINT) callconv(WINAPI) BOOL;
pub extern "user32" fn GetDpiForWindow(HWND) callconv(WINAPI) UINT;
pub extern "user32" fn GetDpiForSystem() callconv(WINAPI) UINT;
pub extern "user32" fn SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT) callconv(WINAPI) BOOL;
pub extern "user32" fn GetWindowLongPtrW(HWND, i32) callconv(WINAPI) isize;
pub extern "user32" fn SetWindowLongPtrW(HWND, i32, isize) callconv(WINAPI) isize;
pub extern "user32" fn GetWindowPlacement(HWND, *WINDOWPLACEMENT) callconv(WINAPI) BOOL;
pub extern "user32" fn SetWindowPlacement(HWND, *const WINDOWPLACEMENT) callconv(WINAPI) BOOL;
pub extern "user32" fn PeekMessageW(*MSG, ?HWND, UINT, UINT, UINT) callconv(WINAPI) BOOL;
pub extern "user32" fn TranslateMessage(*const MSG) callconv(WINAPI) BOOL;
pub extern "user32" fn DispatchMessageW(*const MSG) callconv(WINAPI) LRESULT;
pub extern "user32" fn PostMessageW(?HWND, UINT, WPARAM, LPARAM) callconv(WINAPI) BOOL;
pub extern "user32" fn SendMessageW(HWND, UINT, WPARAM, LPARAM) callconv(WINAPI) LRESULT;
pub extern "user32" fn MsgWaitForMultipleObjectsEx(DWORD, ?[*]const HANDLE, DWORD, DWORD, DWORD) callconv(WINAPI) DWORD;
pub extern "user32" fn GetMessageTime() callconv(WINAPI) LONG;
pub extern "user32" fn GetKeyState(i32) callconv(WINAPI) i16;
pub extern "user32" fn GetKeyboardState(*[256]u8) callconv(WINAPI) BOOL;
pub extern "user32" fn MapVirtualKeyW(UINT, UINT) callconv(WINAPI) UINT;
pub extern "user32" fn ToUnicode(UINT, UINT, *const [256]u8, [*]u16, i32, UINT) callconv(WINAPI) i32;
pub extern "user32" fn SetCapture(HWND) callconv(WINAPI) ?HWND;
pub extern "user32" fn ReleaseCapture() callconv(WINAPI) BOOL;
pub extern "user32" fn GetCapture() callconv(WINAPI) ?HWND;
pub extern "user32" fn TrackMouseEvent(*TRACKMOUSEEVENT) callconv(WINAPI) BOOL;
pub extern "user32" fn GetDoubleClickTime() callconv(WINAPI) UINT;
pub extern "user32" fn GetSystemMetricsForDpi(i32, UINT) callconv(WINAPI) i32;
pub extern "user32" fn GetSystemMetrics(i32) callconv(WINAPI) i32;
pub extern "user32" fn ScreenToClient(HWND, *POINT) callconv(WINAPI) BOOL;
pub extern "user32" fn ClientToScreen(HWND, *POINT) callconv(WINAPI) BOOL;
pub extern "user32" fn LoadCursorW(?HINSTANCE, IntResource) callconv(WINAPI) ?HCURSOR;
pub extern "user32" fn LoadImageW(?HINSTANCE, IntResource, UINT, i32, i32, UINT) callconv(WINAPI) ?HANDLE;
pub const IMAGE_ICON: UINT = 1;
pub const LR_SHARED: UINT = 0x8000;
pub const SM_CXICON: i32 = 11;
pub const SM_CYICON: i32 = 12;
pub const SM_CXSMICON: i32 = 49;
pub const SM_CYSMICON: i32 = 50;
pub extern "user32" fn SetCursor(?HCURSOR) callconv(WINAPI) ?HCURSOR;
pub extern "user32" fn OpenClipboard(?HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn CloseClipboard() callconv(WINAPI) BOOL;
pub extern "user32" fn EmptyClipboard() callconv(WINAPI) BOOL;
pub extern "user32" fn SetClipboardData(UINT, ?HANDLE) callconv(WINAPI) ?HANDLE;
pub extern "user32" fn GetClipboardData(UINT) callconv(WINAPI) ?HANDLE;
pub extern "user32" fn GetClipboardSequenceNumber() callconv(WINAPI) DWORD;
pub extern "user32" fn AddClipboardFormatListener(HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn RemoveClipboardFormatListener(HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn SetForegroundWindow(HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn GetForegroundWindow() callconv(WINAPI) ?HWND;
pub extern "user32" fn BringWindowToTop(HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn SetFocus(?HWND) callconv(WINAPI) ?HWND;
pub extern "user32" fn GetFocus() callconv(WINAPI) ?HWND;
pub extern "user32" fn FlashWindowEx(*const FLASHWINFO) callconv(WINAPI) BOOL;
pub extern "user32" fn MonitorFromWindow(HWND, DWORD) callconv(WINAPI) ?HMONITOR;
pub extern "user32" fn MonitorFromPoint(POINT, DWORD) callconv(WINAPI) ?HMONITOR;
pub extern "user32" fn GetMonitorInfoW(HMONITOR, *MONITORINFO) callconv(WINAPI) BOOL;
pub extern "user32" fn SetTimer(?HWND, usize, UINT, ?*anyopaque) callconv(WINAPI) usize;
pub extern "user32" fn KillTimer(?HWND, usize) callconv(WINAPI) BOOL;
pub extern "user32" fn BeginPaint(HWND, *PAINTSTRUCT) callconv(WINAPI) ?HDC;
pub extern "user32" fn EndPaint(HWND, *const PAINTSTRUCT) callconv(WINAPI) BOOL;
pub extern "user32" fn IsChild(HWND, HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn PostQuitMessage(i32) callconv(WINAPI) void;

// kernel32
pub extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(WINAPI) ?HMODULE;
pub extern "kernel32" fn GetLastError() callconv(WINAPI) DWORD;
pub extern "kernel32" fn GetCurrentThreadId() callconv(WINAPI) DWORD;
pub extern "kernel32" fn CreateEventW(?*anyopaque, BOOL, BOOL, ?[*:0]const u16) callconv(WINAPI) ?HANDLE;
pub extern "kernel32" fn SetEvent(HANDLE) callconv(WINAPI) BOOL;
pub extern "kernel32" fn CloseHandle(HANDLE) callconv(WINAPI) BOOL;
pub extern "kernel32" fn WaitForSingleObject(HANDLE, DWORD) callconv(WINAPI) DWORD;
pub extern "kernel32" fn GlobalAlloc(UINT, usize) callconv(WINAPI) ?HGLOBAL;
pub extern "kernel32" fn GlobalLock(HGLOBAL) callconv(WINAPI) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(HGLOBAL) callconv(WINAPI) BOOL;
pub extern "kernel32" fn GlobalFree(HGLOBAL) callconv(WINAPI) ?HGLOBAL;
pub extern "kernel32" fn GlobalSize(HGLOBAL) callconv(WINAPI) usize;
pub extern "kernel32" fn SetConsoleCtrlHandler(?HANDLER_ROUTINE, BOOL) callconv(WINAPI) BOOL;
pub extern "kernel32" fn CreateDirectoryW([*:0]const u16, ?*anyopaque) callconv(WINAPI) BOOL;
pub extern "kernel32" fn GetEnvironmentVariableW([*:0]const u16, ?[*]u16, DWORD) callconv(WINAPI) DWORD;
pub extern "kernel32" fn GetWindowsDirectoryW([*]u16, UINT) callconv(WINAPI) UINT;
pub extern "kernel32" fn QueryPerformanceCounter(*i64) callconv(WINAPI) BOOL;
pub extern "kernel32" fn QueryPerformanceFrequency(*i64) callconv(WINAPI) BOOL;
pub extern "kernel32" fn Sleep(DWORD) callconv(WINAPI) void;

// imm32
pub extern "imm32" fn ImmGetContext(HWND) callconv(WINAPI) ?HIMC;
pub extern "imm32" fn ImmReleaseContext(HWND, HIMC) callconv(WINAPI) BOOL;
pub extern "imm32" fn ImmGetCompositionStringW(HIMC, DWORD, ?*anyopaque, DWORD) callconv(WINAPI) LONG;
pub extern "imm32" fn ImmSetCompositionWindow(HIMC, *const COMPOSITIONFORM) callconv(WINAPI) BOOL;
pub extern "imm32" fn ImmSetCandidateWindow(HIMC, *const CANDIDATEFORM) callconv(WINAPI) BOOL;
pub extern "imm32" fn ImmAssociateContextEx(HWND, ?HIMC, DWORD) callconv(WINAPI) BOOL;
pub extern "imm32" fn ImmNotifyIME(HIMC, DWORD, DWORD, DWORD) callconv(WINAPI) BOOL;

// dwmapi
pub extern "dwmapi" fn DwmSetWindowAttribute(HWND, DWORD, *const anyopaque, DWORD) callconv(WINAPI) HRESULT;
pub extern "dwmapi" fn DwmFlush() callconv(WINAPI) HRESULT;

// advapi32
pub extern "advapi32" fn RegGetValueW(HKEY, ?[*:0]const u16, ?[*:0]const u16, DWORD, ?*DWORD, ?*anyopaque, ?*DWORD) callconv(WINAPI) LONG;

// shell32
pub extern "shcore" fn GetDpiForMonitor(HMONITOR, i32, *UINT, *UINT) callconv(WINAPI) HRESULT;
pub extern "shell32" fn SHGetFolderPathW(?HWND, i32, ?HANDLE, DWORD, [*]u16) callconv(WINAPI) HRESULT;

// -- UTF-16 helpers -------------------------------------------------------------------------------

/// Comptime UTF-16 literal.
pub fn L(comptime s: []const u8) [:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

/// UTF-8 → NUL-terminated UTF-16 into `buf`; invalid UTF-8 becomes U+FFFD; truncates.
pub fn utf8ToUtf16Z(buf: []u16, s: []const u8) [:0]u16 {
    std.debug.assert(buf.len > 0);
    var n: usize = 0;
    var view = std.unicode.Wtf8View.init(s) catch {
        // Lossy fallback, byte by byte.
        for (s) |c| {
            if (n + 1 >= buf.len) break;
            buf[n] = if (c < 0x80) c else 0xFFFD;
            n += 1;
        }
        buf[n] = 0;
        return buf[0..n :0];
    };
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x10000) {
            if (n + 1 >= buf.len) break;
            buf[n] = @intCast(cp);
            n += 1;
        } else {
            if (n + 2 >= buf.len) break;
            const v = cp - 0x10000;
            buf[n] = @intCast(0xD800 + (v >> 10));
            buf[n + 1] = @intCast(0xDC00 + (v & 0x3FF));
            n += 2;
        }
    }
    buf[n] = 0;
    return buf[0..n :0];
}

test "lparam helpers" {
    const lp = makeLparam(-5, 300);
    try std.testing.expectEqual(@as(i32, -5), xParam(lp));
    try std.testing.expectEqual(@as(i32, 300), yParam(lp));
    const wp: WPARAM = @as(WPARAM, @as(u16, @bitCast(@as(i16, -240)))) << 16;
    try std.testing.expectEqual(@as(i16, -240), wheelDelta(wp));
}

test "utf8 to utf16" {
    var buf: [16]u16 = undefined;
    const out = utf8ToUtf16Z(&buf, "a\xc3\xa9\xf0\x9f\x98\x80");
    try std.testing.expectEqualSlices(u16, &.{ 'a', 0xE9, 0xD83D, 0xDE00 }, out);
}
