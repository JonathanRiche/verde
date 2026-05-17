import type {
  ElementBoxModel,
  ElementBoxRect,
  ElementSnapshot,
  InspectorAnyEvent,
  InspectorEvent,
  InspectorEventPayloadMap,
  InspectorEventType,
  InspectorHandle,
  InspectorMode,
  InspectorModeInput,
  InspectorOptions,
  InspectorSelection,
  RegionSelection,
} from "./types";

const OVERLAY_ROOT_ID = "verde-inspector-overlay-root";
const OVERLAY_IGNORE_ATTR = "data-verde-inspector-ignore";
const BOX_ATTR = "data-verde-box";
const SVG_NS = "http://www.w3.org/2000/svg";
const VERDE_RGB = "34, 197, 94";
const VERDE_BORDER_GLOW = "rgba(240, 253, 244, 0.98)";
const OVERLAY_MARGIN_FILL = `rgba(${VERDE_RGB}, 0.12)`;
const OVERLAY_BORDER_FILL = `rgba(${VERDE_RGB}, 0.19)`;
const OVERLAY_PADDING_FILL = `rgba(${VERDE_RGB}, 0.29)`;
const OVERLAY_CONTENT_FILL = `rgba(${VERDE_RGB}, 0.05)`;
const OVERLAY_REGION_FILL = `rgba(${VERDE_RGB}, 0.12)`;
const OVERLAY_REGION_STROKE = `rgba(${VERDE_RGB}, 0.78)`;
const OVERLAY_FREEFORM_FILL = `rgba(${VERDE_RGB}, 0.1)`;
const OVERLAY_STROKE = `rgba(${VERDE_RGB}, 0.05)`;
const FREEFORM_BRUSH_RADIUS = 14;
const FREEFORM_POINT_STEP = 4;
const FREEFORM_CLOSE_SNAP_DISTANCE = 120;
const FREEFORM_CLOSE_SNAP_DISTANCE_MAX = 224;

type OverlayParts = {
  root: HTMLDivElement;
  margin: HTMLDivElement;
  border: HTMLDivElement;
  padding: HTMLDivElement;
  content: HTMLDivElement;
  region: HTMLDivElement;
  freeformSvg: SVGSVGElement;
  freeformPath: SVGPathElement;
  tooltip: HTMLDivElement;
  promptPanel: HTMLDivElement;
  promptTitle: HTMLDivElement;
  promptMeta: HTMLDivElement;
  promptTextarea: HTMLTextAreaElement;
  promptActions: HTMLDivElement;
  promptButton: HTMLButtonElement;
};

type PointerPosition = {
  x: number;
  y: number;
};

