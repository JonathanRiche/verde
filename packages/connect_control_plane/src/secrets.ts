import { sha256Base64Url } from "./ids.ts";

/** Mutable secret material that cannot be serialized or formatted accidentally. */
export class SecretBytes {
  readonly #bytes: Uint8Array;
  #destroyed = false;

  private constructor(bytes: Uint8Array) {
    this.#bytes = bytes;
  }

  static random(size = 32): SecretBytes {
    return new SecretBytes(crypto.getRandomValues(new Uint8Array(size)));
  }

  static copy(bytes: Uint8Array): SecretBytes {
    return new SecretBytes(Uint8Array.from(bytes));
  }

  toString(): string {
    return "[REDACTED]";
  }

  toJSON(): string {
    return "[REDACTED]";
  }

  async verifier(): Promise<string> {
    this.assertLive();
    return sha256Base64Url(this.#bytes);
  }

  /** Copies bytes solely for immediate authenticated encryption; zero the copy in finally. */
  copyForSealing(): Uint8Array {
    this.assertLive();
    return Uint8Array.from(this.#bytes);
  }

  destroy(): void {
    this.#bytes.fill(0);
    this.#destroyed = true;
  }

  private assertLive(): void {
    if (this.#destroyed) {
      throw new Error("secret material has already been destroyed");
    }
  }
}
