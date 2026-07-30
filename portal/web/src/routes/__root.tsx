/**
 * Root route.
 *
 * Deliberately bare. Everything that identifies this as a PBX console — the shell, the
 * navigation, the page names — lives in `_app.tsx` behind the session guard, so an anonymous
 * visitor who reaches the bundle sees a login form and nothing else.
 */
import { createRootRoute, Outlet } from "@tanstack/react-router";

export const Route = createRootRoute({ component: Outlet });
