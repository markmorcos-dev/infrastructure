import { pool } from "@/lib/db";
import bcrypt from "bcrypt";

// User management for the control plane (public.users). Site ownership moved to
// the cms service when CMS was extracted, and the control plane is admin-only
// (no editor tier), so users no longer carry owned sites here. Passwords are
// bcrypt-hashed, matching the login route.

export interface ManagedUser {
  id: number;
  email: string;
  role: string;
  createdAt: Date;
  ownedSites: string[];
}

const BCRYPT_ROUNDS = 10;

export async function listUsers(): Promise<ManagedUser[]> {
  const { rows } = await pool.query(
    `SELECT id, email, role, created_at FROM users ORDER BY created_at`
  );
  return rows.map((r) => ({
    id: Number(r.id),
    email: r.email,
    role: r.role,
    createdAt: r.created_at,
    ownedSites: [],
  }));
}

export async function findUserIdByEmail(email: string): Promise<number | null> {
  const { rows } = await pool.query(`SELECT id FROM users WHERE email = $1`, [email]);
  return rows.length ? Number(rows[0].id) : null;
}

export async function createUser(
  email: string,
  password: string,
  role: string
): Promise<number> {
  const hash = await bcrypt.hash(password, BCRYPT_ROUNDS);
  const { rows } = await pool.query(
    `INSERT INTO users (email, password_hash, role) VALUES ($1, $2, $3) RETURNING id`,
    [email, hash, role]
  );
  return Number(rows[0].id);
}

export async function updateUser(
  id: number,
  fields: { role?: string; password?: string }
): Promise<void> {
  if (fields.role) {
    await pool.query(`UPDATE users SET role = $2 WHERE id = $1`, [id, fields.role]);
  }
  if (fields.password) {
    const hash = await bcrypt.hash(fields.password, BCRYPT_ROUNDS);
    await pool.query(`UPDATE users SET password_hash = $2 WHERE id = $1`, [id, hash]);
  }
}

export async function deleteUser(id: number): Promise<void> {
  await pool.query(`DELETE FROM users WHERE id = $1`, [id]);
}
