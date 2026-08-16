//! Terminal engine boundary (issue #101): the only file that imports the
//! upstream `ghostty-vt` Zig module. Verde code names engine types through
//! this adapter so an upstream pin bump is a one-file audit surface.
const root = @import("ghostty-vt");

pub const Cell = root.Cell;
pub const RenderState = root.RenderState;
pub const Style = root.Style;
pub const Stream = root.Stream;
pub const Terminal = root.Terminal;
pub const MouseShape = root.MouseShape;
pub const RGB = root.color.RGB;
pub const color = root.color;
pub const input = root.input;
pub const kitty = root.kitty;
pub const PageList = root.PageList;
pub const size_report = root.size_report;
pub const sys = root.sys;
pub const TinyIo = root.TinyIo;
