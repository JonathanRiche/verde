const SECRET = [0xa0761d6478bd642fn, 0xe7037ed1a0b428dbn, 0x8ebc6af09c88c6e3n, 0x589965cc75374cc3n]

function mask(value: bigint): bigint {
  return value & 0xffffffffffffffffn
}

function mix(left: bigint, right: bigint): bigint {
  const product = mask(left) * mask(right)
  return mask(product) ^ (product >> 64n)
}

function read(bytes: Uint8Array, offset: number, size: number): bigint {
  let value = 0n
  for (let index = 0; index < size; index++) {
    value |= BigInt(bytes[offset + index] ?? 0) << BigInt(8 * index)
  }
  return value
}

function smallKey(input: Uint8Array): { a: bigint; b: bigint } {
  if (input.length >= 4) {
    const end = input.length - 4
    const quarter = (input.length >> 3) << 2
    return {
      a: (read(input, 0, 4) << 32n) | read(input, quarter, 4),
      b: (read(input, end, 4) << 32n) | read(input, end - quarter, 4),
    }
  }
  if (input.length > 0) {
    return {
      a: (BigInt(input[0]!) << 16n) | (BigInt(input[input.length >> 1]!) << 8n) | BigInt(input[input.length - 1]!),
      b: 0n,
    }
  }
  return { a: 0n, b: 0n }
}

export function wyhash(input: Uint8Array, seed = 0n): bigint {
  let state0 = seed ^ mix(seed ^ SECRET[0]!, SECRET[1]!)
  const state = [state0, state0, state0]
  let a = 0n
  let b = 0n

  if (input.length <= 16) {
    const key = smallKey(input)
    a = key.a
    b = key.b
  } else {
    let index = 0
    if (input.length >= 48) {
      while (index + 48 < input.length) {
        for (let round = 0; round < 3; round++) {
          const left = read(input, index + 8 * (2 * round), 8)
          const right = read(input, index + 8 * (2 * round + 1), 8)
          state[round] = mix(left ^ SECRET[round + 1]!, right ^ state[round]!)
        }
        index += 48
      }
      state[0] = state[0]! ^ state[1]! ^ state[2]!
    }
    const slice = input.subarray(index)
    let cursor = 0
    while (cursor + 16 < slice.length) {
      state[0] = mix(read(slice, cursor, 8) ^ SECRET[1]!, read(slice, cursor + 8, 8) ^ state[0]!)
      cursor += 16
    }
    a = read(input, input.length - 16, 8)
    b = read(input, input.length - 8, 8)
  }

  a ^= SECRET[1]!
  b ^= state[0]!
  const product = mask(a) * mask(b)
  a = mask(product)
  b = product >> 64n
  return mix(a ^ SECRET[0]! ^ BigInt(input.length), b ^ SECRET[1]!)
}

export function linuxWorkspaceId(path: string): string {
  const bytes = new TextEncoder().encode(path)
  return wyhash(bytes, 0n).toString(16)
}
