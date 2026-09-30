import { createFileRoute } from '@tanstack/solid-router'

import { SITE_ORIGIN } from '../lib/seo'

const title = 'Privacy Policy — Verde'
const description = 'How Verde handles Android companion app data, paired hosts, AI providers, permissions, storage, and deletion.'

export const Route = createFileRoute('/privacy')({
  head: () => ({
    meta: [
      { title },
      { name: 'description', content: description },
      { property: 'og:title', content: title },
      { property: 'og:description', content: description },
      { property: 'og:url', content: `${SITE_ORIGIN}/privacy` },
    ],
    links: [{ rel: 'canonical', href: `${SITE_ORIGIN}/privacy` }],
  }),
  component: Privacy,
})

function Privacy() {
  return (
    <main class="wrap privacy-page">
      <article class="term-card privacy-policy">
        <p class="tag">Verde · Privacy</p>
        <h1 class="heading">Privacy policy</h1>
        <p class="privacy-date">Effective September 30, 2026</p>
        <p>This policy describes how Verde handles information in the Verde Android companion app (package <code>dev.verdeai.app</code>), its connections to paired Verde hosts, and this website. For privacy questions or requests, contact the Verde developer at <a href="mailto:developer@verdeai.dev">developer@verdeai.dev</a>.</p>

        <h2>Your phone, your host, your providers</h2>
        <p>The Android app is a companion to a Verde host you choose and pair with. It sends your requests to that host and displays the host’s responses. Coding agents, AI provider connections, workspace files, and terminals run on the host. Local-first does not mean that everything stays on your phone: the host and the AI providers or tools you use receive the information needed to carry out your requests.</p>
        <p>The current Android app uses host pairing, rather than a Verde Cloud account sign-up or cloud workspace provisioning flow. A host can be on your own computer or infrastructure operated by someone else. If you use a remotely hosted machine, VPN, proxy, or tunnel, the relevant operators also process connection information and, where they terminate the connection or operate the host, may process its contents. This policy does not describe every separate hosted service as if it were enabled by default.</p>

        <h2>Information used to provide the app</h2>
        <ul>
          <li><strong>Pairing and access:</strong> host addresses and names, pairing information, device identifiers and labels, device credentials, access permissions, and trusted TLS key information are used to connect your device, authenticate requests, and control access.</li>
          <li><strong>Chats and agent work:</strong> prompts, replies, conversation titles and transcripts, drafts, selected models and providers, approvals, and task status are handled to run and display your conversations.</li>
          <li><strong>Files and images:</strong> images you select or capture and submit, workspace file paths and contents you open or reference, code, and diffs are handled to attach context, preview files, and perform requested work. Content can contain personal or confidential information you include.</li>
          <li><strong>Terminal and repository operations:</strong> commands, terminal input and output, repository metadata, commit messages, and requested changes are sent to or received from the host. Commands and agent tools can access files and contact other services with the permissions available on that host; repository pushes send data to the configured Git remote.</li>
          <li><strong>Connection and local state:</strong> network status, synchronization cursors, cached views, preferences, and error information support reconnection, restoring the interface, and troubleshooting. Hosts and network services can observe IP addresses and request timing.</li>
        </ul>

        <h2>Who receives information</h2>
        <p>Your paired host processes and can retain the content and operations you send. Its configured AI providers receive prompts, relevant conversation history, attachments, code, and tool results as needed for the selected agent. Tools and integrations may send information to additional destinations when you use them. The host operator, AI providers, Git hosting services, and other services you choose have their own privacy, retention, and account settings, including any model-training settings. Review those settings before sending sensitive information.</p>
        <p>Verde does not sell your personal information or use your chat content for advertising. This does not mean the app has no third-party data flows: the QR scanning SDK described below sends technical metrics to Google.</p>

        <h2>Camera, selected media, and device authentication</h2>
        <p>Camera permission enables pairing QR-code scanning and taking photos for attachments. You can pair manually without scanning. Android’s photo and file pickers let you choose attachment images without granting broad access to your photo library. Photos submitted in a chat are sent to your paired host and can be passed to the selected AI provider.</p>
        <p>QR scanning uses Google ML Kit. Google states that scan images and recognition results are processed on-device and are not sent to its servers by ML Kit. The SDK sends technical data to Google, including device and app information, per-installation identifiers, performance metrics, API configuration, input/output sizes, feature versions, events, and error codes. Google uses these for diagnostics, usage analytics, maintenance, and abuse prevention. See <a href="https://developers.google.com/ml-kit/terms">ML Kit privacy information</a>, <a href="https://developers.google.com/ml-kit/android-data-disclosure">its Android data disclosures</a>, and <a href="https://policies.google.com/privacy">Google’s Privacy Policy</a>.</p>
        <p>Optional app lock uses Android’s biometric or device-credential prompt. Verde receives the authentication outcome, not your fingerprint, face template, or screen-lock secret. Internet and network-state access enable host communication and reconnection. You can manage camera permission and app data in Android Settings.</p>

        <h2>Storage, retention, and deletion</h2>
        <p>The phone stores pairing credentials and local app records, including cached views and drafts, using app-private storage. Credential and view-cache stores are encrypted with keys protected by Android Keystore. The app disables Android cloud backup. Temporary camera captures use the app’s private cache; file previews also use temporary in-memory storage. Session access tokens are kept in memory.</p>
        <p>Local pairing and cached records remain until removed by app actions, cache replacement, or clearing the app’s storage. Use sign out or forget/remove host to clear that host’s local credentials and associated cached records. Clear Verde’s storage in Android Settings or uninstall it to remove remaining app-local data. Copies you separately saved or shared must be removed separately.</p>
        <p>Removing the app or forgetting a host does not delete chats, files, logs, repository history, or backups on the host or at AI providers. Use the host’s deletion controls or ask its operator to delete records and revoke device access. Use the relevant provider’s controls for data held by that provider. Host and provider retention depends on their configuration and policies; Verde does not promise a universal retention period or automatic deletion of those copies.</p>
        <p>If you email support, the Verde developer and email service providers receive your address and the contents you send, for responding and resolving the issue. Support correspondence is retained as needed to handle the request and related follow-up; request deletion at <a href="mailto:developer@verdeai.dev">developer@verdeai.dev</a>. Avoid including credentials, pairing codes, or private workspace content. We can address records under our control, but cannot delete data held only by your host operator or other providers.</p>

        <h2>Security</h2>
        <p>Android host connections use encrypted HTTPS/WSS transport and pin the host’s TLS public key during pairing. The app blocks cleartext host traffic. Verify that you trust the host before pairing or accepting a changed key, protect your phone and host, and revoke lost devices. Encryption in transit does not prevent the destination host or selected provider from processing the content, and no storage or transmission method can guarantee absolute security.</p>

        <h2>This website</h2>
        <p>The Verde website is served through Cloudflare. Requests expose information such as your IP address, browser/request details, requested URL, and timing to the hosting service for delivery, security, and operational logging. If you choose a theme, a <code>verde_theme</code> cookie remembers that preference; you can clear it in your browser. Website operational records follow the hosting service’s configuration and retention practices. See <a href="https://www.cloudflare.com/privacypolicy/">Cloudflare’s Privacy Policy</a>. The site also loads fonts from Google Fonts, which receives your IP address and browser request information when those fonts are fetched. See <a href="https://developers.google.com/fonts/faq/privacy">Google Fonts privacy information</a>. Following an external link subjects your visit to that destination’s policies.</p>

        <h2>Changes and contact</h2>
        <p>We will update this page and its effective date when these practices change. For questions about this policy or access, correction, or deletion requests concerning information held by the Verde developer, email <a href="mailto:developer@verdeai.dev">developer@verdeai.dev</a>.</p>
        <p class="privacy-back"><a href="/">Back to Verde</a></p>
      </article>
    </main>
  )
}
