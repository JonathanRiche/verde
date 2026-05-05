//! Public API for the powder SDL_GPU UI package.

const std = @import("std");

pub const atlas = @import("atlas.zig");
pub const draw = @import("draw.zig");
pub const image_loader = @import("image_loader.zig");
pub const input_clipboard = @import("input/clipboard.zig");
pub const input_key = @import("input/key.zig");
pub const input_selection = @import("input/selection.zig");
pub const layout = @import("layout.zig");
pub const renderer = @import("renderer.zig");
pub const scroll = @import("scroll.zig");
pub const sdl = @import("sdl.zig");
pub const button_component = @import("components/button.zig");
pub const checkbox_component = @import("components/checkbox.zig");
pub const code_view_component = @import("components/code_view.zig");
pub const image_component = @import("components/image.zig");
pub const list_box_component = @import("components/list_box.zig");
pub const menu_component = @import("components/menu.zig");
pub const modal_component = @import("components/modal.zig");
pub const scroll_area_component = @import("components/scroll_area.zig");
pub const select_component = @import("components/select.zig");
pub const table_component = @import("components/table.zig");
pub const tabs_component = @import("components/tabs.zig");
pub const text_component = @import("components/text.zig");
pub const text_area_component = @import("components/text_area.zig");
pub const text_input_component = @import("components/text_input.zig");
pub const text_layout = @import("text_layout.zig");

pub const Color = draw.Color;
pub const Rect = draw.Rect;
pub const RenderBatch = draw.RenderBatch;
pub const TextureId = draw.TextureId;
pub const TextRun = draw.TextRun;
pub const Renderer = renderer.Renderer;
pub const FontAtlas = atlas.FontAtlas;
pub const ButtonCallbacks = button_component.ButtonCallbacks;
pub const ButtonConfig = button_component.ButtonConfig;
pub const ButtonContentAlign = button_component.ButtonContentAlign;
pub const ButtonEvent = button_component.ButtonEvent;
pub const CheckboxCallbacks = checkbox_component.CheckboxCallbacks;
pub const CheckboxConfig = checkbox_component.CheckboxConfig;
pub const CheckboxEvent = checkbox_component.CheckboxEvent;
pub const CodeViewConfig = code_view_component.CodeViewConfig;
pub const IconButtonConfig = button_component.IconButtonConfig;
pub const ImageConfig = image_component.ImageConfig;
pub const ImageFit = image_component.ImageFit;
pub const LoadedImage = image_loader.LoadedImage;
pub const ListBoxCallbacks = list_box_component.ListBoxCallbacks;
pub const ListBoxConfig = list_box_component.ListBoxConfig;
pub const ListBoxEvent = list_box_component.ListBoxEvent;
pub const MenuCallbacks = menu_component.MenuCallbacks;
pub const MenuConfig = menu_component.MenuConfig;
pub const MenuEvent = menu_component.MenuEvent;
pub const ModalCallbacks = modal_component.ModalCallbacks;
pub const ModalConfig = modal_component.ModalConfig;
pub const ModalEvent = modal_component.ModalEvent;
pub const ScrollAreaCallbacks = scroll_area_component.ScrollAreaCallbacks;
pub const ScrollAreaConfig = scroll_area_component.ScrollAreaConfig;
pub const ScrollAreaEvent = scroll_area_component.ScrollAreaEvent;
pub const SelectCallbacks = select_component.SelectCallbacks;
pub const SelectConfig = select_component.SelectConfig;
pub const SelectEvent = select_component.SelectEvent;
pub const TabsCallbacks = tabs_component.TabsCallbacks;
pub const TabsConfig = tabs_component.TabsConfig;
pub const TabsEvent = tabs_component.TabsEvent;
pub const TableCallbacks = table_component.TableCallbacks;
pub const TableConfig = table_component.TableConfig;
pub const TableEvent = table_component.TableEvent;
pub const Text = text_component.Text;
pub const TextCallbacks = text_component.TextCallbacks;
pub const TextEvent = text_component.TextEvent;
pub const TextArea = text_area_component.TextArea;
pub const TextAreaAction = text_area_component.TextAreaAction;
pub const TextAreaCallbacks = text_area_component.TextAreaCallbacks;
pub const TextAreaConfig = text_area_component.TextAreaConfig;
pub const TextAreaEvent = text_area_component.TextAreaEvent;
pub const TextAreaKey = text_area_component.Key;
pub const TextInputAction = text_input_component.TextInputAction;
pub const TextInputCallbacks = text_input_component.TextInputCallbacks;
pub const TextInputConfig = text_input_component.TextInputConfig;
pub const TextInputEvent = text_input_component.TextInputEvent;
pub const ClipboardCallbacks = input_clipboard;
pub const Key = input_key;
pub const ImageLoader = image_loader;
pub const Layout = layout;
pub const LayoutAlign = layout.Align;
pub const LayoutBox = layout.Box;
pub const LayoutEdges = layout.Edges;
pub const LayoutFlexConfig = layout.FlexConfig;
pub const LayoutFlexDirection = layout.FlexDirection;
pub const LayoutFlexItem = layout.FlexItem;
pub const LayoutGridConfig = layout.GridConfig;
pub const LayoutGridItem = layout.GridItem;
pub const LayoutJustify = layout.Justify;
pub const LayoutTrack = layout.Track;
pub const FontAdvance = text_layout.Advance;
pub const FontAdvanceFn = text_layout.AdvanceFn;
pub const FontMetrics = text_layout.FontMetrics;
pub const TextLayout = text_layout;
pub const ScrollState = scroll;
pub const SelectionRange = input_selection.Range;
pub const SelectionState = input_selection;

