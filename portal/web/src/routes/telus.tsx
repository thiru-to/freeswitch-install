import { createFileRoute } from "@tanstack/react-router"

export const Route = createFileRoute("/telus")({
  component: RouteComponent,
})

function RouteComponent() {
  return <div>Hello "/telus"!</div>
}
