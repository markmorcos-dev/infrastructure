import { Pool } from "pg";

type Pg = InstanceType<typeof Pool>;
const g = globalThis as unknown as {
  pgPool?: Pg;
  pgCmsPool?: Pg;
};

// The control plane lives in `public` on DATABASE_URL; the CMS console still uses
// `cmsPool` (search_path cms,public). Experimentation moved to its own service +
// DB — the admin routes proxy to it, so no experimentation pool here anymore.
function makePool(searchPath?: string): Pg {
  return new Pool({
    connectionString: process.env.DATABASE_URL,
    ...(searchPath ? { options: `-c search_path=${searchPath}` } : {}),
  });
}

export const pool = g.pgPool ?? makePool();
export const cmsPool = g.pgCmsPool ?? makePool("cms,public");

if (process.env.NODE_ENV !== "production") {
  g.pgPool = pool;
  g.pgCmsPool = cmsPool;
}
