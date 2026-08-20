import { useEffect, useRef } from 'react'
import { GraphChart } from 'echarts/charts'
import { AriaComponent, TooltipComponent } from 'echarts/components'
import { init, use as registerECharts } from 'echarts/core'
import { CanvasRenderer } from 'echarts/renderers'
import type { ObservedDependency } from '../../api/serviceMap'
import type { ServiceIdentity } from '../../api/telemetryContext'
import { serviceMapGraphOption } from './serviceMapGraphPresentation'

registerECharts([GraphChart, AriaComponent, TooltipComponent, CanvasRenderer])

export function ServiceMapGraph({
  nodes,
  edges,
  nodeCount,
  edgeCount,
}: {
  nodes: readonly ServiceIdentity[]
  edges: readonly ObservedDependency[]
  nodeCount: number
  edgeCount: number
}) {
  const container = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const element = container.current
    if (element === null) return
    const chart = init(element)
    chart.setOption(serviceMapGraphOption(nodes, edges, nodeCount, edgeCount))
    const observer = new ResizeObserver(() => chart.resize())
    observer.observe(element)
    return () => {
      observer.disconnect()
      chart.dispose()
    }
  }, [edgeCount, edges, nodeCount, nodes])

  return (
    <div
      ref={container}
      className="service-map-graph"
      role="img"
      aria-label={`Observed dependency graph with ${nodeCount} services and ${edgeCount} dependencies`}
    />
  )
}
