"use client";

import React, { useState } from "react";
import { useRouter } from "next/navigation";
import { Button, Card, Input, Label } from "@/components/ui";
import { STACK_LIST } from "@/lib/templates";

interface Step {
  step: string;
  status: string;
  detail?: string;
}
interface Result {
  projectName: string;
  repo: string;
  ok: boolean;
  steps: Step[];
}

const OK = ["created", "exists", "set", "registered", "updated"];

const DATA_SERVICES: { id: string; label: string; enabled: boolean }[] = [
  { id: "postgres", label: "Postgres", enabled: true },
  { id: "redis", label: "Redis", enabled: true },
  { id: "mongo", label: "Mongo", enabled: false },
  { id: "minio", label: "MinIO", enabled: false },
];

// GitHub owner for the new repo: the platform org (default) or the personal
// account. Chosen per-provision.
const OWNER_OPTIONS = ["markmorcos-dev", "markmorcos"];

export default function ProvisionPage() {
  const router = useRouter();
  const [name, setName] = useState("");
  const [owner, setOwner] = useState(OWNER_OPTIONS[0]);
  const [repo, setRepo] = useState("");
  const [namespace, setNamespace] = useState("");
  const [stack, setStack] = useState(STACK_LIST[0].id);
  const [port, setPort] = useState(String(STACK_LIST[0].defaultPort));
  const [ingressHost, setIngressHost] = useState("");
  const [env, setEnv] = useState<{ name: string; value: string }[]>([]);
  const [databases, setDatabases] = useState<string[]>([]);
  const [isPrivate, setIsPrivate] = useState(true);

  const toggleDb = (id: string) =>
    setDatabases((arr) => (arr.includes(id) ? arr.filter((x) => x !== id) : [...arr, id]));
  const [running, setRunning] = useState(false);
  const [shown, setShown] = useState<Step[]>([]);
  const [result, setResult] = useState<Result | null>(null);
  const [error, setError] = useState<string | null>(null);

  const now = () => new Date().toISOString().slice(11, 19);

  const pickStack = (id: string) => {
    setStack(id);
    const s = STACK_LIST.find((x) => x.id === id);
    if (s) setPort(String(s.defaultPort));
  };

  const provision = async () => {
    setRunning(true);
    setError(null);
    setResult(null);
    setShown([]);
    try {
      const res = await fetch("/api/admin/projects/provision", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          projectName: name,
          owner,
          repo: repo || undefined,
          namespace: namespace || undefined,
          stack,
          port: Number(port) || undefined,
          ingressHost: ingressHost || undefined,
          env: env.filter((e) => e.name),
          databases,
          private: isPrivate,
        }),
      });
      const d = await res.json();
      if (res.status >= 400 && d.error) {
        setError(d.error);
        setRunning(false);
        return;
      }
      // stream the steps in one-by-one for a live build-log feel
      for (let i = 0; i < d.steps.length; i++) {
        await new Promise((r) => setTimeout(r, 420));
        setShown((s) => [...s, d.steps[i]]);
      }
      setRunning(false);
      setResult(d);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setRunning(false);
    }
  };

  const headerDot = error
    ? "var(--cp-err)"
    : running
    ? "var(--cp-warn)"
    : result
    ? "var(--cp-ok)"
    : "var(--md-sys-color-outline)";

  return (
    <div className="grid grid-cols-1 items-start gap-[14px] px-[14px] pb-12 pt-4 md:grid-cols-[380px_1fr] md:gap-[18px] md:px-7 md:pb-[60px] md:pt-6">
      {/* FORM */}
      <Card pad={false} className="static p-4 md:sticky md:top-[90px] md:p-[22px]">
        <div style={{ fontFamily: "var(--cp-mono)", fontSize: 11, letterSpacing: ".08em", color: "var(--md-sys-color-on-surface-variant)", marginBottom: 18 }}>{"// NEW PROJECT"}</div>
        {[
          { label: "NAME", value: name, set: setName, ph: "my-new-app" },
          { label: "REPOSITORY", value: repo, set: setRepo, ph: name ? `markmorcos/${name}` : "markmorcos/my-new-app" },
          { label: "NAMESPACE", value: namespace, set: setNamespace, ph: name || "my-new-app" },
        ].map((f) => (
          <div key={f.label} style={{ marginBottom: 16 }}>
            <Label>{f.label}</Label>
            <Input value={f.value} onChange={(e) => f.set(e.target.value)} placeholder={f.ph} style={{ marginTop: 7 }} />
          </div>
        ))}

        <div style={{ marginBottom: 16 }}>
          <Label>GITHUB OWNER</Label>
          <div style={{ display: "flex", gap: 6, marginTop: 7, flexWrap: "wrap" }}>
            {OWNER_OPTIONS.map((o) => {
              const active = owner === o;
              return (
                <button
                  key={o}
                  onClick={() => setOwner(o)}
                  style={{
                    flex: "1 1 45%",
                    height: 38,
                    borderRadius: 9,
                    cursor: "pointer",
                    fontFamily: "var(--cp-mono)",
                    fontSize: 12,
                    border: "1px solid " + (active ? "var(--md-sys-color-primary)" : "var(--md-sys-color-outline-variant)"),
                    background: active ? "var(--md-sys-color-primary-container)" : "var(--md-sys-color-surface-container)",
                    color: active ? "var(--md-sys-color-on-primary-container)" : "var(--md-sys-color-on-surface-variant)",
                  }}
                >
                  {o}
                </button>
              );
            })}
          </div>
        </div>

        <div style={{ marginBottom: 16 }}>
          <Label>STACK</Label>
          <div style={{ display: "flex", gap: 6, marginTop: 7, flexWrap: "wrap" }}>
            {STACK_LIST.map((s) => {
              const active = stack === s.id;
              return (
                <button
                  key={s.id}
                  onClick={() => pickStack(s.id)}
                  style={{
                    flex: "1 1 45%",
                    height: 38,
                    borderRadius: 9,
                    cursor: "pointer",
                    fontFamily: "var(--cp-mono)",
                    fontSize: 12,
                    border: "1px solid " + (active ? "var(--md-sys-color-primary)" : "var(--md-sys-color-outline-variant)"),
                    background: active ? "var(--md-sys-color-primary-container)" : "var(--md-sys-color-surface-container)",
                    color: active ? "var(--md-sys-color-on-primary-container)" : "var(--md-sys-color-on-surface-variant)",
                  }}
                >
                  {s.label}
                </button>
              );
            })}
          </div>
        </div>

        <div style={{ display: "flex", gap: 10, marginBottom: 16 }}>
          <div style={{ width: 110 }}>
            <Label>PORT</Label>
            <Input value={port} onChange={(e) => setPort(e.target.value)} style={{ marginTop: 7 }} />
          </div>
          <div style={{ flex: 1 }}>
            <Label>INGRESS HOST</Label>
            <Input value={ingressHost} onChange={(e) => setIngressHost(e.target.value)} placeholder={name ? `${name}.morcos.tech` : "my-new-app.morcos.tech"} style={{ marginTop: 7 }} />
          </div>
        </div>

        <div style={{ marginBottom: 16 }}>
          <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 7 }}>
            <Label>ENV</Label>
            <Button onClick={() => setEnv((e) => [...e, { name: "", value: "" }])} variant="ghost" className="h-[24px] px-2 text-[10.5px]">
              <span className="msym" style={{ fontSize: 13 }}>add</span>add
            </Button>
          </div>
          {env.map((row, i) => (
            <div key={i} style={{ display: "flex", gap: 6, marginBottom: 6 }}>
              <Input value={row.name} onChange={(e) => setEnv((arr) => arr.map((r, j) => (j === i ? { ...r, name: e.target.value } : r)))} placeholder="KEY" style={{ height: 38 }} />
              <Input value={row.value} onChange={(e) => setEnv((arr) => arr.map((r, j) => (j === i ? { ...r, value: e.target.value } : r)))} placeholder="value" style={{ height: 38 }} />
              <Button onClick={() => setEnv((arr) => arr.filter((_, j) => j !== i))} variant="soft" className="w-[38px] h-[38px] p-0">
                <span className="msym" style={{ fontSize: 16 }}>close</span>
              </Button>
            </div>
          ))}
        </div>

        <div style={{ marginBottom: 16 }}>
          <Label>DATA SERVICES</Label>
          <div style={{ display: "flex", gap: 6, marginTop: 7, flexWrap: "wrap" }}>
            {DATA_SERVICES.map((s) => {
              const active = databases.includes(s.id);
              return (
                <button
                  key={s.id}
                  onClick={() => s.enabled && toggleDb(s.id)}
                  disabled={!s.enabled}
                  title={s.enabled ? "" : "coming soon"}
                  style={{
                    flex: "1 1 45%",
                    height: 38,
                    borderRadius: 9,
                    cursor: s.enabled ? "pointer" : "not-allowed",
                    opacity: s.enabled ? 1 : 0.45,
                    fontFamily: "var(--cp-mono)",
                    fontSize: 12,
                    display: "flex",
                    alignItems: "center",
                    justifyContent: "center",
                    gap: 6,
                    border: "1px solid " + (active ? "var(--md-sys-color-primary)" : "var(--md-sys-color-outline-variant)"),
                    background: active ? "var(--md-sys-color-primary-container)" : "var(--md-sys-color-surface-container)",
                    color: active ? "var(--md-sys-color-on-primary-container)" : "var(--md-sys-color-on-surface-variant)",
                  }}
                >
                  <span className="msym" style={{ fontSize: 15 }}>{active ? "check_box" : "check_box_outline_blank"}</span>
                  {s.label}{s.enabled ? "" : " · soon"}
                </button>
              );
            })}
          </div>
          <div style={{ fontFamily: "var(--cp-mono)", fontSize: 10.5, color: "var(--md-sys-color-outline)", marginTop: 7 }}>
            creates a db-per-app + least-privilege user, writes the connection string to a namespace secret, and wires the env ref.
          </div>
        </div>

        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", padding: "12px 14px", borderRadius: 10, background: "var(--md-sys-color-surface-container)", border: "1px solid var(--md-sys-color-outline-variant)" }}>
          <div style={{ fontFamily: "var(--cp-mono)", fontSize: 12.5 }}>private repository</div>
          <button
            onClick={() => setIsPrivate((v) => !v)}
            style={{ width: 40, height: 24, borderRadius: 9999, border: "none", cursor: "pointer", padding: 2, background: isPrivate ? "var(--md-sys-color-primary)" : "var(--md-sys-color-surface-container-highest)", display: "flex", justifyContent: isPrivate ? "flex-end" : "flex-start", alignItems: "center" }}
          >
            <span style={{ width: 20, height: 20, borderRadius: "50%", background: isPrivate ? "var(--md-sys-color-on-primary)" : "var(--md-sys-color-outline)" }} />
          </button>
        </div>
        <Button onClick={provision} disabled={running || !name} variant="primary" className="w-full h-[46px] mt-[18px] text-[13px]">
          <span className="msym" style={{ fontSize: 18, animation: running ? "cpSpin 1s linear infinite" : "none" }}>{running ? "progress_activity" : "rocket_launch"}</span>
          {running ? "provisioning…" : "provision"}
        </Button>
      </Card>

      {/* BUILD LOG */}
      <Card pad={false} style={{ background: "var(--md-sys-color-surface-container-lowest)", overflow: "hidden", minHeight: 440, display: "flex", flexDirection: "column" }}>
        <div style={{ display: "flex", alignItems: "center", gap: 10, padding: "13px 18px", borderBottom: "1px solid var(--md-sys-color-outline-variant)", background: "var(--md-sys-color-surface-container-low)" }}>
          <span style={{ width: 10, height: 10, borderRadius: "50%", background: headerDot }} />
          <span style={{ fontFamily: "var(--cp-mono)", fontSize: 12, letterSpacing: ".06em", color: "var(--md-sys-color-on-surface-variant)" }}>
            build log{name ? ` · ${name}` : ""}
          </span>
          <div style={{ flex: 1 }} />
          <span style={{ fontFamily: "var(--cp-mono)", fontSize: 11, color: "var(--md-sys-color-outline)" }}>
            {running ? "running" : result ? "done" : error ? "error" : "idle"}
          </span>
        </div>
        <div style={{ flex: 1, padding: "16px 18px", fontFamily: "var(--cp-mono)", fontSize: 12.5, lineHeight: 1.5, overflow: "auto" }}>
          {shown.length === 0 && !running && !error && (
            <div style={{ display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", height: 340, color: "var(--md-sys-color-outline)", textAlign: "center" }}>
              <span className="msym" style={{ fontSize: 40, opacity: 0.6, marginBottom: 14 }}>terminal</span>
              <div>fill in the form and run a provision —</div>
              <div>each step will land here, live.</div>
            </div>
          )}
          {error && (
            <div style={{ display: "flex", alignItems: "center", gap: 9, color: "var(--cp-err)" }}>
              <span className="msym" style={{ fontSize: 16 }}>error</span>{error}
            </div>
          )}
          {shown.map((s, i) => {
            const ok = OK.includes(s.status);
            return (
              <div key={i} style={{ display: "flex", alignItems: "flex-start", gap: 11, padding: "5px 0", animation: "cpLogIn .28s cubic-bezier(.2,0,0,1) both" }}>
                <span style={{ color: "var(--md-sys-color-outline)", flexShrink: 0, fontSize: 11, paddingTop: 1 }}>{now()}</span>
                <span className="msym" style={{ fontSize: 16, flexShrink: 0, color: ok ? "var(--cp-ok)" : "var(--cp-err)" }}>{ok ? "check" : "error"}</span>
                <span style={{ color: "var(--md-sys-color-on-surface)", flex: 1 }}>{s.step}</span>
                <span style={{ fontFamily: "var(--cp-mono)", fontSize: 10.5, padding: "2px 9px", borderRadius: 6, flexShrink: 0, background: ok ? "var(--cp-ok-dim)" : "var(--cp-err-dim)", color: ok ? "var(--cp-ok)" : "var(--cp-err)" }}>
                  {s.status}{s.detail ? `: ${s.detail}` : ""}
                </span>
              </div>
            );
          })}
          {running && (
            <div style={{ display: "flex", alignItems: "center", gap: 8, padding: "5px 0" }}>
              <span style={{ width: 8, height: 15, background: "var(--md-sys-color-primary)", animation: "cpBlink 1s step-end infinite", display: "inline-block" }} />
            </div>
          )}
          {result && (
            <div style={{ display: "flex", alignItems: "center", gap: 12, marginTop: 14, padding: "14px 16px", borderRadius: 12, background: result.ok ? "var(--cp-ok-dim)" : "var(--cp-err-dim)", border: "1px solid " + (result.ok ? "rgba(70,224,160,.25)" : "rgba(255,122,107,.25)"), animation: "cpFade .4s both" }}>
              <span className="msym fill" style={{ fontSize: 22, color: result.ok ? "var(--cp-ok)" : "var(--cp-err)" }}>{result.ok ? "task_alt" : "report"}</span>
              <div style={{ flex: 1 }}>
                <div style={{ fontFamily: "var(--cp-mono)", fontSize: 13, color: result.ok ? "var(--cp-ok)" : "var(--cp-err)", fontWeight: 600 }}>{result.projectName} {result.ok ? "provisioned" : "completed with errors"}</div>
                <div style={{ fontFamily: "var(--cp-mono)", fontSize: 11, color: "var(--md-sys-color-on-surface-variant)", marginTop: 2 }}>repo + secrets + CI scaffold</div>
              </div>
              <Button onClick={() => router.push("/projects")} variant="primary" className="h-[36px] px-4 text-[12px]">view fleet</Button>
            </div>
          )}
        </div>
      </Card>
    </div>
  );
}
