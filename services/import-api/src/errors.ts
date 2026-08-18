export class APIError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: string,
    message: string
  ) {
    super(message);
  }
}

export function errorResponse(error: unknown, requestID: string): Response {
  const apiError = error instanceof APIError
    ? error
    : new APIError(500, "internal_error", "The request could not be completed.");
  return Response.json(
    { error: { code: apiError.code, message: apiError.message }, requestID },
    { status: apiError.status, headers: { "Cache-Control": "no-store" } }
  );
}
