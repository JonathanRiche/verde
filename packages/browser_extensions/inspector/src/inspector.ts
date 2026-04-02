import type {
  InspectorAnyEvent,
  ElementBoxModel,
  ElementBoxRect,
  ElementSnapshot,
  InspectorEvent,
  InspectorEventPayloadMap,
  InspectorEventType,
  InspectorHandle,
  InspectorOptions,
} from "./types";

const OVERLAY_ROOT_ID = "verde-inspector-overlay-root";
const OVERLAY_IGNORE_ATTR = "data-verde-inspector-ignore";
const BOX_ATTR = "data-verde-box";
const VERDE_RGB = "34, 197, 94";
const VERDE_BUTTON_BG = "#16a34a";
const VERDE_BORDER_GLOW = "rgba(240, 253, 244, 0.98)";
const OVERLAY_MARGIN_FILL = `rgba(${VERDE_RGB}, 0.12)`;
const OVERLAY_BORDER_FILL = `rgba(${VERDE_RGB}, 0.19)`;
const OVERLAY_PADDING_FILL = `rgba(${VERDE_RGB}, 0.29)`;
const OVERLAY_CONTENT_FILL = `rgba(${VERDE_RGB}, 0.05)`;
const OVERLAY_STROKE = `rgba(${VERDE_RGB}, 0.05)`;

type OverlayParts = {
  root: HTMLDivElement;
  margin: HTMLDivElement;
  border: HTMLDivElement;
  padding: HTMLDivElement;
  content: HTMLDivElement;
  tooltip: HTMLDivElement;
  promptPanel: HTMLDivElement;
  promptTitle: HTMLDivElement;
  promptMeta: HTMLDivElement;
  promptTextarea: HTMLTextAreaElement;
  promptActions: HTMLDivElement;
  promptButton: HTMLButtonElement;
};

