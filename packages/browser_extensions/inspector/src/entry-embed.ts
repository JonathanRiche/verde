import { createInspector } from "./inspector";
import type { InspectorAnyEvent, InspectorHandle, InspectorOptions } from "./types";

declare global {
  interface Window {
    VerdeInspector?: {
      mount: (options?: InspectorOptions) => InspectorHandle;
      unmount: () => void;
      get: () => InspectorHandle | null;
    };
    __VERDE_INSPECTOR_BRIDGE__?: {
      postMessage: (event: InspectorAnyEvent) => void;
    };
  }
}

let activeInspector: InspectorHandle | null = null;

function mount(options: InspectorOptions = {}): InspectorHandle {
  activeInspector?.destroy();
  activeInspector = createInspector({
    enabled: options.enabled ?? true,
    root: options.root,
    onEvent: options.onEvent,
    bridge: options.bridge ?? window.__VERDE_INSPECTOR_BRIDGE__,
  });
  return activeInspector;
}

function unmount(): void {
  activeInspector?.destroy();
  activeInspector = null;
}

window.VerdeInspector = {
  mount,
  unmount,
  get: () => activeInspector,
};
