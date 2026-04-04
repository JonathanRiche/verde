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
}
