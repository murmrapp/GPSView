// Chart component — line chart with hover, brush, cursor
// Renders SVG; uses container size via ResizeObserver

const { useState, useEffect, useRef, useMemo, useCallback } = React;

// metric color ramps (oklch) — for color-by track and chart strokes
const METRIC_RAMPS = {
  speed:   ['oklch(0.78 0.05 240)', 'oklch(0.7 0.13 220)', 'oklch(0.62 0.18 30)'],
  alt:     ['oklch(0.78 0.06 150)', 'oklch(0.7 0.14 90)',  'oklch(0.55 0.16 25)'],
  battery: ['oklch(0.62 0.2 25)',   'oklch(0.75 0.14 75)', 'oklch(0.7 0.14 150)'],
  sats:    ['oklch(0.62 0.2 25)',   'oklch(0.75 0.14 75)', 'oklch(0.65 0.14 220)'],
};

// 3-stop ramp interpolator → returns css color string. v in [0,1]
function rampColor(stops, v){
  v = Math.max(0, Math.min(1, v));
  if (v < 0.5){
    const t = v / 0.5;
    return mixOklch(stops[0], stops[1], t);
  }
  const t = (v - 0.5) / 0.5;
  return mixOklch(stops[1], stops[2], t);
}

// Crude oklch mix via CSS-style string parse (we keep stops as strings, mix by interpolation in lightness/chroma/hue space)
function parseOklch(s){
  const m = s.match(/oklch\(([\d.]+)\s+([\d.]+)\s+([\d.-]+)\)/);
  if (!m) return [0.5, 0, 0];
  return [parseFloat(m[1]), parseFloat(m[2]), parseFloat(m[3])];
}
function mixOklch(a, b, t){
  const [l1,c1,h1] = parseOklch(a);
  const [l2,c2,h2] = parseOklch(b);
  // shortest path on hue
  let dh = h2 - h1;
  if (dh > 180) dh -= 360;
  if (dh < -180) dh += 360;
  const L = l1 + (l2-l1)*t;
  const C = c1 + (c2-c1)*t;
  const H = h1 + dh * t;
  return `oklch(${L.toFixed(3)} ${C.toFixed(3)} ${H.toFixed(2)})`;
}

window.METRIC_RAMPS = METRIC_RAMPS;
window.rampColor = rampColor;

