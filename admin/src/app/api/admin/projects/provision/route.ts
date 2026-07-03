import { NextRequest, NextResponse } from "next/server";
import { pool } from "@/lib/db";
import { mintDeploymentToken } from "@/lib/jwt";
import {
  GITHUB_OWNER,
  parseRepo,
  repoExists,
  createRepo,
  putRepoSecret,
  createFileIfAbsent,
  registerDispatchType,
} from "@/lib/github";
import { deployWorkflow } from "@/lib/scaffold";
import { getStack, deploymentYaml, StackOpts, EnvVar } from "@/lib/templates";
import { ensureNamespace, upsertNamespaceSecret } from "@/lib/k8s";
import { provisionPostgres } from "@/lib/postgres-provision";
import { provisionRedis } from "@/lib/redis-provision";

// Data stores that the provisioner can stand up (db-per-app). Each maps to the
// secret-ref env injected into the scaffolded deployment.yaml.
const SUPPORTED_DB = new Set(["postgres", "redis"]);
const DATA_ENV: Record<string, EnvVar> = {
  postgres: { name: "DATABASE_URL", secret: { name: "database-secrets", key: "DATABASE_URL" } },
  redis: { name: "REDIS_URL", secret: { name: "database-secrets", key: "REDIS_URL" } },
};

type StepStatus = "created" | "exists" | "set" | "registered" | "updated" | "error";
interface Step {
  step: string;
  status: StepStatus;
  detail?: string;
}

