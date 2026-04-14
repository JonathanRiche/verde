import { Link } from '@tanstack/solid-router'

import verdeLogo from '../../../desktop/src/assets/verde_logo.png'

export default function Header() {
  return (
    <header class="site-header">
      <nav class="wrap header-inner" aria-label="Primary">
        <Link to="/" class="brand">
          <img src={verdeLogo} alt="Verde" class="brand-logo" />
          <span>verde</span>
        </Link>

        <div class="nav-links">
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
