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
          <a href="/#providers" class="nav-link">
            Providers
          </a>
          <a href="/#features" class="nav-link">
            Features
          </a>
          <a href="/#cli" class="nav-link">
            CLI
          </a>
          <a href="/#compare" class="nav-link">
            Compare
          </a>
          <a href="/#install" class="nav-link">
            Install
          </a>
          <Link to="/docs" class="nav-link" activeProps={{ class: 'nav-link nav-link--active' }}>
            Docs
          </Link>
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
