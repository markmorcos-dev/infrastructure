import { Pool } from "pg";

type Pg = InstanceType<typeof Pool>;
const g = globalThis as unknown as { pgPool?: Pg };

// The control plane lives in `public` on DATABASE_URL. CMS, experimentation, and
// analytics were extracted to their own services + databases — admin proxies to
// them, so there are no per-domain schema pools here anymore.
export const pool = g.pgPool ?? new Pool({ connectionString: process.env.DATABASE_URL });

if (process.env.NODE_ENV !== "production") g.pgPool = pool;
