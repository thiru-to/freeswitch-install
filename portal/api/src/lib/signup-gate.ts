/**
 * Registration gate.
 *
 * There is no self-service signup on this platform. A portal account can administer telephony
 * for a tenant, and a compromise means toll fraud billed to that tenant - so accounts are
 * created by an operator (`src/cli/create-user.ts`), never by whoever finds the hostname.
 *
 * Implemented as a flag rather than better-auth's `emailAndPassword.disableSignUp`, because that
 * option is enforced inside the `/sign-up/email` handler - which is the same code path
 * `auth.api.signUpEmail()` takes when called server-side. Setting it would block the operator
 * CLI along with the public, leaving no way to create the first account at all.
 *
 * Lives in its own module so `auth.ts` and the CLI can both reach it without importing each
 * other.
 */

let allowed = false;

/**
 * Permits exactly one signup, from in-process code.
 *
 * Single-use on purpose: a CLI that forgets to reset the flag cannot leave the running process
 * accepting public registrations. Nothing in the HTTP path can call this - it is not reachable
 * from a route handler.
 */
export function allowOneSignup(): void {
  allowed = true;
}

/** Consumes the permission. Returns true at most once per `allowOneSignup()`. */
export function consumeSignupPermission(): boolean {
  if (!allowed) return false;
  allowed = false;
  return true;
}
