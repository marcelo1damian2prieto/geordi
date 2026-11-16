import type { ReactNode } from 'react'
import { NavLink } from 'react-router-dom'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import type { CurrentIdentity } from '../api/auth'
import { logout } from '../api/auth'
import { advanceAuthenticationGeneration } from '../api/client'

export function AppShell({ children, identity, onSignedOut }: {
  children: ReactNode
  identity: CurrentIdentity
  onSignedOut: () => void
}) {
  const queryClient = useQueryClient()
  const logoutMutation = useMutation({
    mutationFn: () => logout(),
    onSuccess: async () => {
      advanceAuthenticationGeneration()
      await queryClient.cancelQueries()
      queryClient.clear()
      onSignedOut()
    },
  })
  return (
    <>
      <div className="app-user" aria-label="Signed-in user">
        <span>{identity.displayName ?? identity.subject}</span>
        <button type="button" onClick={() => logoutMutation.mutate()} disabled={logoutMutation.isPending}>Sign out</button>
        {logoutMutation.isError && <span role="alert">Sign out failed. Retry.</span>}
      </div>
      <nav className="app-nav" aria-label="Primary navigation">
        <NavLink to="/" end>Platform</NavLink>
        <NavLink to="/metrics">Service metrics</NavLink>
        <NavLink to="/traces">Traces</NavLink>
        <NavLink to="/logs">Logs</NavLink>
        <NavLink to="/investigate">Investigate</NavLink>
        <NavLink to="/service-map">Service map</NavLink>
        <NavLink to="/slos">SLOs</NavLink>
        <NavLink to="/alert-evaluations">Alert lifecycle</NavLink>
        <NavLink to="/alert-history">Alert history</NavLink>
      </nav>
      {children}
    </>
  )
}
