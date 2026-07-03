import { NextRequest, NextResponse } from "next/server";

// Experimentation was extracted into its own service. Admin keeps the console UI;
// these routes are now thin server-side proxies to that service, adding the
// shared admin secret. The UI's relative /api/experimentation/* fetches are
// unchanged. /api/experimentation/v1/* stays public (the service ignores the
// bearer there); /projects/* is gated by the service's shared-secret middleware.
export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const BASE =
  process.env.EXPERIMENTATION_SERVICE_URL ??
  "http://experimentation-experimentation-service.experimentation.svc.cluster.local:3000";
const SECRET = process.env.EXPERIMENTATION_ADMIN_SECRET ?? "";

async function proxy(req: NextRequest, path: string[]): Promise<NextResponse> {
  const search = new URL(req.url).search;
  const target = `${BASE}/api/experimentation/${path.join("/")}${search}`;
  const headers: Record<string, string> = { authorization: `Bearer ${SECRET}` };
  const ct = req.headers.get("content-type");
  if (ct) headers["content-type"] = ct;
  const method = req.method;
  const body = method === "GET" || method === "HEAD" ? undefined : await req.text();
  const res = await fetch(target, { method, headers, body, cache: "no-store" });
  const text = await res.text();
  return new NextResponse(text, {
    status: res.status,
    headers: { "content-type": res.headers.get("content-type") ?? "application/json" },
  });
}

type Ctx = { params: Promise<{ path: string[] }> };
const handler = async (req: NextRequest, ctx: Ctx) => proxy(req, (await ctx.params).path);

export { handler as GET, handler as POST, handler as PUT, handler as PATCH, handler as DELETE };