function errMessage(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

export async function POST(req: NextRequest) {
  const body = await req.json();
  const projectName: string | undefined = body.projectName;
  if (!projectName) {
    return NextResponse.json({ error: "projectName is required" }, { status: 400 });
  }
  // projectName becomes the namespace, repo, db, and role — enforce a strict
  // RFC1123 label so an invalid value can't create junk repos/rows/namespaces.
  if (!/^[a-z][a-z0-9-]{0,62}$/.test(projectName)) {
    return NextResponse.json(
      { error: "projectName must be a lowercase RFC1123 label: ^[a-z][a-z0-9-]{0,62}$" },
      { status: 400 }
    );
  }

  const stack = getStack(body.stack || "nextjs");
  if (!stack) {
    return NextResponse.json({ error: "unknown stack" }, { status: 400 });
  }

  // Owner is chosen per-provision (UI dropdown): the personal account or the
  // platform org. Falls back to the GITHUB_OWNER default. An explicit body.repo
  // ("owner/name") still overrides both.
  const owner: string = typeof body.owner === "string" && body.owner ? body.owner : GITHUB_OWNER;
  const repo: string = body.repo || `${owner}/${projectName}`;
  const namespace: string = body.namespace || projectName;
  const configFile = "deployment.yaml";
  const isPrivate: boolean = body.private !== false;
  const repoName = repo.includes("/") ? repo.split("/")[1] : repo;

  const opts: StackOpts = {
    project: projectName,
    namespace,
    port: Number(body.port) || stack.defaultPort,
    ingressHost: body.ingressHost || `${projectName}.morcos.tech`,
    env: Array.isArray(body.env)
      ? body.env.filter((e: { name?: string }) => e && e.name)
      : [],
  };

  // Requested data stores (e.g. ["postgres"]). Inject their secret-ref env into
  // the scaffolded deployment.yaml up front — the secret values are created in a
  // later step, but the deployment.yaml only needs the deterministic ref.
  const databases: string[] = Array.isArray(body.databases)
    ? body.databases.filter((d: unknown): d is string => typeof d === "string")
    : [];
  for (const d of databases) {
    if (SUPPORTED_DB.has(d) && DATA_ENV[d]) opts.env.push(DATA_ENV[d]);
  }

  const steps: Step[] = [];
  const run = async (label: string, fn: () => Promise<StepStatus>) => {
    try {
      steps.push({ step: label, status: await fn() });
    } catch (e) {
      steps.push({ step: label, status: "error", detail: errMessage(e) });
    }
  };

  const token = mintDeploymentToken(projectName);

  // 1. Repo (created in the org when repo's owner is one; else under the PAT user)
  const repoOwner = parseRepo(repo).owner;
  await run("repo", async () => {
    if (await repoExists(repo)) return "exists";
    await createRepo(repoName, isPrivate, repoOwner);
    return "created";
  });

  // 2. Secrets (must exist before the deploy workflow runs)
  await run("secret:INFRASTRUCTURE_PAT", async () => {
    await putRepoSecret(repo, "INFRASTRUCTURE_PAT", process.env.GITHUB_PAT as string);
    return "set";
  });
  await run("secret:DEPLOYMENT_TOKEN", async () => {
    await putRepoSecret(repo, "DEPLOYMENT_TOKEN", token);
    return "set";
  });

  // 3. Scaffold the app + deployment config FIRST (so the build has something
  //    to build), then register the dispatch type, then commit the workflow
  //    LAST — that final push is what triggers the (now buildable) auto-deploy.
  await run("scaffold:deployment.yaml", () =>
    createFileIfAbsent(repo, configFile, deploymentYaml(opts, stack.ingress), "chore: add deployment config")
  );
  for (const [path, content] of Object.entries(stack.files(opts))) {
    await run(`scaffold:${path}`, () =>
      createFileIfAbsent(repo, path, content, `chore: scaffold ${path}`)
    );
  }

  // 3b. Provision requested data stores (db-per-app) + their secrets BEFORE the
  //     workflow commit triggers the first deploy, so the pod finds them.
  for (const service of databases) {
    if (!SUPPORTED_DB.has(service)) {
      steps.push({ step: `data:${service}`, status: "error", detail: "unsupported" });
      continue;
    }
    if (service === "postgres") {
      await run("data:postgres:namespace", () => ensureNamespace(namespace));
      let conn: string | null = null;
      await run("data:postgres:database", async () => {
        const r = await provisionPostgres(projectName);
        conn = r.connectionString;
        return r.status;
      });
      // The connection string is sensitive — only written to the secret, never
      // returned in a step detail.
      await run("data:postgres:secret", async () => {
        if (!conn) throw new Error("database step did not yield a connection string");
        await upsertNamespaceSecret(namespace, "database-secrets", { DATABASE_URL: conn });
        return "set";
      });
    }
    if (service === "redis") {
      await run("data:redis:namespace", () => ensureNamespace(namespace));
      let conn: string | null = null;
      await run("data:redis:user", async () => {
        const r = await provisionRedis(projectName);
        conn = r.connectionString;
        return r.status;
      });
      await run("data:redis:secret", async () => {
        if (!conn) throw new Error("redis step did not yield a connection string");
        await upsertNamespaceSecret(namespace, "database-secrets", { REDIS_URL: conn });
        return "set";
      });
    }
  }

  // 4. Register dispatch type in infrastructure (before the workflow fires)
  await run("dispatch-type", () => registerDispatchType(projectName));

  // 5. Workflow last — triggers the auto-deploy
  await run("scaffold:workflow", () =>
    createFileIfAbsent(
      repo,
      `.github/workflows/deploy-${projectName}.yaml`,
      deployWorkflow(projectName, repo, configFile),
      `ci: add deploy-${projectName} workflow`
    )
  );

  // 6. Upsert DB row
  await run("db", async () => {
    const { rowCount } = await pool.query(
      `INSERT INTO projects (project_name, token, repo, namespace)
       VALUES ($1, $2, $3, $4)
       ON CONFLICT (project_name)
       DO UPDATE SET token = $2, repo = $3, namespace = $4, updated_at = now()`,
      [projectName, token, repo, namespace]
    );
    return rowCount === 1 ? "created" : "updated";
  });

  const ok = !steps.some((s) => s.status === "error");
  return NextResponse.json(
    { projectName, repo, namespace, ok, steps },
    { status: ok ? 200 : 207 }
  );
}