// ----- the Chart component -----
function MetricChart({
  points,
  field,
  unit,
  color,
  decimals = 1,
  hoveredIndex,
  onHoverIndex,
  brushRange,            // [startIdx, endIdx] or null
  onBrushRange,          // (range)
}){
  const wrapRef = useRef(null);
  const [size, setSize] = useState({ w: 600, h: 280 });
  const svgRef = useRef(null);
  const [dragging, setDragging] = useState(null); // 'start' | 'end' | 'new' | 'move' | null
  const [dragStart, setDragStart] = useState(null);

  useEffect(() => {
    if (!wrapRef.current) return;
    const ro = new ResizeObserver(entries => {
      for (const e of entries){
        const { width, height } = e.contentRect;
        setSize({ w: Math.max(200, width), h: Math.max(160, height) });
      }
    });
    ro.observe(wrapRef.current);
    return () => ro.disconnect();
  }, []);

  const padding = { top: 14, right: 12, bottom: 22, left: 40 };
  const innerW = size.w - padding.left - padding.right;
  const innerH = size.h - padding.top - padding.bottom;

  const scales = useMemo(() => {
    if (!points.length) return null;
    const vals = points.map(p => p[field]);
    let vMin = Math.min(...vals);
    let vMax = Math.max(...vals);
    const pad = (vMax - vMin) * 0.08 || 1;
    vMin = field === 'satellites' ? Math.max(0, Math.floor(vMin - 1)) : vMin - pad;
    vMax = field === 'satellites' ? Math.ceil(vMax + 1) : vMax + pad;
    if (field === 'battery_pct') { vMin = Math.max(0, Math.floor(vMin/10)*10); vMax = 100; }
    const tMin = points[0].t, tMax = points[points.length-1].t;

    return {
      x: t => padding.left + ((t - tMin) / (tMax - tMin)) * innerW,
      y: v => padding.top + (1 - (v - vMin) / (vMax - vMin)) * innerH,
      xInv: px => tMin + ((px - padding.left) / innerW) * (tMax - tMin),
      vMin, vMax, tMin, tMax,
    };
  }, [points, field, innerW, innerH, padding.left, padding.top]);

  const path = useMemo(() => {
    if (!scales) return '';
    let d = '';
    for (let i = 0; i < points.length; i++){
      const p = points[i];
      const x = scales.x(p.t);
      const y = scales.y(p[field]);
      d += (i === 0 ? 'M' : 'L') + x.toFixed(1) + ',' + y.toFixed(1);
    }
    return d;
  }, [points, scales, field]);

  const areaPath = useMemo(() => {
    if (!scales) return '';
    const baseY = scales.y(scales.vMin);
    let d = '';
    for (let i = 0; i < points.length; i++){
      const x = scales.x(points[i].t);
      const y = scales.y(points[i][field]);
      d += (i === 0 ? 'M' : 'L') + x.toFixed(1) + ',' + y.toFixed(1);
    }
    d += ` L${scales.x(points[points.length-1].t).toFixed(1)},${baseY.toFixed(1)}`;
    d += ` L${scales.x(points[0].t).toFixed(1)},${baseY.toFixed(1)} Z`;
    return d;
  }, [points, scales, field]);

  // y-axis ticks
  const yTicks = useMemo(() => {
    if (!scales) return [];
    const n = 4;
    const out = [];
    for (let i = 0; i <= n; i++){
      const v = scales.vMin + (scales.vMax - scales.vMin) * (i / n);
      out.push(v);
    }
    return out;
  }, [scales]);

  const xTicks = useMemo(() => {
    if (!scales) return [];
    const n = 5;
    const out = [];
    for (let i = 0; i <= n; i++){
      const t = scales.tMin + (scales.tMax - scales.tMin) * (i / n);
      out.push(t);
    }
    return out;
  }, [scales]);

  // event coords → index
  const pxToIndex = useCallback((px) => {
    if (!scales) return -1;
    const t = scales.xInv(px);
    // binary search
    let lo = 0, hi = points.length - 1;
    while (lo < hi){
      const mid = (lo + hi) >> 1;
      if (points[mid].t < t) lo = mid + 1; else hi = mid;
    }
    return lo;
  }, [scales, points]);

  const handleMove = (e) => {
    if (!svgRef.current || !scales) return;
    const rect = svgRef.current.getBoundingClientRect();
    const px = (e.clientX - rect.left) * (size.w / rect.width);

    if (dragging === 'new' && dragStart != null){
      const idx = pxToIndex(px);
      const a = Math.min(dragStart, idx);
      const b = Math.max(dragStart, idx);
      if (b - a > 2) onBrushRange([a, b]);
    } else if (dragging === 'start' && brushRange){
      let idx = pxToIndex(px);
      idx = Math.min(idx, brushRange[1] - 2);
      onBrushRange([Math.max(0, idx), brushRange[1]]);
    } else if (dragging === 'end' && brushRange){
      let idx = pxToIndex(px);
      idx = Math.max(idx, brushRange[0] + 2);
      onBrushRange([brushRange[0], Math.min(points.length-1, idx)]);
    } else {
      const idx = pxToIndex(px);
      onHoverIndex(idx);
    }
  };

  const handleDown = (e) => {
    if (!svgRef.current) return;
    const rect = svgRef.current.getBoundingClientRect();
    const px = (e.clientX - rect.left) * (size.w / rect.width);
    const idx = pxToIndex(px);

    // shift+drag → start brush
    if (e.shiftKey || e.altKey){
      setDragging('new');
      setDragStart(idx);
      onBrushRange([idx, idx]);
    } else {
      // tap to set hover (clicked point detail handled by parent)
      onHoverIndex(idx);
    }
  };

  const handleUp = () => {
    if (dragging === 'new' && brushRange && brushRange[1] - brushRange[0] < 3){
      onBrushRange(null);
    }
    setDragging(null);
    setDragStart(null);
  };

  useEffect(() => {
    const up = () => handleUp();
    window.addEventListener('mouseup', up);
    return () => window.removeEventListener('mouseup', up);
  });

  const formatVal = (v) => v == null ? '—' : v.toFixed(decimals);
  const formatTime = (t) => {
    const d = new Date(t);
    return d.toUTCString().slice(17, 22);
  };

  if (!points.length || !scales) return <div ref={wrapRef} className="chart-svg-wrap"></div>;

  const hovered = hoveredIndex != null && hoveredIndex >= 0 && hoveredIndex < points.length
    ? points[hoveredIndex] : null;
  const last = points[points.length - 1];
  const readVal = hovered ? hovered[field] : last[field];

  return (
    <div ref={wrapRef} className="chart-svg-wrap">
      <svg
        ref={svgRef}
        className="chart-svg"
        viewBox={`0 0 ${size.w} ${size.h}`}
        preserveAspectRatio="none"
        onMouseMove={handleMove}
        onMouseDown={handleDown}
        onMouseLeave={() => onHoverIndex(null)}
        style={{ cursor: dragging ? 'ew-resize' : 'crosshair' }}
      >
        {/* grid */}
        <g className="chart-grid">
          {yTicks.map((v, i) => (
            <line key={i} x1={padding.left} x2={size.w - padding.right}
                  y1={scales.y(v)} y2={scales.y(v)} />
          ))}
        </g>

        {/* area fill */}
        <path d={areaPath} fill={color} className="chart-area-fill" />

        {/* main line */}
        <path d={path} stroke={color} className="chart-line" />

        {/* y axis labels */}
        <g className="chart-axis">
          {yTicks.map((v, i) => (
            <text key={i} x={padding.left - 6} y={scales.y(v) + 3} textAnchor="end">
              {Math.abs(v) >= 100 ? v.toFixed(0) : v.toFixed(field === 'satellites' ? 0 : 1)}
            </text>
          ))}
        </g>
        {/* x axis labels */}
        <g className="chart-axis">
          <line x1={padding.left} x2={size.w - padding.right}
                y1={size.h - padding.bottom} y2={size.h - padding.bottom} />
          {xTicks.map((t, i) => (
            <text key={i} x={scales.x(t)} y={size.h - padding.bottom + 14}
                  textAnchor={i === 0 ? 'start' : i === xTicks.length-1 ? 'end' : 'middle'}>
              {formatTime(t)}
            </text>
          ))}
        </g>

        {/* brush */}
        {brushRange && (
          <g>
            <rect
              className="chart-brush"
              x={scales.x(points[brushRange[0]].t)}
              y={padding.top}
              width={Math.max(1, scales.x(points[brushRange[1]].t) - scales.x(points[brushRange[0]].t))}
              height={innerH}
            />
            <rect
              className="brush-handle"
              x={scales.x(points[brushRange[0]].t) - 3}
              y={padding.top}
              width={6} height={innerH}
              fillOpacity={0.6}
              onMouseDown={(e) => { e.stopPropagation(); setDragging('start'); }}
            />
            <rect
              className="brush-handle"
              x={scales.x(points[brushRange[1]].t) - 3}
              y={padding.top}
              width={6} height={innerH}
              fillOpacity={0.6}
              onMouseDown={(e) => { e.stopPropagation(); setDragging('end'); }}
            />
          </g>
        )}

        {/* hover cursor */}
        {hovered && (
          <g>
            <line className="chart-cursor-line"
                  x1={scales.x(hovered.t)} x2={scales.x(hovered.t)}
                  y1={padding.top} y2={size.h - padding.bottom} />
            <circle className="chart-cursor-dot"
                    cx={scales.x(hovered.t)} cy={scales.y(hovered[field])} r={4} />
          </g>
        )}
      </svg>

      <div style={{
        position: 'absolute', top: 8, right: 18,
        fontFamily: 'JetBrains Mono, monospace', fontSize: 10,
        color: 'var(--text-faint)', letterSpacing: '0.05em',
      }}>
        {hovered ? formatTime(hovered.t) : formatTime(last.t)}
      </div>
    </div>
  );
}

window.MetricChart = MetricChart;
