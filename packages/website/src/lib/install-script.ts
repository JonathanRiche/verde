export const macosInstallCliScript = String.raw`macos_install_cli() {
  app_executable="$MACOS_APP_DIR/Verde.app/Contents/MacOS/verde"
  cli_dir="$PREFIX/bin"
  cli_path="$cli_dir/verde"

  mkdir -p "$cli_dir"
  ln -sf "$app_executable" "$cli_path"
  say "CLI: $cli_path"

  case ":$PATH:" in
    *":$cli_dir:"*) return ;;
  esac

  if [ "$PREFIX" != "$HOME/.local" ]; then
    say "Add $cli_dir to PATH to run Verde as: verde"
    return
  fi

  case "${'${'}SHELL:-/bin/zsh}" in
    */zsh)
      zsh_config_dir="${'${'}ZDOTDIR:-$HOME}"
      zprofile="$zsh_config_dir/.zprofile"
      path_line='export PATH="$HOME/.local/bin:$PATH"'
      mkdir -p "$zsh_config_dir"
      if ! grep -F "$path_line" "$zprofile" >/dev/null 2>&1; then
        printf '\n# Added by the Verde installer\n%s\n' "$path_line" >> "$zprofile"
        say "Added $cli_dir to PATH in $zprofile"
      fi
      say "Open a new terminal, then run Verde with: verde"
      ;;
    *)
      say "Add $cli_dir to PATH to run Verde as: verde"
      ;;
  esac
}`
