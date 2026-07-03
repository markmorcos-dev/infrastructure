import { NextRequest, NextResponse } from "next/server";
import { requireAdmin } from "@/lib/cms/authz";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

// Analytics was extracted to its own service. The admin global dashboard keeps
// its session gate (requireAdmin) and proxies to that service with the shared
// admin secret. The dashboard UI's relative fetch is unchanged.
const BASE =
  process.env.ANALYTICS_SERVICE_URL ??
  "http://analytics-analytics-service.analytics.svc.cluster.local:3000";
const SECRET = process.env.ANALYTICS_ADMIN_SECRET ?? "";

export async function GET(req: NextRequest) {
  const gate = requireAdmin(req);
  if ("error" in gate) return gate.error;

  const search = new URL(req.url).search;
  const res = await fetch(`${BASE}/api/admin/analytics${search}`, {
    headers: { authorization: `Bearer ${SECRET}` },
    cache: "no-store",
  });
  const text = await res.text();
  return new NextResponse(text, {
    status: res.status,
    headers: { "content-type": res.headers.get("content-type") ?? "application/json" },
  });
}
