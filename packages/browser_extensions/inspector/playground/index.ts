import { createInspector } from "../src/inspector";
import type { InspectorAnyEvent } from "../src/types";

const log = document.querySelector<HTMLElement>("[data-log]");
const status = document.querySelector<HTMLElement>("[data-status]");
const enableButton = document.querySelector<HTMLButtonElement>("[data-enable]");
const disableButton = document.querySelector<HTMLButtonElement>("[data-disable]");
const pointModeButton = document.querySelector<HTMLButtonElement>("[data-mode-point]");
const boxModeButton = document.querySelector<HTMLButtonElement>("[data-mode-box]");
const freeformModeButton = document.querySelector<HTMLButtonElement>("[data-mode-freeform]");

const inspector = createInspector({
  enabled: true,
  onEvent(event) {
    renderStatus(event);
    appendLog(event);
  },
});

enableButton?.addEventListener("click", () => inspector.enable());
disableButton?.addEventListener("click", () => inspector.disable());
pointModeButton?.addEventListener("click", () => inspector.setMode("point"));
boxModeButton?.addEventListener("click", () => inspector.setMode("draw-box"));
freeformModeButton?.addEventListener("click", () => inspector.setMode("draw-freeform"));

renderStatus({
  source: "verde-inspector",
  type: "inspector:enabled",
  payload: null,
  timestamp: Date.now(),
});

function renderStatus(event: InspectorAnyEvent): void {
  if (!status) return;

  switch (event.type) {
    case "inspector:mode-changed":
      status.textContent = `mode: ${event.payload.mode}`;
      return;
    case "element:hover":
    case "element:selected":
      status.textContent = `${event.type}: ${event.payload.selector}`;
      return;
    case "region:selected":
      status.textContent =
        `${event.type}: ${event.payload.elements.length} elements`;
      return;
    default:
      status.textContent = event.type;
      return;
  }
}

function appendLog(event: InspectorAnyEvent): void {
  if (!log) return;
  const line = document.createElement("pre");
  line.textContent = JSON.stringify(event, null, 2);
  log.prepend(line);

  while (log.childElementCount > 8) {
    log.lastElementChild?.remove();
  }
}
