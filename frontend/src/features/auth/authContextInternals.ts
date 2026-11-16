import { createContext } from 'react'
import type { GeordiPermission } from '../../api/auth'

export const authContext = createContext<ReadonlySet<GeordiPermission>>(new Set<GeordiPermission>())