export function createInspector(options: InspectorOptions = {}): InspectorHandle {
  const doc = options.root ?? document;
  const win = doc.defaultView ?? window;
  const onEvent = options.onEvent;
  const bridge = options.bridge;

  let mode: InspectorMode = normalizeMode(options.mode);
  let enabled = false;
  let destroyed = false;
  let hoveredElement: Element | null = null;
  let pointSelectionNode: Element | null = null;
  let selection: InspectorSelection | null = null;
  let lastHoverSelector = "";
  let boxStart: PointerPosition | null = null;
  let freeformPoints: PointerPosition[] = [];
  let suppressNextClick = false;

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

  const setOverlayActive = (active: boolean): void => {
    overlay.root.style.display = active ? "block" : "none";
  };

  const showTooltip = (label: string, rect: ElementBoxRect): void => {
    overlay.tooltip.textContent = label;
    overlay.tooltip.style.transform = `translate(${Math.max(rect.x, 8)}px, ${Math.max(rect.y - 30, 8)}px)`;
    overlay.tooltip.style.opacity = "1";
  };

  const hideTooltip = (): void => {
    overlay.tooltip.style.opacity = "0";
  };

  const showElementBoxes = (): void => {
    overlay.margin.style.display = "block";
    overlay.border.style.display = "block";
    overlay.padding.style.display = "block";
    overlay.content.style.display = "block";
  };

  const hideElementBoxes = (): void => {
    overlay.margin.style.display = "none";
    overlay.border.style.display = "none";
    overlay.padding.style.display = "none";
    overlay.content.style.display = "none";
  };

  const showRegionBox = (): void => {
    overlay.region.style.display = "block";
  };

  const hideRegionBox = (): void => {
    overlay.region.style.display = "none";
  };

  const showFreeformPath = (): void => {
    overlay.freeformSvg.style.display = "block";
  };

  const hideFreeformPath = (): void => {
    overlay.freeformSvg.style.display = "none";
    overlay.freeformPath.setAttribute("d", "");
    overlay.freeformPath.setAttribute("fill", "none");
  };

  const hideVisuals = (): void => {
    hideElementBoxes();
    hideRegionBox();
    hideFreeformPath();
    hideTooltip();
  };

  const focusPrompt = (): void => {
    overlay.promptTextarea.focus();
    overlay.promptTextarea.select();
  };

  const syncPrompt = (nextSelection: InspectorSelection | null): void => {
    if (!nextSelection) {
      overlay.promptPanel.hidden = true;
      overlay.promptTextarea.value = "";
      return;
    }

    overlay.promptPanel.hidden = false;
    if (nextSelection.mode === "point") {
      const snapshot = nextSelection.element;
      overlay.promptTitle.textContent = `Selected: ${snapshot.selector}`;
      overlay.promptMeta.textContent =
        `${snapshot.rect.width} x ${snapshot.rect.height} at (${snapshot.rect.x}, ${snapshot.rect.y})`;
      return;
    }

    const selectionLabel =
      nextSelection.mode === "draw-box" ? "Selected box region" : "Selected freeform region";
    overlay.promptTitle.textContent =
      `${selectionLabel}: ${nextSelection.elements.length} element${nextSelection.elements.length === 1 ? "" : "s"}`;
    overlay.promptMeta.textContent =
      `${nextSelection.rect.width} x ${nextSelection.rect.height} at (${nextSelection.rect.x}, ${nextSelection.rect.y})`;
  };

  const renderPointSnapshot = (
    snapshot: ElementSnapshot,
    emitHoverEvent: boolean,
  ): void => {
    hideRegionBox();
    hideFreeformPath();
    showElementBoxes();
    positionBox(overlay.margin, snapshot.boxModel.margin);
    positionBox(overlay.border, snapshot.boxModel.border);
    positionBox(overlay.padding, snapshot.boxModel.padding);
    positionBox(overlay.content, snapshot.boxModel.content);

    showTooltip(
      `${snapshot.selector}  ${Math.round(snapshot.rect.width)} x ${Math.round(snapshot.rect.height)}`,
      snapshot.rect,
    );

    if (emitHoverEvent && snapshot.selector !== lastHoverSelector) {
      lastHoverSelector = snapshot.selector;
      emit("element:hover", snapshot);
    }
  };

  const renderRegionRect = (rect: ElementBoxRect, label: string): void => {
    hideElementBoxes();
    hideFreeformPath();
    showRegionBox();
    positionBox(overlay.region, rect);
    showTooltip(label, rect);
  };

  const renderFreeform = (
    points: PointerPosition[],
    label: string,
    closed: boolean,
  ): void => {
    if (points.length === 0) {
      hideFreeformPath();
      return;
    }

    hideElementBoxes();
    hideRegionBox();
    showFreeformPath();
    syncFreeformViewport(overlay.freeformSvg, win);
    overlay.freeformPath.setAttribute("d", buildFreeformPath(points, closed));
    overlay.freeformPath.setAttribute("fill", closed ? OVERLAY_FREEFORM_FILL : "none");
    showTooltip(label, expandRect(boundsFromPoints(points), FREEFORM_BRUSH_RADIUS));
  };

  const refreshPointHover = (emitHoverEvent: boolean): void => {
    if (hoveredElement == null) {
      if (selection == null) hideVisuals();
      return;
    }

    renderPointSnapshot(snapshotElement(hoveredElement, win), emitHoverEvent);
  };

  const resetDrawingState = (): void => {
    boxStart = null;
    freeformPoints = [];
    suppressNextClick = false;
  };

  const clearSelection = (): void => {
    pointSelectionNode = null;
    selection = null;
    resetDrawingState();
    syncPrompt(null);

    if (mode === "point" && hoveredElement) {
      refreshPointHover(false);
      return;
    }

    hideVisuals();
  };

  const beginDrawInteraction = (): void => {
    pointSelectionNode = null;
    selection = null;
    hoveredElement = null;
    lastHoverSelector = "";
    syncPrompt(null);
  };

  const setPointSelection = (node: Element): void => {
    pointSelectionNode = node;
    const snapshot = snapshotElement(node, win);
    selection = {
      mode: "point",
      element: snapshot,
    };
    renderPointSnapshot(snapshot, false);
    syncPrompt(selection);
    emit("element:selected", snapshot);
    focusPrompt();
  };

  const setBoxSelection = (rect: ElementBoxRect): void => {
    pointSelectionNode = null;
    const nextSelection: RegionSelection = {
      mode: "draw-box",
      rect,
      elements: collectTopLevelElements(doc, rect, win, (candidateRect) =>
        rectsIntersect(candidateRect, rect),
      ),
    };

    selection = nextSelection;
    renderRegionRect(
      rect,
      `${nextSelection.elements.length} element${nextSelection.elements.length === 1 ? "" : "s"} in box`,
    );
    syncPrompt(nextSelection);
    emit("region:selected", nextSelection);
    focusPrompt();
  };

  const setFreeformSelection = (points: PointerPosition[]): void => {
    pointSelectionNode = null;
    const { points: finalizedPoints, closed } = finalizeFreeformPoints(points);
    const rect = expandRect(boundsFromPoints(finalizedPoints), FREEFORM_BRUSH_RADIUS);
    const nextSelection: RegionSelection = {
      mode: "draw-freeform",
      rect,
      elements: collectTopLevelElements(doc, rect, win, (candidateRect) =>
        freeformHitsRect(finalizedPoints, candidateRect, FREEFORM_BRUSH_RADIUS, closed),
      ),
      points: finalizedPoints.map((point) => ({ x: round2(point.x), y: round2(point.y) })),
      brushRadius: FREEFORM_BRUSH_RADIUS,
      closed,
    };

    selection = nextSelection;
    renderFreeform(
      finalizedPoints,
      `${nextSelection.elements.length} element${nextSelection.elements.length === 1 ? "" : "s"} in freeform`,
      closed,
    );
    syncPrompt(nextSelection);
    emit("region:selected", nextSelection);
    focusPrompt();
  };

  const setMode = (nextModeInput: InspectorModeInput): void => {
    const nextMode = normalizeMode(nextModeInput);
    if (mode === nextMode) return;

    mode = nextMode;
    hoveredElement = null;
    pointSelectionNode = null;
    selection = null;
    lastHoverSelector = "";
    resetDrawingState();
    syncPrompt(null);
    hideVisuals();
    emit("inspector:mode-changed", { mode });
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
    if (!enabled || destroyed) return;

    if (boxStart) {
      const rect = rectFromPoints(boxStart, {
        x: event.clientX,
        y: event.clientY,
      });
      renderRegionRect(
        rect,
        `Drawing box  ${Math.round(rect.width)} x ${Math.round(rect.height)}`,
      );
      return;
    }

    if (freeformPoints.length > 0) {
      appendPointIfNeeded(freeformPoints, {
        x: event.clientX,
        y: event.clientY,
      });
      renderFreeform(
        freeformPoints,
        `Drawing freeform  ${freeformPoints.length} points`,
        false,
      );
      return;
    }

    if (isInsideIgnoredSurface(event.target)) {
      hoveredElement = null;
      lastHoverSelector = "";
      if (selection == null) hideVisuals();
      return;
    }

    if (mode !== "point" || pointSelectionNode) return;

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
      hoveredElement = null;
      lastHoverSelector = "";
      if (selection == null) hideVisuals();
      return;
    }

    hoveredElement = target;
    renderPointSnapshot(snapshotElement(target, win), true);
  };

  const handlePointerLeave = (): void => {
    if (!enabled || destroyed || mode !== "point" || pointSelectionNode) return;
    hoveredElement = null;
    lastHoverSelector = "";
    if (selection == null) hideVisuals();
  };

  const handleMouseDown = (event: MouseEvent): void => {
    if (!enabled || destroyed || mode === "point") return;
    if (event.button !== 0 || isInsideIgnoredSurface(event.target)) return;

    event.preventDefault();
    event.stopPropagation();
    event.stopImmediatePropagation();

    suppressNextClick = true;
    beginDrawInteraction();

    if (mode === "draw-box") {
      boxStart = {
        x: event.clientX,
        y: event.clientY,
      };
      renderRegionRect(
        rectFromPoints(boxStart, boxStart),
        "Drawing box  0 x 0",
      );
      return;
    }

    freeformPoints = [
      {
        x: event.clientX,
        y: event.clientY,
      },
    ];
    renderFreeform(freeformPoints, "Drawing freeform  1 point", false);
  };

  const handleMouseUp = (event: MouseEvent): void => {
    if (!enabled || destroyed) return;

    if (boxStart) {
      event.preventDefault();
      event.stopPropagation();
      event.stopImmediatePropagation();

      const rect = rectFromPoints(boxStart, {
        x: event.clientX,
        y: event.clientY,
      });
      boxStart = null;
      setBoxSelection(rect);
      return;
    }

    if (freeformPoints.length > 0) {
      event.preventDefault();
      event.stopPropagation();
      event.stopImmediatePropagation();

      appendPointIfNeeded(freeformPoints, {
        x: event.clientX,
        y: event.clientY,
      });
      const finalized = [...freeformPoints];
      freeformPoints = [];
      setFreeformSelection(finalized);
    }
  };

  const handleClick = (event: MouseEvent): void => {
    if (!enabled || destroyed) return;
    if (isInsideIgnoredSurface(event.target)) return;

    if (suppressNextClick) {
      suppressNextClick = false;
      event.preventDefault();
      event.stopPropagation();
      event.stopImmediatePropagation();
      return;
    }

    if (mode !== "point") return;

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
    setPointSelection(target);
  };

  const handleKeyDown = (event: KeyboardEvent): void => {
    if (!enabled || destroyed) return;

    if (event.key === "Escape") {
      event.preventDefault();

      if (boxStart || freeformPoints.length > 0) {
        clearSelection();
        return;
      }

      if (selection) {
        clearSelection();
        return;
      }

      disable();
    }
  };

  overlay.promptTextarea.addEventListener("input", () => {
    if (!selection) return;
    emit("prompt:changed", {
      selection,
      prompt: overlay.promptTextarea.value,
    });
  });
  for (const eventName of ["mousedown", "mouseup", "click", "dblclick", "select", "copy", "cut", "paste"] as const) {
    overlay.promptTextarea.addEventListener(eventName, (event) => {
      event.stopPropagation();
    });
  }

  overlay.promptButton.addEventListener("click", () => {
    if (!selection) return;
    emit("prompt:submitted", {
      selection,
      prompt: overlay.promptTextarea.value.trim(),
    });
    clearSelection();
  });

  const enable = (): void => {
    if (destroyed || enabled) return;
    enabled = true;
    doc.addEventListener("mousemove", handlePointerMove, true);
    doc.addEventListener("mouseout", handlePointerLeave, true);
    doc.addEventListener("mousedown", handleMouseDown, true);
    doc.addEventListener("mouseup", handleMouseUp, true);
    doc.addEventListener("click", handleClick, true);
    doc.addEventListener("keydown", handleKeyDown, true);
    if (!overlay.root.isConnected) {
      doc.documentElement.appendChild(overlay.root);
    }
    setOverlayActive(true);
    hideVisuals();
    syncPrompt(selection);
    emit("inspector:enabled", null);
  };

  const disable = (): void => {
    if (destroyed || !enabled) return;
    enabled = false;
    hoveredElement = null;
    pointSelectionNode = null;
    selection = null;
    lastHoverSelector = "";
    resetDrawingState();
    doc.removeEventListener("mousemove", handlePointerMove, true);
    doc.removeEventListener("mouseout", handlePointerLeave, true);
    doc.removeEventListener("mousedown", handleMouseDown, true);
    doc.removeEventListener("mouseup", handleMouseUp, true);
    doc.removeEventListener("click", handleClick, true);
    doc.removeEventListener("keydown", handleKeyDown, true);
    syncPrompt(null);
    hideVisuals();
    setOverlayActive(false);
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
    getMode: () => mode,
    setMode,
    getSelection: () => selection,
    getSelectedElements: () => {
      if (selection == null) return [];
      return selection.mode === "point" ? [selection.element] : selection.elements;
    },
    getSelectedElement: () => {
      if (selection == null || selection.mode !== "point") return null;
      return selection.element;
    },
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
    "user-select:none",
  ].join(";");

  const margin = createBox(doc, "margin", OVERLAY_MARGIN_FILL);
  const border = createBox(doc, "border", OVERLAY_BORDER_FILL);
  const padding = createBox(doc, "padding", OVERLAY_PADDING_FILL);
  const content = createBox(doc, "content", OVERLAY_CONTENT_FILL);

  const region = doc.createElement("div");
  region.setAttribute(OVERLAY_IGNORE_ATTR, "true");
  region.setAttribute(BOX_ATTR, "region");
  region.style.cssText = [
    "position:fixed",
    "left:0",
    "top:0",
    "display:none",
    "box-sizing:border-box",
    "pointer-events:none",
    `background:${OVERLAY_REGION_FILL}`,
    `border:2px solid ${OVERLAY_REGION_STROKE}`,
    "border-radius:18px",
    "box-shadow:0 0 0 1px rgba(240, 253, 244, 0.3) inset",
  ].join(";");

  const freeformSvg = doc.createElementNS(SVG_NS, "svg");
  freeformSvg.setAttribute(OVERLAY_IGNORE_ATTR, "true");
  freeformSvg.style.cssText = [
    "position:fixed",
    "inset:0",
    "display:none",
    "overflow:visible",
    "pointer-events:none",
  ].join(";");

  const freeformPath = doc.createElementNS(SVG_NS, "path");
  freeformPath.setAttribute("fill", "none");
  freeformPath.setAttribute("stroke", OVERLAY_REGION_STROKE);
  freeformPath.setAttribute("stroke-width", String(FREEFORM_BRUSH_RADIUS * 2));
  freeformPath.setAttribute("stroke-linecap", "round");
  freeformPath.setAttribute("stroke-linejoin", "round");
  freeformPath.setAttribute("vector-effect", "non-scaling-stroke");
  freeformSvg.appendChild(freeformPath);

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
    "padding:12px",
    "border:1px solid rgba(80, 200, 120, 0.22)",
    "border-radius:10px",
    "background:rgba(25, 31, 36, 0.96)",
    "color:#f0f0f5",
    "box-shadow:0 18px 48px rgba(0, 0, 0, 0.38)",
    "backdrop-filter:blur(10px)",
    "pointer-events:auto",
    "user-select:none",
  ].join(";");

  const promptTitle = doc.createElement("div");
  promptTitle.setAttribute(OVERLAY_IGNORE_ATTR, "true");
  promptTitle.style.cssText = "font-size:12px;font-weight:700;color:#f0f0f5;margin-bottom:6px;";

  const promptMeta = doc.createElement("div");
  promptMeta.setAttribute(OVERLAY_IGNORE_ATTR, "true");
  promptMeta.style.cssText = "font-size:11px;color:#b9bbc3;margin-bottom:10px;";

  const promptTextarea = doc.createElement("textarea");
  promptTextarea.setAttribute(OVERLAY_IGNORE_ATTR, "true");
  promptTextarea.placeholder = "Describe what you want to do with this selection...";
  promptTextarea.style.cssText = [
    "display:block",
    "width:100%",
    "min-height:128px",
    "resize:vertical",
    "padding:12px",
    "border-radius:8px",
    "border:1px solid rgba(80, 200, 120, 0.2)",
    "background:rgba(29, 38, 43, 0.95)",
    "color:#f0f0f5",
    "font:inherit",
    "font-size:13px",
    "line-height:1.45",
    "box-sizing:border-box",
    "outline:none",
    "caret-color:#50c878",
    "user-select:text",
    "-webkit-user-select:text",
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
    "padding:9px 14px",
    "border:0",
    "border-radius:8px",
    "background:#375846",
    "color:white",
    "font:inherit",
    "font-weight:700",
    "cursor:pointer",
  ].join(";");

  promptActions.appendChild(promptButton);
  promptPanel.append(promptTitle, promptMeta, promptTextarea, promptActions);
  root.append(margin, border, padding, content, region, freeformSvg, tooltip, promptPanel);

  return {
    root,
    margin,
    border,
    padding,
    content,
    region,
    freeformSvg,
    freeformPath,
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
    "display:none",
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

function syncFreeformViewport(node: SVGSVGElement, win: Window): void {
  const width = Math.max(win.innerWidth, 1);
  const height = Math.max(win.innerHeight, 1);
  node.setAttribute("width", String(width));
  node.setAttribute("height", String(height));
  node.setAttribute("viewBox", `0 0 ${width} ${height}`);
}

function buildFreeformPath(points: PointerPosition[], closed: boolean): string {
  if (points.length === 0) return "";
  if (points.length === 1) {
    const point = points[0]!;
    return `M ${point.x} ${point.y} l 0.01 0.01`;
  }

  const firstPoint = points[0]!;
  let path = `M ${firstPoint.x} ${firstPoint.y}`;
  for (const point of points.slice(1)) {
    path += ` L ${point.x} ${point.y}`;
  }

  if (closed) {
    path += " Z";
  }

  return path;
}

function appendPointIfNeeded(points: PointerPosition[], point: PointerPosition): void {
  const previous = points.at(-1);
  if (!previous || distanceBetween(previous, point) >= FREEFORM_POINT_STEP) {
    points.push(point);
    return;
  }

  points[points.length - 1] = point;
}

function snapshotElement(node: Element, win: Window = window): ElementSnapshot {
  const element = node as HTMLElement;
  const rect = element.getBoundingClientRect();
  const style = win.getComputedStyle(element);
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

function normalizeMode(mode: InspectorModeInput | undefined): InspectorMode {
  if (mode === "region") return "draw-box";
  return mode ?? "point";
}

function rectFromPoints(start: PointerPosition, end: PointerPosition): ElementBoxRect {
  return normalizeRect(
    Math.min(start.x, end.x),
    Math.min(start.y, end.y),
    Math.abs(end.x - start.x),
    Math.abs(end.y - start.y),
  );
}

function boundsFromPoints(points: PointerPosition[]): ElementBoxRect {
  if (points.length === 0) {
    return normalizeRect(0, 0, 0, 0);
  }

  const xs = points.map((point) => point.x);
  const ys = points.map((point) => point.y);
  const left = Math.min(...xs);
  const top = Math.min(...ys);
  const right = Math.max(...xs);
  const bottom = Math.max(...ys);
  return normalizeRect(left, top, right - left, bottom - top);
}

function collectTopLevelElements(
  doc: Document,
  selectionRect: ElementBoxRect,
  win: Window,
  matches: (rect: ElementBoxRect) => boolean,
): ElementSnapshot[] {
  const candidates = [...doc.querySelectorAll("*")]
    .filter((element) => {
      if (shouldIgnoreElement(element)) return false;
      if (element === doc.documentElement || element === doc.body) return false;
      if (!isVisibleElement(element, win)) return false;

      const rect = normalizeRectFromDomRect(element.getBoundingClientRect());
      if (!matches(rect)) return false;
      if (isOversizedContainer(rect, selectionRect)) return false;
      return true;
    })
    .sort((left, right) => {
      const depthDelta = getElementDepth(left) - getElementDepth(right);
      if (depthDelta !== 0) return depthDelta;
      return rectArea(left.getBoundingClientRect()) - rectArea(right.getBoundingClientRect());
    });

  const topLevel: Element[] = [];
  for (const candidate of candidates) {
    if (topLevel.some((ancestor) => ancestor.contains(candidate))) continue;
    topLevel.push(candidate);
  }

  return topLevel.map((element) => snapshotElement(element, win));
}

function freeformHitsRect(
  points: PointerPosition[],
  rect: ElementBoxRect,
  brushRadius: number,
  closed: boolean,
): boolean {
  const expandedRect = expandRect(rect, brushRadius);
  if (points.some((point) => pointInRect(point, expandedRect))) {
    return true;
  }

  for (let index = 1; index < points.length; index += 1) {
    const previous = points[index - 1];
    const current = points[index];
    if (previous && current && segmentIntersectsRect(previous, current, expandedRect)) {
      return true;
    }
  }

  if (closed) {
    return sampleRectPoints(rect).some((point) => pointInPolygon(point, points));
  }

  return false;
}

function isVisibleElement(element: Element, win: Window): boolean {
  const rect = element.getBoundingClientRect();
  if (rect.width <= 0 || rect.height <= 0) return false;

  const style = win.getComputedStyle(element as HTMLElement);
  if (style.display === "none") return false;
  if (style.visibility === "hidden" || style.visibility === "collapse") return false;
  if (Number.parseFloat(style.opacity) === 0) return false;

  return true;
}

function isOversizedContainer(candidate: ElementBoxRect, selection: ElementBoxRect): boolean {
  const selectionArea = Math.max(selection.width * selection.height, 1);
  const candidateArea = Math.max(candidate.width * candidate.height, 1);
  return rectContains(candidate, selection) && candidateArea > selectionArea * 2;
}

function getElementDepth(element: Element): number {
  let depth = 0;
  let current: Element | null = element.parentElement;
  while (current) {
    depth += 1;
    current = current.parentElement;
  }
  return depth;
}

function sampleRectPoints(rect: ElementBoxRect): PointerPosition[] {
  const middleX = rect.x + rect.width / 2;
  const middleY = rect.y + rect.height / 2;
  return [
    { x: rect.x, y: rect.y },
    { x: middleX, y: rect.y },
    { x: rect.x + rect.width, y: rect.y },
    { x: rect.x, y: middleY },
    { x: middleX, y: middleY },
    { x: rect.x + rect.width, y: middleY },
    { x: rect.x, y: rect.y + rect.height },
    { x: middleX, y: rect.y + rect.height },
    { x: rect.x + rect.width, y: rect.y + rect.height },
  ];
}

function finalizeFreeformPoints(
  points: PointerPosition[],
): { points: PointerPosition[]; closed: boolean } {
  if (points.length < 2) {
    return {
      points,
      closed: false,
    };
  }

  if (!shouldAutoCloseLoop(points)) {
    return {
      points,
      closed: false,
    };
  }

  const firstPoint = points[0];
  if (!firstPoint) {
    return {
      points,
      closed: false,
    };
  }

  const closedPoints = [...points];
  closedPoints[closedPoints.length - 1] = {
    x: firstPoint.x,
    y: firstPoint.y,
  };

  return {
    points: closedPoints,
    closed: true,
  };
}

function isClosedLoop(points: PointerPosition[], brushRadius: number): boolean {
  if (points.length < 3) return false;
  const firstPoint = points[0];
  const lastPoint = points.at(-1);
  if (!firstPoint || !lastPoint) return false;
  return distanceBetween(firstPoint, lastPoint) <= brushRadius * 2;
}

function shouldAutoCloseLoop(points: PointerPosition[]): boolean {
  if (points.length < 4) return false;

  const bounds = boundsFromPoints(points);
  if (bounds.width < FREEFORM_BRUSH_RADIUS * 4 || bounds.height < FREEFORM_BRUSH_RADIUS * 4) {
    return false;
  }

  if (isClosedLoop(points, FREEFORM_BRUSH_RADIUS)) {
    return true;
  }

  const firstPoint = points[0];
  const lastPoint = points.at(-1);
  if (!firstPoint || !lastPoint) return false;

  const scaledSnapDistance = Math.min(
    FREEFORM_CLOSE_SNAP_DISTANCE_MAX,
    Math.max(
      FREEFORM_CLOSE_SNAP_DISTANCE,
      Math.min(bounds.width, bounds.height) * 0.34,
    ),
  );

  return distanceBetween(firstPoint, lastPoint) <= scaledSnapDistance;
}

function expandRect(rect: ElementBoxRect, amount: number): ElementBoxRect {
  return normalizeRect(
    rect.x - amount,
    rect.y - amount,
    rect.width + amount * 2,
    rect.height + amount * 2,
  );
}

function pointInRect(point: PointerPosition, rect: ElementBoxRect): boolean {
  return (
    point.x >= rect.x &&
    point.x <= rect.x + rect.width &&
    point.y >= rect.y &&
    point.y <= rect.y + rect.height
  );
}

function segmentIntersectsRect(
  start: PointerPosition,
  end: PointerPosition,
  rect: ElementBoxRect,
): boolean {
  if (pointInRect(start, rect) || pointInRect(end, rect)) {
    return true;
  }

  const topLeft = { x: rect.x, y: rect.y };
  const topRight = { x: rect.x + rect.width, y: rect.y };
  const bottomLeft = { x: rect.x, y: rect.y + rect.height };
  const bottomRight = { x: rect.x + rect.width, y: rect.y + rect.height };

  return (
    segmentsIntersect(start, end, topLeft, topRight) ||
    segmentsIntersect(start, end, topRight, bottomRight) ||
    segmentsIntersect(start, end, bottomRight, bottomLeft) ||
    segmentsIntersect(start, end, bottomLeft, topLeft)
  );
}

function segmentsIntersect(
  a1: PointerPosition,
  a2: PointerPosition,
  b1: PointerPosition,
  b2: PointerPosition,
): boolean {
  const o1 = orientation(a1, a2, b1);
  const o2 = orientation(a1, a2, b2);
  const o3 = orientation(b1, b2, a1);
  const o4 = orientation(b1, b2, a2);

  if (o1 !== o2 && o3 !== o4) {
    return true;
  }

  if (o1 === 0 && pointOnSegment(a1, b1, a2)) return true;
  if (o2 === 0 && pointOnSegment(a1, b2, a2)) return true;
  if (o3 === 0 && pointOnSegment(b1, a1, b2)) return true;
  if (o4 === 0 && pointOnSegment(b1, a2, b2)) return true;
  return false;
}

function orientation(
  p: PointerPosition,
  q: PointerPosition,
  r: PointerPosition,
): number {
  const value = (q.y - p.y) * (r.x - q.x) - (q.x - p.x) * (r.y - q.y);
  if (Math.abs(value) < 0.0001) return 0;
  return value > 0 ? 1 : 2;
}

function pointOnSegment(
  start: PointerPosition,
  point: PointerPosition,
  end: PointerPosition,
): boolean {
  return (
    point.x <= Math.max(start.x, end.x) &&
    point.x >= Math.min(start.x, end.x) &&
    point.y <= Math.max(start.y, end.y) &&
    point.y >= Math.min(start.y, end.y)
  );
}

function pointInPolygon(point: PointerPosition, polygon: PointerPosition[]): boolean {
  if (polygon.length < 3) return false;

  let inside = false;

  for (let i = 0, j = polygon.length - 1; i < polygon.length; j = i, i += 1) {
    const current = polygon[i];
    const previous = polygon[j];
    if (!current || !previous) continue;

    const xi = current.x;
    const yi = current.y;
    const xj = previous.x;
    const yj = previous.y;

    const intersects =
      yi > point.y !== yj > point.y &&
      point.x < ((xj - xi) * (point.y - yi)) / ((yj - yi) || Number.EPSILON) + xi;

    if (intersects) {
      inside = !inside;
    }
  }

  return inside;
}

function distanceBetween(left: PointerPosition, right: PointerPosition): number {
  return Math.hypot(left.x - right.x, left.y - right.y);
}

function rectArea(rect: DOMRect | ElementBoxRect): number {
  return Math.max(rect.width, 0) * Math.max(rect.height, 0);
}

function rectContains(outer: ElementBoxRect, inner: ElementBoxRect): boolean {
  return (
    inner.x >= outer.x &&
    inner.y >= outer.y &&
    inner.x + inner.width <= outer.x + outer.width &&
    inner.y + inner.height <= outer.y + outer.height
  );
}

function rectsIntersect(left: ElementBoxRect, right: ElementBoxRect): boolean {
  return !(
    left.x + left.width < right.x ||
    right.x + right.width < left.x ||
    left.y + left.height < right.y ||
    right.y + right.height < left.y
  );
}

function normalizeRectFromDomRect(rect: DOMRect): ElementBoxRect {
  return normalizeRect(rect.left, rect.top, rect.width, rect.height);
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

function isInsideIgnoredSurface(node: EventTarget | null): boolean {
  return node instanceof Element && Boolean(node.closest(`[${OVERLAY_IGNORE_ATTR}]`));
}

export function createBoxModel(element: Element): ElementBoxModel {
  return snapshotElement(element).boxModel;
}