export function createInspector(options: InspectorOptions = {}): InspectorHandle {
  const doc = options.root ?? document;
  const win = doc.defaultView ?? window;
  const onEvent = options.onEvent;
  const bridge = options.bridge;

  let enabled = false;
  let destroyed = false;
  let hoveredElement: Element | null = null;
  let selectedElement: Element | null = null;
  let selectedSnapshot: ElementSnapshot | null = null;
  let lastHoverSelector = "";

  const overlay = createOverlay(doc);

  const emit = <TType extends InspectorEventType>(
    type: TType,
    payload: InspectorEventPayloadMap[TType],
  ): void => {
    const event: InspectorEvent<TType> = {
      source: "verde-inspector",
      type,
      payload,
      timestamp: Date.now(),
    };
    const forwarded = event as InspectorAnyEvent;
    onEvent?.(forwarded);
    bridge?.postMessage(forwarded);
    win.dispatchEvent(
      new CustomEvent("verde-inspector:event", {
        detail: forwarded,
      }),
    );
  };

  const hideOverlay = (): void => {
    overlay.root.style.display = "none";
    overlay.tooltip.style.opacity = "0";
  };

  const showOverlay = (): void => {
    overlay.root.style.display = "block";
  };

  const syncPrompt = (snapshot: ElementSnapshot | null): void => {
    if (!snapshot) {
      overlay.promptPanel.hidden = true;
      overlay.promptTextarea.value = "";
      return;
    }

    overlay.promptPanel.hidden = false;
    overlay.promptTitle.textContent = `Selected: ${snapshot.selector}`;
    overlay.promptMeta.textContent = `${snapshot.rect.width} x ${snapshot.rect.height} at (${snapshot.rect.x}, ${snapshot.rect.y})`;
  };

  const updateBox = (node: Element): void => {
    const snapshot = snapshotElement(node);
    positionBox(overlay.margin, snapshot.boxModel.margin);
    positionBox(overlay.border, snapshot.boxModel.border);
    positionBox(overlay.padding, snapshot.boxModel.padding);
    positionBox(overlay.content, snapshot.boxModel.content);

    overlay.tooltip.textContent = `${snapshot.selector}  ${Math.round(snapshot.rect.width)} x ${Math.round(snapshot.rect.height)}`;
    overlay.tooltip.style.transform = `translate(${Math.max(snapshot.rect.x, 8)}px, ${Math.max(snapshot.rect.y - 30, 8)}px)`;
    overlay.tooltip.style.opacity = "1";
    showOverlay();

    if (snapshot.selector !== lastHoverSelector) {
      lastHoverSelector = snapshot.selector;
      emit("element:hover", snapshot);
    }
  };

  const clearHover = (): void => {
    hoveredElement = null;
    lastHoverSelector = "";
    if (selectedElement == null) {
      hideOverlay();
    }
  };

  const setSelected = (node: Element): void => {
    selectedElement = node;
    selectedSnapshot = snapshotElement(node);
    updateBox(node);
    syncPrompt(selectedSnapshot);
    emit("element:selected", selectedSnapshot);
    overlay.promptTextarea.focus();
    overlay.promptTextarea.select();
  };

  const pickTarget = (
    eventTarget: EventTarget | null,
    clientX: number,
    clientY: number,
    path: EventTarget[] = [],
  ): Element | null => {
    for (const item of path) {
      if (!(item instanceof Element)) continue;
      if (shouldIgnoreElement(item)) continue;
      if (item === doc.documentElement || item === doc.body) continue;
      return item;
    }

    const stacked = doc.elementsFromPoint(clientX, clientY);
    for (const candidate of stacked) {
      if (shouldIgnoreElement(candidate)) continue;
      if (candidate === doc.documentElement || candidate === doc.body) continue;
      return candidate;
    }

    const directTarget = eventTarget instanceof Element ? eventTarget : null;
    if (
      directTarget &&
      !shouldIgnoreElement(directTarget) &&
      directTarget !== doc.documentElement &&
      directTarget !== doc.body
    ) {
      return directTarget;
    }

    const fromPoint = doc.elementFromPoint(clientX, clientY);
    if (
      fromPoint &&
      !shouldIgnoreElement(fromPoint) &&
      fromPoint !== doc.documentElement &&
      fromPoint !== doc.body
    ) {
      return fromPoint;
    }

    return directTarget ?? fromPoint;
  };

  const handlePointerMove = (event: MouseEvent): void => {
    if (!enabled || destroyed || selectedElement) return;

    const path = event.composedPath().filter(
      (item): item is EventTarget => item !== undefined,
    );
    const target = pickTarget(
      event.target,
      event.clientX,
      event.clientY,
      path,
    );
    if (!target) {
      clearHover();
      return;
    }

    hoveredElement = target;
    updateBox(target);
  };

  const handlePointerLeave = (): void => {
    if (!enabled || destroyed || selectedElement) return;
    clearHover();
  };

  const handleClick = (event: MouseEvent): void => {
    if (!enabled || destroyed) return;
    if (isInsidePrompt(event.target)) return;

    const path = event.composedPath().filter(
      (item): item is EventTarget => item !== undefined,
    );
    const target = pickTarget(
      event.target,
      event.clientX,
      event.clientY,
      path,
    );
    if (!target) return;

    event.preventDefault();
    event.stopPropagation();
    event.stopImmediatePropagation();
    setSelected(target);
  };

  const handleKeyDown = (event: KeyboardEvent): void => {
    if (!enabled || destroyed) return;

    if (event.key === "Escape") {
      event.preventDefault();
      if (selectedElement) {
        selectedElement = null;
        selectedSnapshot = null;
        syncPrompt(null);
        if (hoveredElement) {
          updateBox(hoveredElement);
        } else {
          hideOverlay();
        }
        return;
      }

      disable();
    }
  };

  overlay.promptTextarea.addEventListener("input", () => {
    if (!selectedSnapshot) return;
    emit("prompt:changed", {
      element: selectedSnapshot,
      prompt: overlay.promptTextarea.value,
    });
  });

  overlay.promptButton.addEventListener("click", () => {
    if (!selectedSnapshot) return;
    emit("prompt:submitted", {
      element: selectedSnapshot,
      prompt: overlay.promptTextarea.value.trim(),
    });
  });

  const enable = (): void => {
    if (destroyed || enabled) return;
    enabled = true;
    doc.addEventListener("mousemove", handlePointerMove, true);
    doc.addEventListener("mouseout", handlePointerLeave, true);
    doc.addEventListener("click", handleClick, true);
    doc.addEventListener("keydown", handleKeyDown, true);
    doc.documentElement.appendChild(overlay.root);
    syncPrompt(selectedSnapshot);
    emit("inspector:enabled", null);
  };

  const disable = (): void => {
    if (destroyed || !enabled) return;
    enabled = false;
    hoveredElement = null;
    selectedElement = null;
    selectedSnapshot = null;
    lastHoverSelector = "";
    doc.removeEventListener("mousemove", handlePointerMove, true);
    doc.removeEventListener("mouseout", handlePointerLeave, true);
    doc.removeEventListener("click", handleClick, true);
    doc.removeEventListener("keydown", handleKeyDown, true);
    syncPrompt(null);
    hideOverlay();
    emit("inspector:disabled", null);
  };

  const destroy = (): void => {
    if (destroyed) return;
    disable();
    destroyed = true;
    overlay.root.remove();
  };

  if (options.enabled ?? true) {
    enable();
  }

  return {
    enable,
    disable,
    destroy,
    isEnabled: () => enabled,
    getSelectedElement: () => selectedSnapshot,
  };
}

