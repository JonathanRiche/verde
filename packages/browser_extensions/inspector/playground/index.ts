import { createInspector } from "../src/inspector";
import type { InspectorAnyEvent } from "../src/types";

const log = document.querySelector<HTMLElement>("[data-log]");
const status = document.querySelector<HTMLElement>("[data-status]");
const enableButton = document.querySelector<HTMLButtonElement>("[data-enable]");
const disableButton = document.querySelector<HTMLButtonElement>("[data-disable]");

const inspector = createInspector({
  enabled: true,
  onEvent(event) {
    renderStatus(event);
    appendLog(event);
  },
});

enableButton?.addEventListener("click", () => inspector.enable());
disableButton?.addEventListener("click", () => inspector.disable());

renderStatus({
  source: "verde-inspector",
  type: "inspector:enabled",
  payload: null,
  timestamp: Date.now(),
});

function renderStatus(event: InspectorAnyEvent): void {
  if (!status) return;

  switch (event.type) {
    case "element:hover":
    case "element:selected":
      status.textContent = `${event.type}: ${event.payload.selector}`;
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
