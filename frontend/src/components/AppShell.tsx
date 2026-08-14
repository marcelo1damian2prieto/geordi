import type { ReactNode } from 'react'
import { NavLink } from 'react-router-dom'

export function AppShell({ children }: { children: ReactNode }) {
  return (
    <>
      <nav className="app-nav" aria-label="Primary navigation">
        <NavLink to="/" end>Platform</NavLink>
        <NavLink to="/metrics">Service metrics</NavLink>
        <NavLink to="/traces">Traces</NavLink>
        <NavLink to="/logs">Logs</NavLink>
        <NavLink to="/investigate">Investigate</NavLink>
      </nav>
      {children}
    </>
  )
}