function createOverlay(doc: Document): OverlayParts {
  const root = doc.createElement("div");
  root.id = OVERLAY_ROOT_ID;
  root.setAttribute(OVERLAY_IGNORE_ATTR, "true");
  root.style.cssText = [
    "position:fixed",
    "inset:0",
    "pointer-events:none",
    "z-index:2147483647",
    "display:none",
    "font-family:ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace",
  ].join(";");

  const margin = createBox(doc, "margin", OVERLAY_MARGIN_FILL);
  const border = createBox(doc, "border", OVERLAY_BORDER_FILL);
  const padding = createBox(doc, "padding", OVERLAY_PADDING_FILL);
  const content = createBox(doc, "content", OVERLAY_CONTENT_FILL);

  const tooltip = doc.createElement("div");
  tooltip.setAttribute(OVERLAY_IGNORE_ATTR, "true");
  tooltip.style.cssText = [
    "position:fixed",
    "left:0",
    "top:0",
    "transform:translate(8px, 8px)",
    "padding:6px 10px",
    "border-radius:999px",
    "background:rgba(15, 23, 42, 0.92)",
    "color:#eff6ff",
    "font-size:12px",
    "line-height:1",
    "white-space:nowrap",
    "box-shadow:0 10px 30px rgba(15, 23, 42, 0.25)",
    "opacity:0",
  ].join(";");

  const promptPanel = doc.createElement("div");
  promptPanel.hidden = true;
  promptPanel.setAttribute(OVERLAY_IGNORE_ATTR, "true");
  promptPanel.style.cssText = [
    "position:fixed",
    "right:20px",
    "bottom:20px",
    "width:min(420px, calc(100vw - 40px))",
    "padding:14px",
    "border:1px solid rgba(148, 163, 184, 0.35)",
    "border-radius:16px",
    "background:rgba(15, 23, 42, 0.94)",
    "color:#e2e8f0",
    "box-shadow:0 24px 80px rgba(2, 6, 23, 0.45)",
    "backdrop-filter:blur(14px)",
    "pointer-events:auto",
  ].join(";");

  const promptTitle = doc.createElement("div");
  promptTitle.setAttribute(OVERLAY_IGNORE_ATTR, "true");
  promptTitle.style.cssText = "font-size:12px;font-weight:700;color:#f8fafc;margin-bottom:6px;";

  const promptMeta = doc.createElement("div");
  promptMeta.setAttribute(OVERLAY_IGNORE_ATTR, "true");
  promptMeta.style.cssText = "font-size:11px;color:#94a3b8;margin-bottom:10px;";

  const promptTextarea = doc.createElement("textarea");
  promptTextarea.setAttribute(OVERLAY_IGNORE_ATTR, "true");
  promptTextarea.placeholder = "Describe what you want to do with this element...";
  promptTextarea.style.cssText = [
    "display:block",
    "width:100%",
    "min-height:128px",
    "resize:vertical",
    "padding:12px",
    "border-radius:12px",
    "border:1px solid rgba(148, 163, 184, 0.3)",
    "background:rgba(2, 6, 23, 0.8)",
    "color:#f8fafc",
    "font:inherit",
    "box-sizing:border-box",
    "outline:none",
  ].join(";");

  const promptActions = doc.createElement("div");
  promptActions.setAttribute(OVERLAY_IGNORE_ATTR, "true");
  promptActions.style.cssText = "display:flex;justify-content:flex-end;margin-top:10px;";

  const promptButton = doc.createElement("button");
  promptButton.type = "button";
  promptButton.textContent = "Send prompt";
  promptButton.setAttribute(OVERLAY_IGNORE_ATTR, "true");
  promptButton.style.cssText = [
    "pointer-events:auto",
    "padding:10px 14px",
    "border:0",
    "border-radius:999px",
    `background:${VERDE_BUTTON_BG}`,
    "color:white",
    "font:inherit",
    "font-weight:700",
    "cursor:pointer",
  ].join(";");

  promptActions.appendChild(promptButton);
  promptPanel.append(promptTitle, promptMeta, promptTextarea, promptActions);
  root.append(margin, border, padding, content, tooltip, promptPanel);

  return {
    root,
    margin,
    border,
    padding,
    content,
    tooltip,
    promptPanel,
    promptTitle,
    promptMeta,
    promptTextarea,
    promptActions,
    promptButton,
  };
}

function createBox(doc: Document, name: string, background: string): HTMLDivElement {
  const box = doc.createElement("div");
  box.setAttribute(OVERLAY_IGNORE_ATTR, "true");
  box.setAttribute(BOX_ATTR, name);
  box.style.cssText = [
    "position:fixed",
    "left:0",
    "top:0",
    "box-sizing:border-box",
    "pointer-events:none",
    "background:" + background,
    name === "content"
      ? `border:1px solid ${VERDE_BORDER_GLOW}`
      : `border:1px solid ${OVERLAY_STROKE}`,
  ].join(";");
  return box;
}

