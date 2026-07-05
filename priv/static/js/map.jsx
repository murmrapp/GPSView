// MapView — Leaflet-based map with colored polyline, cursor marker, click points

const { useEffect, useRef, useState } = React;

function MapView({
  points,
  hoveredIndex,
  onHoverIndex,
  onClickPoint,
  brushRange,
  colorBy,         // 'speed' | 'alt' | 'battery' | 'sats' | 'none'
  mapStyle,        // 'light' | 'dark' | 'sat'
  theme,           // 'light' | 'dark'
  renderMode,      // 'points' (default) | 'line'
}){
  const containerRef = useRef(null);
  const mapRef = useRef(null);
  const tileLayerRef = useRef(null);
  const segmentsLayerRef = useRef(null);
  const cursorMarkerRef = useRef(null);
  const startMarkerRef = useRef(null);
  const endMarkerRef = useRef(null);
  const popupRef = useRef(null);

  // init map
  useEffect(() => {
    if (!containerRef.current || mapRef.current) return;
    const map = L.map(containerRef.current, {
      zoomControl: false,
      attributionControl: true,
      preferCanvas: true,
    });
    L.control.zoom({ position: 'topright' }).addTo(map);
    mapRef.current = map;

    // suppress default attribution prefix
    map.attributionControl.setPrefix('');

    return () => {
      map.remove();
      mapRef.current = null;
    };
  }, []);

  // tiles
  useEffect(() => {
    const map = mapRef.current;
    if (!map) return;
    if (tileLayerRef.current) {
      map.removeLayer(tileLayerRef.current);
    }

    let url, attr;
    if (mapStyle === 'sat'){
      url = 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
      attr = 'Esri';
    } else if (mapStyle === 'dark' || (mapStyle === 'auto' && theme === 'dark')){
      url = 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png';
      attr = '© OpenStreetMap · CARTO';
    } else {
      url = 'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png';
      attr = '© OpenStreetMap · CARTO';
    }

    const layer = L.tileLayer(url, {
      attribution: attr,
      maxZoom: 19,
      subdomains: 'abcd',
    }).addTo(map);
    tileLayerRef.current = layer;
  }, [mapStyle, theme]);

  // fit bounds & start/end markers when points change
  useEffect(() => {
    const map = mapRef.current;
    if (!map || !points.length) return;

    const lls = points.map(p => [p.lat, p.lon]);
    const bounds = L.latLngBounds(lls);
    map.fitBounds(bounds, { padding: [40, 40], maxZoom: 13, animate: false });

    // start/end markers
    if (startMarkerRef.current) map.removeLayer(startMarkerRef.current);
    if (endMarkerRef.current) map.removeLayer(endMarkerRef.current);

    const startIcon = L.divIcon({
      className: '',
      html: '<div class="gps-start"></div>',
      iconSize: [14, 14], iconAnchor: [7, 7],
    });
    const endIcon = L.divIcon({
      className: '',
      html: '<div class="gps-end"></div>',
      iconSize: [14, 14], iconAnchor: [7, 7],
    });
    startMarkerRef.current = L.marker(lls[0], { icon: startIcon, interactive: false }).addTo(map);
    endMarkerRef.current = L.marker(lls[lls.length-1], { icon: endIcon, interactive: false }).addTo(map);
  }, [points]);

  // segments (color-by)
  useEffect(() => {
    const map = mapRef.current;
    if (!map || !points.length) return;

    if (segmentsLayerRef.current) map.removeLayer(segmentsLayerRef.current);

    const layer = L.layerGroup();

    let metricFn = null;
    let stops = null;
    if (colorBy && colorBy !== 'none'){
      stops = window.METRIC_RAMPS[colorBy];
      const field = ({ speed:'speed_kts', alt:'alt_m', battery:'battery_pct', sats:'satellites' })[colorBy];
      const vals = points.map(p => p[field]);
      const vMin = Math.min(...vals);
      const vMax = Math.max(...vals);
      const range = (vMax - vMin) || 1;
      metricFn = (p) => (p[field] - vMin) / range;
    }

    // draw segments — within brush = full opacity, outside = dim
    const inBrush = (i) => !brushRange || (i >= brushRange[0] && i <= brushRange[1]);

    const accent = getComputedStyle(document.documentElement).getPropertyValue('--accent').trim() || '#3aa0d6';
    const colored = colorBy && colorBy !== 'none';

    if (renderMode === 'points'){
      // One canvas-rendered circle marker per point. Holds up to ~100k points
      // smoothly because preferCanvas:true on the map turns these into bulk
      // canvas draws rather than SVG nodes.
      for (let i = 0; i < points.length; i++){
        const p = points[i];
        const color = colored ? window.rampColor(stops, metricFn(p)) : accent;
        const inB = inBrush(i);
        L.circleMarker([p.lat, p.lon], {
          radius: 2,
          color,
          fillColor: color,
          fillOpacity: inB ? 0.85 : 0.15,
          weight: 0,
          interactive: false,
        }).addTo(layer);
      }
    } else if (colored){
      // per-segment polylines so each segment can take its own color
      for (let i = 1; i < points.length; i++){
        const a = points[i-1], b = points[i];
        const v = (metricFn(a) + metricFn(b)) / 2;
        const color = window.rampColor(stops, v);
        const inB = inBrush(i-1) && inBrush(i);
        L.polyline([[a.lat, a.lon],[b.lat, b.lon]], {
          color, weight: 4, opacity: inB ? 0.95 : 0.18, lineCap: 'round',
        }).addTo(layer);
      }
    } else {
      // single line + brushed overlay
      L.polyline(points.map(p => [p.lat, p.lon]), {
        color: accent, weight: 3.5, opacity: brushRange ? 0.22 : 0.95, lineCap: 'round',
      }).addTo(layer);
      if (brushRange){
        const sub = points.slice(brushRange[0], brushRange[1]+1);
        L.polyline(sub.map(p => [p.lat, p.lon]), {
          color: accent, weight: 4, opacity: 1, lineCap: 'round',
        }).addTo(layer);
      }
    }

    // invisible interaction polyline (thicker, transparent) for hover/click
    const hit = L.polyline(points.map(p => [p.lat, p.lon]), {
      color: '#000', weight: 18, opacity: 0,
    });
    hit.on('mousemove', (e) => {
      // find nearest index
      let bestI = 0, bestD = Infinity;
      const lat = e.latlng.lat, lon = e.latlng.lng;
      for (let i = 0; i < points.length; i++){
        const d = (points[i].lat - lat)**2 + (points[i].lon - lon)**2;
        if (d < bestD){ bestD = d; bestI = i; }
      }
      onHoverIndex(bestI);
    });
    hit.on('mouseout', () => onHoverIndex(null));
    hit.on('click', (e) => {
      let bestI = 0, bestD = Infinity;
      const lat = e.latlng.lat, lon = e.latlng.lng;
      for (let i = 0; i < points.length; i++){
        const d = (points[i].lat - lat)**2 + (points[i].lon - lon)**2;
        if (d < bestD){ bestD = d; bestI = i; }
      }
      onClickPoint(bestI, e.latlng);
    });
    hit.addTo(layer);

    layer.addTo(map);
    segmentsLayerRef.current = layer;
  }, [points, colorBy, brushRange, renderMode]);

  // cursor marker tracking hovered index
  useEffect(() => {
    const map = mapRef.current;
    if (!map) return;
    if (cursorMarkerRef.current){
      map.removeLayer(cursorMarkerRef.current);
      cursorMarkerRef.current = null;
    }
    if (hoveredIndex == null || hoveredIndex < 0 || hoveredIndex >= points.length) return;
    const p = points[hoveredIndex];
    const icon = L.divIcon({
      className: '',
      html: '<div class="gps-cursor"></div>',
      iconSize: [14, 14], iconAnchor: [7, 7],
    });
    cursorMarkerRef.current = L.marker([p.lat, p.lon], { icon, interactive: false, zIndexOffset: 1000 }).addTo(map);
  }, [hoveredIndex, points]);

  // popup mgmt — open via parent state
  useEffect(() => {
    const map = mapRef.current;
    if (!map) return;
    return () => { if (popupRef.current) map.closePopup(popupRef.current); };
  }, []);

  // expose openPopup for parent
  MapView.openPopup = (idx) => {
    const map = mapRef.current;
    if (!map || idx == null) return;
    const p = points[idx];
    if (!p) return;
    const fmtTime = (t) => new Date(t).toUTCString().slice(0, 22).replace('GMT', 'UTC');
    const html = `
      <div class="popup">
        <div class="popup-head">${fmtTime(p.t)}</div>
        <div class="popup-row"><span class="k">LAT</span><span class="v">${p.lat.toFixed(5)}°</span></div>
        <div class="popup-row"><span class="k">LON</span><span class="v">${p.lon.toFixed(5)}°</span></div>
        <div class="popup-row"><span class="k">ALT</span><span class="v">${p.alt_m.toFixed(1)} m</span></div>
        <div class="popup-row"><span class="k">SPEED</span><span class="v">${p.speed_kts.toFixed(2)} kts</span></div>
        <div class="popup-row"><span class="k">COG</span><span class="v">${p.cog}°</span></div>
        <div class="popup-row"><span class="k">SATS</span><span class="v">${p.satellites} · HDOP ${p.hdop}</span></div>
        <div class="popup-row"><span class="k">BAT</span><span class="v">${p.battery_pct.toFixed(1)}% · ${p.battery_v.toFixed(3)}V</span></div>
        <div class="popup-row"><span class="k">MODE</span><span class="v">${p.mode || '—'}</span></div>
      </div>`;
    popupRef.current = L.popup({ closeButton: true, autoPan: true, maxWidth: 260 })
      .setLatLng([p.lat, p.lon])
      .setContent(html)
      .openOn(map);
  };

  return <div ref={containerRef} id="map"></div>;
}

window.MapView = MapView;