/// Creates a retained code viewer with comptime styling.
pub fn codeView(comptime config: CodeViewConfig) type {
    return code_view_component.CodeView(config);
}

/// Creates a retained diff viewer with comptime styling.
pub fn diffView(comptime config: CodeViewConfig) type {
    return code_view_component.DiffView(config);
}

/// Creates a retained button with comptime styling.
pub fn button(comptime config: ButtonConfig) type {
    return button_component.Button(config);
}

/// Creates a retained icon button with comptime styling.
pub fn iconButton(comptime config: IconButtonConfig) type {
    return button_component.IconButton(config);
}

/// Creates a retained image component with comptime styling.
pub fn image(comptime config: ImageConfig) type {
    return image_component.Image(config);
}

/// Creates a retained checkbox with comptime styling.
pub fn checkbox(comptime config: CheckboxConfig) type {
    return checkbox_component.Checkbox(config);
}

/// Creates a retained toggle with comptime styling.
pub fn toggle(comptime config: checkbox_component.ToggleConfig) type {
    return checkbox_component.Toggle(config);
}

/// Creates a retained listbox with comptime styling.
pub fn listBox(comptime config: ListBoxConfig) type {
    return list_box_component.ListBox(config);
}

/// Creates a retained popup menu with comptime styling.
pub fn menu(comptime config: MenuConfig) type {
    return menu_component.Menu(config);
}

/// Creates a retained modal with comptime styling.
pub fn modal(comptime config: ModalConfig) type {
    return modal_component.Modal(config);
}

/// Creates a retained select/dropdown with comptime styling.
pub fn select(comptime config: SelectConfig) type {
    return select_component.Select(config);
}

/// Creates a retained table with comptime styling.
pub fn table(comptime config: TableConfig) type {
    return table_component.Table(config);
}

/// Creates a retained scroll area with comptime styling.
pub fn scrollArea(comptime config: ScrollAreaConfig) type {
    return scroll_area_component.ScrollArea(config);
}

/// Creates a retained tab strip with comptime styling.
pub fn tabs(comptime config: TabsConfig) type {
    return tabs_component.Tabs(config);
}

/// Creates a retained text label type with comptime styling.
pub fn text(comptime config: text_component.TextConfig) type {
    return text_component.Text(config);
}

/// Creates a retained single-line text input with comptime styling.
pub fn textInput(comptime config: TextInputConfig) type {
    return text_input_component.TextInput(config);
}

/// Creates a retained text-area type with comptime styling.
pub fn textArea(comptime config: TextAreaConfig) type {
    return text_area_component.TextArea(config);
}

test {
    _ = draw;
    _ = image_loader;
    _ = input_clipboard;
    _ = input_key;
    _ = input_selection;
    _ = layout;
    _ = scroll;
    _ = button_component;
    _ = checkbox_component;
    _ = code_view_component;
    _ = image_component;
    _ = list_box_component;
    _ = menu_component;
    _ = modal_component;
    _ = scroll_area_component;
    _ = select_component;
    _ = table_component;
    _ = tabs_component;
    _ = text_component;
    _ = text_area_component;
    _ = text_input_component;
}
