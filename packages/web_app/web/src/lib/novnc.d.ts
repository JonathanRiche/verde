// Narrow declaration for the noVNC public API used by the host desktop viewer.
declare module '@novnc/novnc' {
  export default class RFB extends EventTarget {
    constructor(target: HTMLElement, url: string, options?: { shared?: boolean })
    viewOnly: boolean
    scaleViewport: boolean
    resizeSession: boolean
    focusOnClick: boolean
    disconnect(): void
    focus(): void
    sendCredentials(credentials: { username?: string; password?: string }): void
  }
}