function positionBox(node: HTMLDivElement, rect: ElementBoxRect): void {
  node.style.transform = `translate(${rect.x}px, ${rect.y}px)`;
  node.style.width = `${Math.max(rect.width, 0)}px`;
  node.style.height = `${Math.max(rect.height, 0)}px`;
}

function snapshotElement(node: Element): ElementSnapshot {
  const element = node as HTMLElement;
  const rect = element.getBoundingClientRect();
  const style = window.getComputedStyle(element);
  const borderLeft = parsePixelValue(style.borderLeftWidth);
  const borderRight = parsePixelValue(style.borderRightWidth);
  const borderTop = parsePixelValue(style.borderTopWidth);
  const borderBottom = parsePixelValue(style.borderBottomWidth);
  const paddingLeft = parsePixelValue(style.paddingLeft);
  const paddingRight = parsePixelValue(style.paddingRight);
  const paddingTop = parsePixelValue(style.paddingTop);
  const paddingBottom = parsePixelValue(style.paddingBottom);
  const marginLeft = parsePixelValue(style.marginLeft);
  const marginRight = parsePixelValue(style.marginRight);
  const marginTop = parsePixelValue(style.marginTop);
  const marginBottom = parsePixelValue(style.marginBottom);

  const borderRect = normalizeRect(rect.left, rect.top, rect.width, rect.height);
  const paddingRect = normalizeRect(
    rect.left + borderLeft,
    rect.top + borderTop,
    rect.width - borderLeft - borderRight,
    rect.height - borderTop - borderBottom,
  );
  const contentRect = normalizeRect(
    paddingRect.x + paddingLeft,
    paddingRect.y + paddingTop,
    paddingRect.width - paddingLeft - paddingRight,
    paddingRect.height - paddingTop - paddingBottom,
  );
  const marginRect = normalizeRect(
    rect.left - marginLeft,
    rect.top - marginTop,
    rect.width + marginLeft + marginRight,
    rect.height + marginTop + marginBottom,
  );

  return {
    tagName: element.tagName.toLowerCase(),
    id: element.id || null,
    className: normalizeWhitespace(element.className),
    selector: buildSelector(element),
    textSnippet: normalizeWhitespace(element.textContent ?? "").slice(0, 140),
    href: element instanceof HTMLAnchorElement ? element.href : element.getAttribute("href"),
    ariaLabel: element.getAttribute("aria-label"),
    rect: borderRect,
    boxModel: {
      margin: marginRect,
      border: borderRect,
      padding: paddingRect,
      content: contentRect,
    },
  };
}

function normalizeRect(x: number, y: number, width: number, height: number): ElementBoxRect {
  return {
    x: round2(x),
    y: round2(y),
    width: round2(Math.max(width, 0)),
    height: round2(Math.max(height, 0)),
  };
}

function round2(value: number): number {
  return Math.round(value * 100) / 100;
}

function parsePixelValue(value: string): number {
  const parsed = Number.parseFloat(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function normalizeWhitespace(value: string): string {
  return value.replace(/\s+/g, " ").trim();
}

function buildSelector(element: Element): string {
  if (element.id) {
    return `#${escapeIdent(element.id)}`;
  }

  const parts: string[] = [];
  let current: Element | null = element;

  while (current && current.nodeType === Node.ELEMENT_NODE && parts.length < 5) {
    let segment = current.tagName.toLowerCase();
    const classList = [...current.classList]
      .filter((name) => name && !name.startsWith("verde-"))
      .slice(0, 2);

    if (classList.length > 0) {
      segment += classList.map((name) => `.${escapeIdent(name)}`).join("");
    }

    const parent: Element | null = current.parentElement;
    if (parent) {
      const siblings = [...parent.children].filter(
        (child) => child.tagName === current?.tagName,
      );
      if (siblings.length > 1) {
        segment += `:nth-of-type(${siblings.indexOf(current) + 1})`;
      }
    }

    parts.unshift(segment);
    current = parent;
  }

  return parts.join(" > ");
}

function escapeIdent(value: string): string {
  if (typeof CSS !== "undefined" && typeof CSS.escape === "function") {
    return CSS.escape(value);
  }
  return value.replace(/[^a-zA-Z0-9_-]/g, "\\$&");
}

function shouldIgnoreElement(node: Element): boolean {
  return Boolean(node.closest(`#${OVERLAY_ROOT_ID}`)) || node.hasAttribute(OVERLAY_IGNORE_ATTR);
}

function isInsidePrompt(node: EventTarget | null): boolean {
  return node instanceof Element && Boolean(node.closest(`#${OVERLAY_ROOT_ID}`));
}

export function createBoxModel(element: Element): ElementBoxModel {
  return snapshotElement(element).boxModel;
}
