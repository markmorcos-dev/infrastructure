import { NextRequest, NextResponse } from "next/server";

// CMS was extracted to its own service (cms.morcos.tech, own DB). Admin keeps the
// CMS console UI; these routes now proxy to that service. cms shares admin's
// JWT_SECRET, so forwarding the admin session `token` cookie is enough — the
// service's requireAdmin/getSessionUser verify it. The Authorization header is
// forwarded too for the token/service surfaces.
export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const BASE = process.env.CMS_SERVICE_URL ?? "http://cms-cms-service.cms.svc.cluster.local:3000";

async function proxy(req: NextRequest, path: string[]): Promise<NextResponse> {
  const search = new URL(req.url).search;
  const target = `${BASE}/api/cms/${path.join("/")}${search}`;
  const headers: Record<string, string> = {};
  const cookie = req.headers.get("cookie");
  if (cookie) headers["cookie"] = cookie;
  const auth = req.headers.get("authorization");
  if (auth) headers["authorization"] = auth;
  const ct = req.headers.get("content-type");
  if (ct) headers["content-type"] = ct;

  const method = req.method;
  const body =
    method === "GET" || method === "HEAD" ? undefined : Buffer.from(await req.arrayBuffer());

  const res = await fetch(target, { method, headers, body, cache: "no-store" });
  const out = new NextResponse(Buffer.from(await res.arrayBuffer()), { status: res.status });
  const oct = res.headers.get("content-type");
  if (oct) out.headers.set("content-type", oct);
  return out;
}

type Ctx = { params: Promise<{ path: string[] }> };
const handler = async (req: NextRequest, ctx: Ctx) => proxy(req, (await ctx.params).path);

export { handler as GET, handler as POST, handler as PUT, handler as PATCH, handler as DELETE };
