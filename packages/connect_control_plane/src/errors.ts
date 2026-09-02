export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly details?: Record<string, unknown>,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

export function conflict(code: string, message: string): never {
  throw new ApiError(409, code, message);
}

export function forbidden(code: string, message: string): never {
  throw new ApiError(403, code, message);
}

export function notFound(code: string, message: string): never {
  throw new ApiError(404, code, message);
}
