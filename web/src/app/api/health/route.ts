/** Liveness/readiness probe for Kubernetes. */
export function GET() {
  return Response.json({ status: "ok" });
}
