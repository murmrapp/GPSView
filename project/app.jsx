// GPSView main app

const { useState, useEffect, useRef, useMemo, useCallback } = React;

const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "theme": "light",
  "mapStyle": "auto",
  "colorBy": "speed",
  "units": "metric"
}/*EDITMODE-END*/;

function App(){
  // ---- tweaks ----
  const [tweaks, setTweak] = window.useTweaks(TWEAK_DEFAULTS);
  const theme = tweaks.theme || 'light';
  const mapStyle = tweaks.mapStyle || 'auto';

  // apply theme
  useEffect(() => {
    document.documentElement.setAttribute('data-theme', theme);
  }, [theme]);

  // ---- data ----
  const [seed, setSeed] = useState(7);
  const [points, setPoints] = useState(() => window.GPSData.generateTrack(7));
  const [syncing, setSyncing] = useState(false);
  const [syncMsg, setSyncMsg] = useState(null);
  const [lastSync, setLastSync] = useState(new Date());

  const summary = useMemo(() => window.GPSData.summary(points), [points]);

  // ---- selection state ----
  const [hoveredIndex, setHoveredIndex] = useState(null);
  const [clickedIndex, setClickedIndex] = useState(null);
  const [brushRange, setBrushRange] = useState(null);
  const [activeTab, setActiveTab] = useState('alt'); // alt | speed | battery | sats
  const [colorBy, setColorBy] = useState('speed');

  // playback
  const [playing, setPlaying] = useState(false);
  const [playIdx, setPlayIdx] = useState(0);
  const [playSpeed, setPlaySpeed] = useState(4);
  const playRef = useRef(null);

  useEffect(() => {
    if (!playing) return;
    const tick = () => {
      setPlayIdx(i => {
        const next = i + 1;
        if (next >= points.length){ setPlaying(false); return 0; }
        return next;
      });
    };
    const interval = Math.max(16, 80 / playSpeed);
    playRef.current = setInterval(tick, interval);
    return () => clearInterval(playRef.current);
  }, [playing, playSpeed, points.length]);

  // While playing, sync hovered to playback head
  useEffect(() => {
    if (playing) setHoveredIndex(playIdx);
  }, [playing, playIdx]);

  // ---- handlers ----
  const handleSync = async () => {
    if (syncing) return;
    setSyncing(true);
    setSyncMsg('Connecting to tracker…');
    await new Promise(r => setTimeout(r, 600));
    setSyncMsg('Pulling track points…');
    await new Promise(r => setTimeout(r, 800));
    const newSeed = seed + 1;
    setSeed(newSeed);
    setPoints(window.GPSData.generateTrack(newSeed));
    setBrushRange(null);
    setClickedIndex(null);
    setHoveredIndex(null);
    setPlayIdx(0);
    setPlaying(false);
    setLastSync(new Date());
    setSyncMsg(`Synced · ${new Date().toUTCString().slice(17,22)}`);
    await new Promise(r => setTimeout(r, 400));
    setSyncing(false);
    setTimeout(() => setSyncMsg(null), 2400);
  };

  const handleClickPoint = (idx, latlng) => {
    setClickedIndex(idx);
    setHoveredIndex(idx);
    if (window.MapView && window.MapView.openPopup) window.MapView.openPopup(idx);
  };

  // chart config
  const tabs = [
    { id: 'alt',     label: 'Altitude',  field: 'alt_m',       unit: 'm',   decimals: 1, color: 'oklch(0.65 0.14 145)' },
    { id: 'speed',   label: 'Speed',     field: 'speed_kts',   unit: 'kts', decimals: 2, color: 'oklch(0.65 0.16 30)' },
    { id: 'battery', label: 'Battery',   field: 'battery_pct', unit: '%',   decimals: 1, color: 'oklch(0.65 0.14 75)' },
    { id: 'sats',    label: 'Satellites',field: 'satellites',  unit: '',    decimals: 0, color: 'oklch(0.65 0.14 220)' },
  ];
  const tabCfg = tabs.find(t => t.id === activeTab);

  const fmtDist = (km) => tweaks.units === 'imperial' ? `${(km*0.621371).toFixed(2)} mi` : `${km.toFixed(2)} km`;
  const fmtSpeed = (kts) => tweaks.units === 'imperial' ? `${(kts*1.15078).toFixed(1)} mph` : `${kts.toFixed(1)} kts`;
  const fmtAlt = (m) => tweaks.units === 'imperial' ? `${(m*3.28084).toFixed(0)} ft` : `${m.toFixed(0)} m`;
  const fmtDur = (min) => {
    const h = Math.floor(min/60);
    const m = Math.round(min % 60);
    return h > 0 ? `${h}h ${m.toString().padStart(2,'0')}m` : `${m}m`;
  };

  // playback timeline scrubber
  const [scrubbing, setScrubbing] = useState(false);
  const tlRef = useRef(null);
  const scrubAt = (e) => {
    if (!tlRef.current) return;
    const r = tlRef.current.getBoundingClientRect();
    const pct = Math.max(0, Math.min(1, (e.clientX - r.left) / r.width));
    setPlayIdx(Math.round(pct * (points.length - 1)));
  };
  useEffect(() => {
    if (!scrubbing) return;
    const move = (e) => scrubAt(e);
    const up = () => setScrubbing(false);
    window.addEventListener('mousemove', move);
    window.addEventListener('mouseup', up);
    return () => {
      window.removeEventListener('mousemove', move);
      window.removeEventListener('mouseup', up);
    };
  }, [scrubbing]);

  const fmtClock = (t) => new Date(t).toUTCString().slice(17, 22);
  const fmtFullTime = (t) => new Date(t).toUTCString().slice(0, 22).replace('GMT','UTC');

  const currentT = points[playing || scrubbing ? playIdx : (hoveredIndex ?? points.length-1)]?.t ?? points[points.length-1].t;

  // legend
  const legendStops = window.METRIC_RAMPS[colorBy];
  const legendField = ({ speed:'speed_kts', alt:'alt_m', battery:'battery_pct', sats:'satellites' })[colorBy];
  const legendVals = legendField ? points.map(p => p[legendField]) : null;
  const legendMin = legendVals ? Math.min(...legendVals) : 0;
  const legendMax = legendVals ? Math.max(...legendVals) : 0;
  const legendUnit = ({ speed:'kts', alt:'m', battery:'%', sats:'' })[colorBy];
  const legendDec = ({ speed:1, alt:0, battery:0, sats:0 })[colorBy];

  return (
    <div className="app">
      {/* ===== HEADER ===== */}
      <header className="header">
        <div className="brand">
          <div className="brand-mark">G</div>
          <div>GPSView</div>
        </div>
        <div className="brand-divider"></div>
        <div className="track-meta">
          <div className="track-name">Track #A-{(seed).toString().padStart(4,'0')} · Moorea Loop</div>
          <div className="track-tag live">LIVE</div>
          <div className="track-tag mono">tracker-7C2A</div>
          <div className="track-tag mono" style={{ color: 'var(--text-faint)' }}>
            synced {fmtClock(lastSync.getTime())}
          </div>
        </div>
        <div className="header-actions">
          <button className="btn btn-icon" title="Toggle theme"
                  onClick={() => setTweak('theme', theme === 'light' ? 'dark' : 'light')}>
            {theme === 'light' ? (
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/>
              </svg>
            ) : (
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <circle cx="12" cy="12" r="4"/>
                <path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M4.93 19.07l1.41-1.41M17.66 6.34l1.41-1.41"/>
              </svg>
            )}
          </button>
          <button className={`btn btn-primary btn-sync`} onClick={handleSync} disabled={syncing}>
            <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4"
                 className={syncing ? 'spin' : ''}>
              <path d="M23 4v6h-6"/>
              <path d="M1 20v-6h6"/>
              <path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10"/>
              <path d="M20.49 15A9 9 0 0 1 5.64 18.36L1 14"/>
            </svg>
            {syncing ? 'Syncing…' : 'Sync from tracker'}
          </button>
        </div>
      </header>

      {/* ===== MAIN ===== */}
      <div className="main">
        {/* ===== MAP ===== */}
        <div className="map-wrap">
          <window.MapView
            points={points}
            hoveredIndex={hoveredIndex}
            onHoverIndex={setHoveredIndex}
            onClickPoint={handleClickPoint}
            brushRange={brushRange}
            colorBy={colorBy}
            mapStyle={mapStyle}
            theme={theme}
          />

          {/* overlays */}
          <div className="map-overlay map-controls">
            <div className="control-card">
              <div className="control-label">Color by</div>
              <div className="seg">
                {[
                  ['none','None'],
                  ['speed','Speed'],
                  ['alt','Alt'],
                  ['battery','Bat'],
                  ['sats','Sats'],
                ].map(([k,l]) => (
                  <button key={k} className={colorBy === k ? 'active' : ''}
                          onClick={() => setColorBy(k)}>{l}</button>
                ))}
              </div>
            </div>
            <div className="control-card">
              <div className="control-label">Map</div>
              <div className="seg">
                {[['auto','Auto'],['light','Light'],['dark','Dark'],['sat','Satellite']].map(([k,l]) => (
                  <button key={k} className={mapStyle === k ? 'active' : ''}
                          onClick={() => setTweak('mapStyle', k)}>{l}</button>
                ))}
              </div>
            </div>
          </div>

          {colorBy !== 'none' && (
            <div className="map-overlay legend">
              <div className="legend-title">{
                ({speed:'Speed (kts)', alt:'Altitude (m)', battery:'Battery (%)', sats:'Satellites'})[colorBy]
              }</div>
              <div className="legend-bar" style={{
                background: `linear-gradient(to right, ${legendStops[0]}, ${legendStops[1]}, ${legendStops[2]})`
              }}></div>
              <div className="legend-ticks">
                <span>{legendMin.toFixed(legendDec)}</span>
                <span>{((legendMin+legendMax)/2).toFixed(legendDec)}</span>
                <span>{legendMax.toFixed(legendDec)} {legendUnit}</span>
              </div>
            </div>
          )}

          <div className="map-overlay scale-tag">
            {points.length} pts · fix {summary?.satAvg.toFixed(1)} sats avg
          </div>
        </div>

        {/* ===== RIGHT PANEL ===== */}
        <aside className="right-panel">
          <div className="stats">
            <div className="stat">
              <div className="stat-label">Distance</div>
              <div className="stat-value mono">
                {tweaks.units === 'imperial'
                  ? (summary.distanceKm*0.621371).toFixed(2)
                  : summary.distanceKm.toFixed(2)}
                <span className="stat-unit">{tweaks.units === 'imperial' ? 'mi' : 'km'}</span>
              </div>
            </div>
            <div className="stat">
              <div className="stat-label">Duration</div>
              <div className="stat-value mono">{fmtDur(summary.durationMin)}</div>
            </div>
            <div className="stat">
              <div className="stat-label">Max speed</div>
              <div className="stat-value mono">
                {tweaks.units === 'imperial'
                  ? (summary.maxSpeedKts*1.15078).toFixed(1)
                  : summary.maxSpeedKts.toFixed(1)}
                <span className="stat-unit">{tweaks.units === 'imperial' ? 'mph' : 'kts'}</span>
              </div>
            </div>
            <div className="stat">
              <div className="stat-label">Ascent</div>
              <div className="stat-value mono">
                {tweaks.units === 'imperial' ? (summary.ascentM*3.28084).toFixed(0) : summary.ascentM.toFixed(0)}
                <span className="stat-unit">{tweaks.units === 'imperial' ? 'ft' : 'm'}</span>
              </div>
            </div>
          </div>

          <div className="tabs-wrap">
            <div className="tabs">
              {tabs.map(t => (
                <button key={t.id}
                        className={`tab ${activeTab === t.id ? 'active' : ''}`}
                        onClick={() => setActiveTab(t.id)}>
                  <span className="tab-dot" style={{ background: t.color }}></span>
                  {t.label}
                </button>
              ))}
            </div>

            <div className="chart-area">
              <div className="chart-header">
                <div className="chart-title">
                  {tabCfg.label} over time
                  {brushRange && (
                    <span style={{ marginLeft: 10, color: 'var(--accent)' }}>
                      · brushed {brushRange[1] - brushRange[0] + 1} pts
                      <span style={{ marginLeft: 8, cursor: 'pointer', textDecoration: 'underline' }}
                            onClick={() => setBrushRange(null)}>clear</span>
                    </span>
                  )}
                </div>
                <div className="chart-readout">
                  <span className="big">
                    {(() => {
                      const idx = hoveredIndex ?? points.length - 1;
                      const v = points[idx][tabCfg.field];
                      return v.toFixed(tabCfg.decimals);
                    })()}
                  </span>
                  <span className="unit">{tabCfg.unit}</span>
                </div>
              </div>

              <window.MetricChart
                points={points}
                field={tabCfg.field}
                unit={tabCfg.unit}
                color={tabCfg.color}
                decimals={tabCfg.decimals}
                hoveredIndex={hoveredIndex}
                onHoverIndex={setHoveredIndex}
                brushRange={brushRange}
                onBrushRange={setBrushRange}
              />

              <div style={{
                padding: '0 14px 10px',
                fontSize: 10, color: 'var(--text-faint)',
                fontFamily: 'JetBrains Mono, monospace',
                letterSpacing: '0.04em',
              }}>
                hover to scrub · shift+drag to brush a time range · click map points for details
              </div>
            </div>
          </div>

          {/* PLAYBACK */}
          <div className="playback">
            <button className={`play-btn ${playing ? 'playing' : ''}`}
                    onClick={() => {
                      if (playIdx >= points.length - 1) setPlayIdx(0);
                      setPlaying(p => !p);
                    }}>
              {playing ? (
                <svg width="11" height="11" viewBox="0 0 24 24" fill="currentColor">
                  <rect x="6" y="5" width="4" height="14"/>
                  <rect x="14" y="5" width="4" height="14"/>
                </svg>
              ) : (
                <svg width="11" height="11" viewBox="0 0 24 24" fill="currentColor">
                  <path d="M7 5v14l12-7z"/>
                </svg>
              )}
            </button>

            <div className="timeline" ref={tlRef}
                 onMouseDown={(e) => { setScrubbing(true); scrubAt(e); }}>
              <div className="timeline-track">
                <div className="timeline-fill" style={{
                  width: `${(playIdx / (points.length-1)) * 100}%`,
                }}></div>
              </div>
              <div className="timeline-thumb" style={{
                left: `${(playIdx / (points.length-1)) * 100}%`,
              }}></div>
            </div>

            <button className="speed-toggle"
                    onClick={() => setPlaySpeed(s => s === 1 ? 2 : s === 2 ? 4 : s === 4 ? 8 : 1)}>
              {playSpeed}×
            </button>

            <div className="timeline-readout">
              {fmtClock(points[playIdx].t)} <span style={{ color: 'var(--text-faint)' }}>UTC</span>
            </div>
          </div>
        </aside>
      </div>

      {/* TWEAKS */}
      <window.TweaksPanel>
        <window.TweakSection label="Appearance">
          <window.TweakRadio label="Theme" value={theme}
                             options={[{value:'light',label:'Light'},{value:'dark',label:'Dark'}]}
                             onChange={v => setTweak('theme', v)} />
          <window.TweakSelect label="Map style" value={mapStyle}
                              options={[
                                {value:'auto',label:'Auto (match theme)'},
                                {value:'light',label:'Light'},
                                {value:'dark',label:'Dark'},
                                {value:'sat',label:'Satellite'},
                              ]}
                              onChange={v => setTweak('mapStyle', v)} />
        </window.TweakSection>
        <window.TweakSection label="Display">
          <window.TweakRadio label="Units" value={tweaks.units || 'metric'}
                             options={[{value:'metric',label:'Metric'},{value:'imperial',label:'Imperial'}]}
                             onChange={v => setTweak('units', v)} />
          <window.TweakSelect label="Color track by" value={colorBy}
                              options={[
                                {value:'none',label:'None'},
                                {value:'speed',label:'Speed'},
                                {value:'alt',label:'Altitude'},
                                {value:'battery',label:'Battery'},
                                {value:'sats',label:'Satellites'},
                              ]}
                              onChange={v => setColorBy(v)} />
        </window.TweakSection>
      </window.TweaksPanel>

      {syncMsg && (
        <div className="toast">
          {syncing && (
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor"
                 strokeWidth="2.4" className="spin">
              <path d="M23 4v6h-6"/><path d="M1 20v-6h6"/>
              <path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10"/>
              <path d="M20.49 15A9 9 0 0 1 5.64 18.36L1 14"/>
            </svg>
          )}
          {syncMsg}
        </div>
      )}
    </div>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<App/>);
