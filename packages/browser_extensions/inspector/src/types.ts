export type InspectorEventType =
  | "inspector:enabled"
  | "inspector:disabled"
  | "element:hover"
  | "element:selected"
  | "prompt:changed"
  | "prompt:submitted";

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

export interface InspectorEventPayloadMap {
  "inspector:enabled": null;
  "inspector:disabled": null;
  "element:hover": ElementSnapshot;
  "element:selected": ElementSnapshot;
  "prompt:changed": {
    element: ElementSnapshot;
    prompt: string;
  };
  "prompt:submitted": {
    element: ElementSnapshot;
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
  getSelectedElement(): ElementSnapshot | null;
}
