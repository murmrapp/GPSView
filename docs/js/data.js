// Realistic mock GPS track data — multi-modal session
// Schema matches the user's CSV: datetime, lat, lon, alt_m, speed_kts, cog,
// satellites, hdop, battery_pct, battery_v, charge_rate, rtc_bat_low, fix, boot

(function(global){
  // ---- helper: small deterministic pseudo-random so the demo is stable ----
  function mulberry32(seed){
    return function(){
      seed |= 0; seed = seed + 0x6D2B79F5 | 0;
      let t = Math.imul(seed ^ seed >>> 15, 1 | seed);
      t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
      return ((t ^ t >>> 14) >>> 0) / 4294967296;
    };
  }

  // Generate a multi-leg track simulating a tracker's day:
  // 1) walking → 2) driving → 3) sailing → 4) flying segment (bush plane)
  // Centered around Moorea/Tahiti region (matches one row of the user's sample)
  function generateTrack(seed = 7){
    const rand = mulberry32(seed);
    const start = new Date('2026-03-26T07:42:00Z').getTime();

    // anchor near Moorea (-17.5, -149.84)
    let lat = -17.5125, lon = -149.8410;
    let alt = 5;          // meters
    let battery = 96.4;   // pct
    let voltage = 4.12;
    let bearing = 90;     // degrees
    let satellites = 11;
    let hdop = 0.7;

    const points = [];
    let t = start;

    // Each leg: { mode, durMin, sampleSec, speedKtsRange, altRange, turn, dischargeRate }
    const legs = [
      { mode: 'walk',  durMin: 28, sampleSec: 8,   sp:[2.2, 4.8],   altDelta:[-2, 4],   turn: 12, drain: 0.012 },
      { mode: 'drive', durMin: 22, sampleSec: 6,   sp:[18, 38],     altDelta:[-3, 8],   turn: 8,  drain: 0.018 },
      { mode: 'sail',  durMin: 65, sampleSec: 12,  sp:[4.2, 7.6],   altDelta:[-0.5, 0.8], turn: 5,drain: 0.022 },
      { mode: 'fly',   durMin: 24, sampleSec: 5,   sp:[78, 112],    altDelta:[10, 60],  turn: 3,  drain: 0.040 },
      { mode: 'walk',  durMin: 18, sampleSec: 10,  sp:[1.6, 3.4],   altDelta:[-2, 3],   turn: 14, drain: 0.014 },
    ];

    for (const leg of legs){
      const samples = Math.floor((leg.durMin * 60) / leg.sampleSec);
      // Smoothly ramp into leg's altitude (especially flying)
      let baseAlt = alt;
      let targetBaseAlt = baseAlt;
      if (leg.mode === 'fly') targetBaseAlt = 1200 + rand() * 400;
      else if (leg.mode === 'sail') targetBaseAlt = 0.6;
      else if (leg.mode === 'drive') targetBaseAlt = 30 + rand() * 80;
      else targetBaseAlt = 8 + rand() * 25;

      for (let i = 0; i < samples; i++){
        const f = i / samples;
        // Ease-in-out alt transition
        const eased = f < 0.5 ? 2*f*f : 1 - Math.pow(-2*f + 2, 2)/2;
        const ramp = baseAlt + (targetBaseAlt - baseAlt) * eased;
        alt = Math.max(0, ramp + (rand() - 0.5) * (leg.mode === 'fly' ? 18 : 3));

        // Speed variation (knots)
        const [s0, s1] = leg.sp;
        let speedKts = s0 + (s1 - s0) * (0.4 + 0.6 * Math.sin(f * Math.PI * (1.5 + rand()*0.6)) * 0.5 + 0.5*rand());
        speedKts = Math.max(0, speedKts);

        // Bearing wobble
        bearing = (bearing + (rand() - 0.5) * leg.turn + 360) % 360;

        // Step in lat/lon: knots → m/s ≈ 0.514, sample → seconds
        const meters = speedKts * 0.5144 * leg.sampleSec;
        const dLat = (meters * Math.cos(bearing * Math.PI / 180)) / 111111;
        const dLon = (meters * Math.sin(bearing * Math.PI / 180)) / (111111 * Math.cos(lat * Math.PI / 180));
        lat += dLat;
        lon += dLon;

        // Battery slowly drains; flight drains faster (temp/transmit), some jitter
        battery = Math.max(2, battery - leg.drain * (0.85 + rand() * 0.3));
        voltage = 3.55 + (battery / 100) * 0.62 + (rand() - 0.5) * 0.01;

        // Sat/hdop — flying gets best fix, sail occasionally drops
        if (leg.mode === 'fly') { satellites = 11 + Math.round(rand()*2); hdop = 0.5 + rand()*0.3; }
        else if (leg.mode === 'sail') { satellites = 8 + Math.round(rand()*4) - (rand() < 0.05 ? 3 : 0); hdop = 0.7 + rand()*0.6; }
        else if (leg.mode === 'drive') { satellites = 7 + Math.round(rand()*3) - (rand() < 0.08 ? 2 : 0); hdop = 0.9 + rand()*0.7; }
        else { satellites = 9 + Math.round(rand()*3) - (rand() < 0.06 ? 2 : 0); hdop = 0.7 + rand()*0.8; }
        satellites = Math.max(3, Math.min(14, satellites));

        points.push({
          t,
          datetime: new Date(t).toISOString().slice(0, 19),
          lat: +lat.toFixed(6),
          lon: +lon.toFixed(6),
          alt_m: +alt.toFixed(1),
          speed_kts: +speedKts.toFixed(2),
          cog: Math.round(bearing),
          satellites,
          hdop: +hdop.toFixed(2),
          battery_pct: +battery.toFixed(1),
          battery_v: +voltage.toFixed(3),
          charge_rate: 0,
          rtc_bat_low: 0,
          fix: 1,
          boot: 826 + Math.floor(i / 200),
          mode: leg.mode,
        });

        t += leg.sampleSec * 1000;
      }
      baseAlt = targetBaseAlt;
    }

    return points;
  }

  // Compute total distance via haversine (km)
  function totalDistanceKm(pts){
    let d = 0;
    const R = 6371;
    for (let i = 1; i < pts.length; i++){
      const a = pts[i-1], b = pts[i];
      const dLat = (b.lat - a.lat) * Math.PI / 180;
      const dLon = (b.lon - a.lon) * Math.PI / 180;
      const lat1 = a.lat * Math.PI / 180, lat2 = b.lat * Math.PI / 180;
      const x = Math.sin(dLat/2)**2 + Math.cos(lat1)*Math.cos(lat2)*Math.sin(dLon/2)**2;
      d += 2 * R * Math.asin(Math.sqrt(x));
    }
    return d;
  }

  function durationMin(pts){
    if (pts.length < 2) return 0;
    return (pts[pts.length-1].t - pts[0].t) / 60000;
  }

  function summary(pts){
    if (!pts.length) return null;
    const speeds = pts.map(p => p.speed_kts);
    const alts = pts.map(p => p.alt_m);
    const totAsc = pts.reduce((s,p,i) => i ? s + Math.max(0, p.alt_m - pts[i-1].alt_m) : 0, 0);
    return {
      points: pts.length,
      distanceKm: totalDistanceKm(pts),
      durationMin: durationMin(pts),
      maxSpeedKts: Math.max(...speeds),
      avgSpeedKts: speeds.reduce((a,b)=>a+b,0) / speeds.length,
      maxAltM: Math.max(...alts),
      minAltM: Math.min(...alts),
      ascentM: totAsc,
      batStart: pts[0].battery_pct,
      batEnd: pts[pts.length-1].battery_pct,
      satAvg: pts.reduce((s,p)=>s+p.satellites,0) / pts.length,
      startT: pts[0].t,
      endT: pts[pts.length-1].t,
    };
  }

  // window.GPSDATA_STATIC is set by the static-exported index.html. When
  // set, fetches read pre-rendered JSON from /data/* (GitHub Pages /
  // S3 / etc.) instead of the live Phoenix API. Same JSON shape either way.
  const isStatic = () => typeof window !== 'undefined' && window.GPSDATA_STATIC === true;

  // Mirrors GET /api/devices. In static mode the URL is relative so it
  // works whether the export is served from the host root or a subpath
  // like <user>.github.io/<repo>/.
  async function fetchDevices(){
    const url = isStatic() ? 'data/devices.json' : '/api/devices';
    const resp = await fetch(url, { headers: { Accept: 'application/json' } });
    if (!resp.ok) throw new Error(`fetchDevices: ${resp.status} ${resp.statusText}`);
    return resp.json();
  }

  // Fetch real fixes from the Phoenix API or the static export. The server /
  // export has already LTTB-decimated if a target was specified. Coerces nulls
  // in numeric fields to 0 so the existing UI math (Math.max, chart axis
  // ranges, etc.) doesn't blow up on partial tracker exports.
  async function fetchTrack(deviceId, decimate = 0){
    // decimate=0 means "all points, full resolution" (server-side LTTB skipped)
    const url = isStatic()
      ? `data/${encodeURIComponent(deviceId)}.json`
      : `/api/fixes?device_id=${encodeURIComponent(deviceId)}&decimate=${decimate}`;
    const resp = await fetch(url, { headers: { Accept: 'application/json' } });
    if (!resp.ok){
      throw new Error(`fetchTrack ${deviceId}: ${resp.status} ${resp.statusText}`);
    }
    const body = await resp.json();
    const points = (body.points || []).map(p => ({
      t: p.t,
      datetime: new Date(p.t).toISOString().slice(0, 19),
      lat: p.lat,
      lon: p.lon,
      alt_m: p.alt_m ?? 0,
      speed_kts: p.speed_kts ?? 0,
      cog: p.cog ?? 0,
      satellites: p.satellites ?? 0,
      hdop: p.hdop ?? 0,
      battery_pct: p.battery_pct ?? 0,
      battery_v: p.battery_v ?? 0,
      charge_rate: p.charge_rate ?? 0,
      rtc_bat_low: 0,
      fix: p.fix ?? 1,
      boot: p.boot ?? 0,
    }));

    // Antimeridian unwrap: if consecutive lons jump by >180°, the tracker
    // crossed the date line. Without this, Leaflet draws the long way around
    // (e.g. Australia → Atlantic via Indian Ocean instead of via the Pacific).
    // Mirror of the same fix in gps_log_viewer.html.
    for (let i = 1; i < points.length; i++){
      const diff = points[i].lon - points[i - 1].lon;
      if (diff > 180) points[i].lon -= 360;
      else if (diff < -180) points[i].lon += 360;
    }

    return { points, device: { id: body.device_id, name: body.name }, summary: body.summary };
  }

  global.GPSData = {
    generateTrack,
    summary,
    totalDistanceKm,
    fetchTrack,
    fetchDevices,
  };
})(window);
