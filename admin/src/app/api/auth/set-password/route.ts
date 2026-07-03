import { NextRequest, NextResponse } from "next/server";
import jwt from "jsonwebtoken";
import { serialize } from "cookie";
import { pool } from "@/lib/db";
import { verifyInviteToken } from "@/lib/cms/authz";
import { updateUser } from "@/lib/users";

// Completes the onboarding invite: verifies the emailed token, sets the owner's
// password, and logs them in (session cookie) so they land in the CMS.

export async function POST(req: NextRequest) {
  let body: { token?: string; password?: string };
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ error: "invalid json" }, { status: 400 });
  }

  const invite = body.token ? verifyInviteToken(body.token) : null;
  if (!invite) {
    return NextResponse.json({ error: "invalid or expired link" }, { status: 401 });
  }
  const password = body.password ?? "";
  if (password.length < 8) {
    return NextResponse.json({ error: "password must be at least 8 characters" }, { status: 422 });
  }

  const { rows } = await pool.query(`SELECT email, role FROM users WHERE id = $1`, [invite.userId]);
  if (rows.length === 0) {
    return NextResponse.json({ error: "account not found" }, { status: 404 });
  }
  const user = rows[0] as { email: string; role: string };

  await updateUser(invite.userId, { password });

  const token = jwt.sign(
    { userId: invite.userId, email: user.email, role: user.role },
    process.env.JWT_SECRET as string,
    { expiresIn: "7d" }
  );
  const cookie = serialize("token", token, {
    httpOnly: true,
    path: "/",
    maxAge: 60 * 60 * 24 * 7,
    sameSite: "lax",
    secure: process.env.NODE_ENV === "production",
  });
  const res = NextResponse.json({
    ok: true,
    id: invite.userId,
    email: user.email,
    role: user.role,
  });
  res.headers.set("Set-Cookie", cookie);
  return res;
}
