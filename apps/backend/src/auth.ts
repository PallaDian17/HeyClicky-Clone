import type { Context, Next } from "hono";
import { createRemoteJWKSet, jwtVerify, type JWTVerifyGetKey } from "jose";
import { env } from "./env.js";

export type AuthedUser = { id: string; email?: string; dev?: boolean };

let jwks: JWTVerifyGetKey | null = null;
function keySource(): JWTVerifyGetKey | Uint8Array | null {
  if (env.supabaseJwtSecret) return new TextEncoder().encode(env.supabaseJwtSecret);
  if (env.supabaseUrl) {
    jwks ??= createRemoteJWKSet(new URL("/auth/v1/.well-known/jwks.json", env.supabaseUrl));
    return jwks;
  }
  return null;
}

export async function verifyBearer(token: string): Promise<AuthedUser> {
  const key = keySource();
  if (!key) throw new Error("Supabase auth is not configured on the server");
  const { payload } = await jwtVerify(token, key as Uint8Array, { audience: "authenticated" });
  if (!payload.sub) throw new Error("token has no subject");
  return { id: payload.sub, email: typeof payload.email === "string" ? payload.email : undefined };
}

/** Hono middleware: sets c.var.user or returns 401. DEV_BYPASS_AUTH=1 accepts anonymous calls. */
export async function requireUser(c: Context, next: Next) {
  const header = c.req.header("authorization") ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7) : "";
  if (token) {
    try {
      c.set("user", await verifyBearer(token));
      return next();
    } catch (err) {
      if (!env.devBypassAuth) return c.json({ error: "invalid token", detail: String(err) }, 401);
    }
  }
  if (env.devBypassAuth) {
    c.set("user", { id: "dev-local", dev: true } satisfies AuthedUser);
    return next();
  }
  return c.json({ error: "missing bearer token" }, 401);
}
