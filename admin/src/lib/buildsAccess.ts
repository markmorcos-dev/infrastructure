import { NextRequest, NextResponse } from "next/server";
import { getSessionUser, type SessionUser } from "@/lib/cms/authz";
import { cached } from "@/lib/cache";
import { getRunProject, listDeployRuns } from "@/lib/github";

// Builds access control. The control plane is admin-only (the editor tier was
// retired when CMS was extracted — per-site ownership lives in the cms service
// now, not this DB). Admins see every deploy-app run; a non-admin sees none.

// null = unrestricted (admin). An empty Set = a non-admin (no builds visible).
export async function allowedProjects(user: SessionUser): Promise<Set<string> | null> {
  if (user.role === "admin") return null;
  return new Set();
}

type Guard = { user: SessionUser } | { error: NextResponse };

// requireRunAccess authorizes a handler operating on a single run id. Admins
// always pass; an editor passes only if the run's project is in their allowed
// set. The run's project is taken from the cached list when present (no extra
// API call for the runs they're actually viewing), else fetched directly.
export async function requireRunAccess(req: NextRequest, runId: number): Promise<Guard> {
  const user = getSessionUser(req);
  if (!user)
    return { error: NextResponse.json({ error: "unauthorized" }, { status: 401 }) };

  const allowed = await allowedProjects(user);
  if (allowed === null) return { user };

  const runs = await cached("builds", 20_000, () => listDeployRuns(50));
  const known = runs.find((r) => r.id === runId);
  const project = known ? known.project : await getRunProject(runId);

  if (allowed.has(project.toLowerCase())) return { user };
  return { error: NextResponse.json({ error: "forbidden" }, { status: 403 }) };
}
