import { createFileRoute } from "@tanstack/react-router"

export const Route = createFileRoute("/aingaran")({
  component: RouteComponent,
})

function RouteComponent() {
  return <div>Hello "/aingaran"!</div>
}
