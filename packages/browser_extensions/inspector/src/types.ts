export type InspectorEventType =
  | "inspector:enabled"
  | "inspector:disabled"
  | "inspector:mode-changed"
  | "element:hover"
  | "element:selected"
  | "region:selected"
  | "prompt:changed"
  | "prompt:submitted";

export type InspectorMode = "point" | "draw-box" | "draw-freeform";
export type InspectorModeInput = InspectorMode | "region";

export interface ElementBoxRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface ElementBoxModel {
  margin: ElementBoxRect;
  border: ElementBoxRect;
  padding: ElementBoxRect;
  content: ElementBoxRect;
}

export interface ElementSnapshot {
  tagName: string;
  id: string | null;
  className: string;
  selector: string;
  textSnippet: string;
  href: string | null;
  ariaLabel: string | null;
  rect: ElementBoxRect;
  boxModel: ElementBoxModel;
}

export interface SelectionPoint {
  x: number;
  y: number;
}

export interface PointSelection {
  mode: "point";
  element: ElementSnapshot;
}

export interface RegionSelection {
  mode: "draw-box" | "draw-freeform";
  rect: ElementBoxRect;
  elements: ElementSnapshot[];
  points?: SelectionPoint[];
  brushRadius?: number;
  closed?: boolean;
}

export type InspectorSelection = PointSelection | RegionSelection;

/** Viewport metrics captured at submit time so the host can map CSS
 * selection coordinates onto browser frame pixels for screenshot crops. */
export interface InspectorViewportInfo {
  width: number;
  height: number;
  devicePixelRatio: number;
  scrollX: number;
  scrollY: number;
}

/** Host verdict for a submitted prompt: "sent"/"drafted" close the bubble,
 * "failed" re-enables it with an optional message. */
export type InspectorPromptResult = "sent" | "drafted" | "failed";

/** One chat destination the host can route a design-mode prompt to. The id is
 * opaque to the page (Verde uses the workspace pane id). */
export interface InspectorPromptTarget {
  id: string;
  label: string;
}

export interface InspectorEventPayloadMap {
  "inspector:enabled": null;
  "inspector:disabled": null;
  "inspector:mode-changed": {
    mode: InspectorMode;
  };
  "element:hover": ElementSnapshot;
  "element:selected": ElementSnapshot;
  "region:selected": RegionSelection;
  "prompt:changed": {
    selection: InspectorSelection;
    prompt: string;
  };
  "prompt:submitted": {
    selection: InspectorSelection;
    prompt: string;
    viewport: InspectorViewportInfo;
    /** Selected target id from the host-provided list, or null when the host
     * never pushed targets (host falls back to its active thread). */
    target: string | null;
  };
}

export interface InspectorEvent<TType extends InspectorEventType = InspectorEventType> {
  source: "verde-inspector";
  type: TType;
  payload: InspectorEventPayloadMap[TType];
  timestamp: number;
}

export type InspectorAnyEvent = {
  [TType in InspectorEventType]: InspectorEvent<TType>;
}[InspectorEventType];

export interface InspectorOptions {
  enabled?: boolean;
  mode?: InspectorModeInput;
  root?: Document;
  onEvent?: (event: InspectorAnyEvent) => void;
  bridge?: {
    postMessage: (event: InspectorAnyEvent) => void;
  };
}

export interface InspectorHandle {
  enable(): void;
  disable(): void;
  destroy(): void;
  isEnabled(): boolean;
  getMode(): InspectorMode;
  setMode(mode: InspectorModeInput): void;
  getSelection(): InspectorSelection | null;
  getSelectedElements(): ElementSnapshot[];
  getSelectedElement(): ElementSnapshot | null;
  /** Host callback resolving the pending state after a prompt:submitted. */
  notifyPromptResult(result: InspectorPromptResult, message?: string | null): void;
  /** Host push of available chat destinations; the bubble shows a selector
   * only when more than one target exists. */
  setPromptTargets(targets: InspectorPromptTarget[], selectedId?: string | null): void;
}
