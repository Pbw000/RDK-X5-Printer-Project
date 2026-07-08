// common.js — Shared state, SSE connection, utilities

window.PrintFlow = (() => {
  // ─── Shared State ───
  const state = {
    printerState: "connecting",
    printerDetail: "",
    printerPos: { x: 0, y: 0, theta: 0 },
    locations: [],
    selectedLocation: null,
    activeLocationId: null,
    currentBatch: null,
    trackedJobs: [],
    stagedFiles: [],
    mapGrid: null,         // { width, height, resolution, origin_x, origin_y, theta, data }
    mapImageCanvas: null,  // offscreen canvas
    events: [],            // recent events log
    connected: false,
  };

  // ─── Event Bus (page-local, with cleanup) ───
  const listeners = {};
  function on(event, fn) {
    (listeners[event] = listeners[event] || []).push(fn);
  }
  function off(event, fn) {
    const arr = listeners[event];
    if (!arr) return;
    const idx = arr.indexOf(fn);
    if (idx !== -1) arr.splice(idx, 1);
  }
  function emit(event, data) {
    (listeners[event] || []).forEach((fn) => fn(data));
  }
  function removeAllListeners() {
    for (const key of Object.keys(listeners)) {
      delete listeners[key];
    }
  }

  // ─── Utilities ───
  function $(sel, ctx) { return (ctx || document).querySelector(sel); }
  function $$(sel, ctx) { return Array.from((ctx || document).querySelectorAll(sel)); }

  function esc(s) {
    const d = document.createElement("div");
    d.textContent = s;
    return d.innerHTML;
  }

  function formatBytes(bytes) {
    if (bytes < 1024) return bytes + " B";
    if (bytes < 1048576) return (bytes / 1024).toFixed(1) + " KB";
    return (bytes / 1048576).toFixed(1) + " MB";
  }

  function timeStr() {
    return new Date().toLocaleTimeString("en-US", {
      hour12: false, hour: "2-digit", minute: "2-digit", second: "2-digit",
    });
  }

  function truncate(s, n) {
    return s.length > n ? s.slice(0, n) + "\u2026" : s;
  }

  function toast(msg, type) {
    type = type || "info";
    const el = document.createElement("div");
    el.className = "toast " + type;
    el.textContent = msg;
    $("#toastContainer").appendChild(el);
    setTimeout(() => {
      el.style.opacity = "0";
      setTimeout(() => el.remove(), 300);
    }, 4000);
  }

  // ─── Map Image Builder ───
  function buildMapImage(grid) {
    const off = document.createElement("canvas");
    off.width = grid.width;
    off.height = grid.height;
    const ctx = off.getContext("2d");
    const imgData = ctx.createImageData(grid.width, grid.height);
    const raw = grid.data;
    const w = grid.width, h = grid.height;
    for (let row = 0; row < h; row++) {
      const srcRow = h - 1 - row;
      for (let col = 0; col < w; col++) {
        const v = raw[srcRow * w + col];
        const o = (row * w + col) * 4;
        if (v === 127 || v === 255) {
          // unknown → light grey
          imgData.data[o] = 200; imgData.data[o+1] = 195; imgData.data[o+2] = 188; imgData.data[o+3] = 255;
        } else if (v > 50) {
          // occupied → dark charcoal
          imgData.data[o] = 74; imgData.data[o+1] = 70; imgData.data[o+2] = 64; imgData.data[o+3] = 255;
        } else {
          // free → warm off-white
          imgData.data[o] = 245; imgData.data[o+1] = 243; imgData.data[o+2] = 239; imgData.data[o+3] = 255;
        }
      }
    }
    ctx.putImageData(imgData, 0, 0);
    return off;
  }

  function applyMapGrid(grid) {
    const bin = atob(grid.data);
    const arr = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
    state.mapGrid = {
      width: grid.width, height: grid.height,
      resolution: grid.resolution,
      origin_x: grid.origin_x, origin_y: grid.origin_y,
      origin_theta: grid.origin_theta,
      data: arr,
    };
    state.mapImageCanvas = buildMapImage(state.mapGrid);
    emit("mapUpdate", state.mapGrid);
  }

  // ─── Map Drawing (shared logic, takes canvas context) ───
  function drawMapOnCanvas(canvas, sizeMode) {
    const ctx = canvas.getContext("2d");
    const dpr = window.devicePixelRatio || 1;
    canvas.width = canvas.clientWidth * dpr;
    canvas.height = canvas.clientHeight * dpr;
    ctx.scale(dpr, dpr);
    const w = canvas.clientWidth;
    const h = canvas.clientHeight;
    ctx.clearRect(0, 0, w, h);
    if (w < 10 || h < 10) return;

    const mg = state.mapGrid;
    const locs = state.locations;

    // Compute world bounds
    let minX, maxX, minY, maxY;
    if (mg) {
      const mw = mg.width * mg.resolution;
      const mh = mg.height * mg.resolution;
      minX = mg.origin_x;
      maxX = mg.origin_x + mw;
      minY = mg.origin_y;
      maxY = mg.origin_y + mh;
    } else if (locs.length) {
      minX = Infinity; maxX = -Infinity;
      minY = Infinity; maxY = -Infinity;
    } else { return; }

    const pts = [
      { x: state.printerPos.x, y: state.printerPos.y },
      ...locs.map(l => ({ x: l.location.x_cord, y: l.location.y_cord })),
    ];
    for (const p of pts) {
      if (mg) {
        if (p.x < minX) minX = p.x;
        if (p.x > maxX) maxX = p.x;
        if (p.y < minY) minY = p.y;
        if (p.y > maxY) maxY = p.y;
      } else {
        if (minX === undefined || p.x < minX) minX = p.x;
        if (maxX === undefined || p.x > maxX) maxX = p.x;
        if (minY === undefined || p.y < minY) minY = p.y;
        if (maxY === undefined || p.y > maxY) maxY = p.y;
      }
    }

    const padFrac = 0.12;
    const px = (maxX - minX) * padFrac || 5;
    const py = (maxY - minY) * padFrac || 5;
    minX -= px; maxX += px;
    minY -= py; maxY += py;
    const rangeX = maxX - minX || 1;
    const rangeY = maxY - minY || 1;

    // Aspect-ratio fit
    const wa = rangeX / rangeY;
    const ca = w / h;
    let scale, offX, offY;
    if (wa > ca) {
      scale = w / rangeX; offX = 0; offY = (h - rangeY * scale) / 2;
    } else {
      scale = h / rangeY; offX = (w - rangeX * scale) / 2; offY = 0;
    }

    function tx(x) { return offX + (x - minX) * scale; }
    function ty(y) { return h - offY - (y - minY) * scale; }

    // Draw occupancy grid
    if (mg && state.mapImageCanvas) {
      const ox = tx(mg.origin_x);
      const oy = ty(mg.origin_y);
      const mpw = mg.width * mg.resolution * scale;
      const mph = mg.height * mg.resolution * scale;
      ctx.save();
      ctx.imageSmoothingEnabled = false;
      ctx.drawImage(state.mapImageCanvas, 0, 0, mg.width, mg.height, ox, oy - mph, mpw, mph);
      ctx.restore();
    }

    // Connection line to active location
    if (state.activeLocationId !== null && locs[state.activeLocationId]) {
      const loc = locs[state.activeLocationId].location;
      ctx.strokeStyle = "rgba(59, 130, 246, 0.35)";
      ctx.lineWidth = 2;
      ctx.setLineDash([6, 6]);
      ctx.beginPath();
      ctx.moveTo(tx(state.printerPos.x), ty(state.printerPos.y));
      ctx.lineTo(tx(loc.x_cord), ty(loc.y_cord));
      ctx.stroke();
      ctx.setLineDash([]);
    }

    // Location dots
    locs.forEach((loc, idx) => {
      const x = tx(loc.location.x_cord);
      const y = ty(loc.location.y_cord);
      const queueLen = loc.pending_jobs ? loc.pending_jobs.length : 0;
      const isActive = idx === state.activeLocationId;
      const isSelected = idx === state.selectedLocation;

      if (isActive) {
        ctx.beginPath();
        ctx.arc(x, y, 16, 0, Math.PI * 2);
        ctx.fillStyle = "rgba(34, 197, 94, 0.1)";
        ctx.fill();
      }

      ctx.beginPath();
      ctx.arc(x, y, 8, 0, Math.PI * 2);
      ctx.fillStyle = isActive ? "#22c55e" : queueLen > 0 ? "#e8a634" : isSelected ? "#6b6560" : "#b8b2aa";
      ctx.fill();

      if (isActive || queueLen > 0) {
        ctx.strokeStyle = isActive ? "#22c55e" : "#e8a634";
        ctx.lineWidth = 2;
        ctx.beginPath();
        ctx.arc(x, y, 10, 0, Math.PI * 2);
        ctx.stroke();
      }

      ctx.fillStyle = "#1a1816";
      ctx.font = (sizeMode === "large" ? 'bold 11px' : '10px') + ' "DM Mono", monospace';
      ctx.textAlign = "center";
      ctx.fillText(loc.name, x, y + 22);

      if (queueLen > 0) {
        ctx.fillStyle = isActive ? "#22c55e" : "#e8a634";
        ctx.beginPath();
        ctx.arc(x + 11, y - 11, 7, 0, Math.PI * 2);
        ctx.fill();
        ctx.fillStyle = "#fff";
        ctx.font = 'bold 9px "DM Mono"';
        ctx.textAlign = "center";
        ctx.textBaseline = "middle";
        ctx.fillText(String(queueLen), x + 11, y - 11);
        ctx.textBaseline = "alphabetic";
      }
    });

    // Printer icon
    const ppx = tx(state.printerPos.x);
    const ppy = ty(state.printerPos.y);

    // Pulse
    if (state.printerState === "moving" || state.printerState === "printing") {
      const t = Date.now() / 1000;
      const r = 12 + Math.sin(t * 3) * 4;
      ctx.beginPath();
      ctx.arc(ppx, ppy, r, 0, Math.PI * 2);
      ctx.fillStyle = state.printerState === "moving"
        ? "rgba(59, 130, 246, 0.1)"
        : "rgba(232, 166, 52, 0.1)";
      ctx.fill();
    }

    ctx.save();
    ctx.translate(ppx, ppy);
    ctx.rotate(Math.PI / 4);
    ctx.fillStyle =
      state.printerState === "moving" ? "#3b82f6"
      : state.printerState === "printing" ? "#e8a634"
      : state.printerState === "error" ? "#ef4444"
      : "#22c55e";
    ctx.fillRect(-6, -6, 12, 12);
    ctx.strokeStyle = "#fff";
    ctx.lineWidth = 1.5;
    ctx.strokeRect(-6, -6, 12, 12);
    ctx.restore();

        // Coordinate display — return full transform for click-to-coord
    return { tx, ty, minX, maxX, minY, maxY, scale, offX, offY, worldW: rangeX, worldH: rangeY };
  }

  // ─── Locations ───
  async function loadLocations() {
    try {
      const res = await fetch("/api/locations");
      if (!res.ok) return;
      const data = await res.json();
      state.locations = data.destinations || [];
      emit("locationsUpdate", state.locations);
    } catch (_) {}
  }

  // ─── Map Fetch (initial) ───
  async function fetchMap() {
    try {
      const res = await fetch("/api/map");
      if (!res.ok) return;
      const grid = await res.json();
      applyMapGrid(grid);
      addEvent("Map loaded from SLAM", "info");
    } catch (_) {}
  }

  // ─── Events ───
  function addEvent(msg, iconType) {
    iconType = iconType || "info";
    const ev = { time: timeStr(), icon: iconType, msg };
    state.events.unshift(ev);
    if (state.events.length > 80) state.events.length = 80;
    emit("event", ev);
  }

  // ─── SSE ───
  let eventSource = null;
  let reconnectTimer = null;
  let initialStateSynced = false;

  function connectSSE() {
    if (eventSource) eventSource.close();
    if (!initialStateSynced) {
      state.printerState = "connecting";
      state.printerDetail = "Waiting for printer stream...";
      emit("stateChange", state.printerState);
    }

    eventSource = new EventSource("/api/events");

    eventSource.onopen = () => {
      state.connected = true;
      if (!initialStateSynced || state.printerState === "connecting") {
        state.printerState = "idle";
        state.printerDetail = "Connected";
        emit("stateChange", "idle");
      }
      addEvent("Connected to printer stream", "info");
    };

    eventSource.onmessage = (e) => {
      try { handleEvent(JSON.parse(e.data)); } catch (_) {}
    };

    eventSource.addEventListener("lagged", (e) => {
      addEvent("Stream lagged: " + e.data, "error");
    });

    eventSource.onerror = () => {
      state.connected = false;
      initialStateSynced = false;
      state.printerState = "error";
      state.printerDetail = "Connection lost";
      emit("stateChange", "error");
      addEvent("Connection lost, reconnecting...", "error");
      eventSource.close();
      clearTimeout(reconnectTimer);
      reconnectTimer = setTimeout(connectSSE, 3000);
    };
  }

  const STATE_NAMES = {
    connecting: "Connecting", idle: "Idle", printing: "Printing",
    moving: "Moving", error: "Error",
  };

  function handleEvent(data) {
    const isString = typeof data === "string";
    const variant = isString ? data : Object.keys(data)[0];
    const p = isString ? {} : data[variant] || {};

    switch (variant) {
      case "Idle":
        state.activeLocationId = null;
        state.currentBatch = null;
        state.printerState = "idle";
        state.printerDetail = "Waiting for print jobs";
        addEvent("Printer idle", "info");
        loadLocations();
        break;

      case "BatchStarted":
        state.activeLocationId = p.location_id;
        state.currentBatch = { name: p.location_name, total: p.total_jobs, completed: 0 };
        state.printerState = "printing";
        state.printerDetail = p.total_jobs + " job(s) at " + p.location_name;
        addEvent("Batch started: " + p.location_name + " (" + p.total_jobs + " jobs)", "info");
        break;

      case "PrintStarted":
        state.printerState = "printing";
        state.printerDetail = "Printing " + (p.job_index + 1) + "/" + p.total_jobs;
        updateTracker(p.store_name, "printing");
        addEvent("Printing: " + truncate(p.store_name, 24), "info");
        break;

      case "PrintComplete":
        if (state.currentBatch) state.currentBatch.completed++;
        updateTracker(p.store_name, "done");
        addEvent("Complete: " + truncate(p.store_name, 24), "success");
        break;

      case "PrintFailed":
        updateTracker(p.store_name, "failed");
        addEvent("Failed: " + p.msg, "error");
        break;

      case "BatchComplete":
        state.activeLocationId = null;
        state.currentBatch = null;
        state.printerState = "idle";
        state.printerDetail = "Batch done at " + p.location_name + ": " + p.succeeded + " ok, " + p.failed + " failed";
        addEvent("Batch done: " + p.location_name, p.failed > 0 ? "error" : "success");
        loadLocations();
        break;

      case "MovingTo":
        state.activeLocationId = p.location_id;
        state.printerState = "moving";
        state.printerDetail = "En route to " + p.location_name;
        addEvent("Moving to " + p.location_name, "move");
        break;

      case "PositionUpdate":
        state.printerPos = { x: p.x, y: p.y, theta: p.theta };
        emit("positionUpdate", state.printerPos);
        break;

      case "MoveComplete":
        state.printerState = "printing";
        state.printerDetail = "Arrived";
        addEvent("Arrived at destination", "success");
        break;

      case "NavError":
        addEvent("Nav error: " + p.msg, "error");
        break;

      case "SchedulerError":
        state.printerState = "error";
        state.printerDetail = p.msg;
        addEvent("Scheduler: " + p.msg, "error");
        break;

      default:
        break;
    }
    emit("stateChange", state.printerState);
  }

  // ─── Tracker ───
  function addTrackedJob(storedName, originalName, ext, locationName) {
    state.trackedJobs.push({
      stored_name: storedName, original_name: originalName,
      ext, location_name: locationName, status: "queued",
    });
    emit("trackerUpdate", null);
  }

  function updateTracker(storedName, newStatus) {
    for (let i = 0; i < state.trackedJobs.length; i++) {
      const j = state.trackedJobs[i];
      if (j.stored_name === storedName && j.status !== "done" && j.status !== "failed") {
        j.status = newStatus;
        break;
      }
    }
    emit("trackerUpdate", null);
    if (newStatus === "done" || newStatus === "failed") {
      setTimeout(() => {
        state.trackedJobs = state.trackedJobs.filter(j => j.status === "queued" || j.status === "printing");
        emit("trackerUpdate", null);
      }, 8000);
    }
  }

  // ─── Init ───
  async function init() {
    await Promise.all([loadLocations(), fetchMap()]);
    // Sync initial printer status
    try {
      const res = await fetch("/api/printer/status");
      if (res.ok) {
        const d = await res.json();
        const raw = d.status;
        if (typeof raw === "string" && raw === "Idle") {
          state.printerState = "idle";
          state.printerDetail = "Connected";
        } else if (raw && typeof raw === "object" && raw.Printing) {
          state.printerState = "printing";
          state.printerDetail = "Resuming: " + raw.Printing.processed + "/" + raw.Printing.total;
        }
        initialStateSynced = true;
      }
    } catch (_) {}

    // Sync initial position
    try {
      const res = await fetch("/api/printer/position");
      if (res.ok) {
        const d = await res.json();
        state.printerPos = { x: d.x, y: d.y, theta: d.theta };
      }
    } catch (_) {}

    connectSSE();
    emit("stateChange", state.printerState);
    emit("positionsUpdate", state.printerPos);
  }

  // ─── Router ───
  const pages = {};
  function registerPage(name, fn) { pages[name] = fn; }

  function navigate() {
    const hash = location.hash.replace("#/", "") || "dashboard";
    const pageName = hash.split("/")[0] || "dashboard";
    const container = $("#pageContainer");

    // Update nav active state
    $$(".nav-link").forEach((a) => {
      const p = a.getAttribute("data-page");
      a.classList.toggle("active", p === pageName);
    });

    // Clear page-specific listeners (keep the bus clean)
    removeAllListeners();

    // Render page
    if (pages[pageName]) {
      container.innerHTML = "";
      pages[pageName](container);
    } else {
      container.innerHTML = '<div class="empty-state"><p>Page not found</p></div>';
    }
  }

  window.addEventListener("hashchange", navigate);

  return {
    state, on, off, emit, removeAllListeners, $, $$, esc, formatBytes, timeStr, truncate, toast,
    drawMapOnCanvas, addTrackedJob, loadLocations, fetchMap, init, navigate,
    registerPage, addEvent, STATE_NAMES,
  };
})();
