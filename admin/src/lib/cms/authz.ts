import { NextRequest, NextResponse } from "next/server";
import jwt from "jsonwebtoken";

// Control-plane auth. Stateless (session JWT only) since CMS + its per-site
// ownership moved to the cms service; the control plane is admin-only.

// verifyInviteToken backs the onboarding set-password flow: a newly-spawned
// owner is emailed a link carrying this token (minted by the onboarding
// service); set-password verifies it and sets their password.
export function verifyInviteToken(token: string): { userId: number; email: string } | null {
  try {
    const p = jwt.verify(token, process.env.JWT_SECRET as string) as {
      kind?: string;
      userId?: number | string;
      email?: string;
    };
    if (p.kind !== "invite" || p.userId === undefined || !p.email) return null;
    return { userId: Number(p.userId), email: p.email };
  } catch {
    return null;
  }
}

export interface SessionUser {
  userId: number;
  email: string;
  role: string;
}

export function getSessionUser(req: NextRequest): SessionUser | null {
  const token = req.cookies.get("token")?.value;
  if (!token) return null;
  try {
    const p = jwt.verify(token, process.env.JWT_SECRET as string) as {
      userId: number | string;
      email: string;
      role: string;
    };
    return { userId: Number(p.userId), email: p.email, role: p.role };
  } catch {
    return null;
  }
}

export function isAdmin(u: SessionUser | null): boolean {
  return !!u && u.role === "admin";
}

type Guard = { user: SessionUser } | { error: NextResponse };

// requireAdmin gates an admin-only handler. Returns the user, or a response to
// return as-is (401 unauthenticated / 403 non-admin).
export function requireAdmin(req: NextRequest): Guard {
  const user = getSessionUser(req);
  if (!user)
    return { error: NextResponse.json({ error: "unauthorized" }, { status: 401 }) };
  if (user.role !== "admin")
    return { error: NextResponse.json({ error: "forbidden" }, { status: 403 }) };
  return { user };
}
