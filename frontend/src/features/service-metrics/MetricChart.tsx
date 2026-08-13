import { useEffect, useRef } from 'react'
import { LineChart } from 'echarts/charts'
import { AriaComponent, GridComponent, TooltipComponent } from 'echarts/components'
import { init, use as registerECharts } from 'echarts/core'
import { CanvasRenderer } from 'echarts/renderers'
import type { MetricSeries } from '../../api/metrics'
import { chartOption, formatMetricValue } from './metricPresentation'

registerECharts([LineChart, AriaComponent, GridComponent, TooltipComponent, CanvasRenderer])

export function MetricChart({ title, series }: { title: string; series: MetricSeries }) {
  const container = useRef<HTMLDivElement>(null)
  const latest = series.points.at(-1)

  useEffect(() => {
    const element = container.current
    if (element === null) return
    const chart = init(element)
    chart.setOption(chartOption(series))
    const observer = new ResizeObserver(() => chart.resize())
    observer.observe(element)
    return () => {
      observer.disconnect()
      chart.dispose()
    }
  }, [series])

  return (
    <article className="metric-chart-card">
      <div className="chart-heading">
        <h3>{title}</h3>
        {latest && <strong>{formatMetricValue(latest.value, series.unit)}</strong>}
      </div>
      <div ref={container} className="metric-chart" role="img" aria-label={`${title} time series`} />
    </article>
  )
}
