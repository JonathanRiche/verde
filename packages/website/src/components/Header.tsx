import { Link } from '@tanstack/solid-router'

import verdeLogo from '../../../desktop/src/assets/verde_logo.png'

export default function Header() {
  return (
    <header class="site-header">
      <nav class="page-wrap site-nav" aria-label="Primary">
        <Link to="/" class="site-brand">
          <img src={verdeLogo} alt="Verde" class="site-brand-logo" />
          <span>verde</span>
        </Link>

        <div class="site-links">
          <a href="/#product" class="nav-link">
            Product
          </a>
          <a href="/#flow" class="nav-link">
            Workflow
          </a>
          <a href="/#install" class="nav-link">
            Install
          </a>
        </div>

        <a
          href="https://github.com/JonathanRiche/verde/releases"
          target="_blank"
          rel="noreferrer"
          class="nav-cta"
        >
          Get Verde
        </a>
      </nav>
    </header>
  )
}
