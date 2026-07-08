// map.js — Full-screen map page with location sidebar

PrintFlow.registerPage("map", (container) => {
  const S = PrintFlow.state;
  const $ = PrintFlow.$;

  container.innerHTML = `
    <div class="map-page-layout">
      <!-- Map -->
      <div class="card map-card">
        <div class="card-header">
          <div class="card-title">Navigation Map</div>
        </div>
        <div class="card-body">
          <canvas id="mapCanvasLarge"></canvas>
          <div class="map-toolbar">
            <div class="map-coord">
              Position: <strong id="mapPosX">0.00</strong>, <strong id="mapPosY">0.00</strong>
              &nbsp;|&nbsp;
              <strong id="mapPosTh">0.0</strong>°
            </div>
            <div class="map-coord" id="mapClickCoord" style="display:none">
              Clicked: <strong id="mapClickX">—</strong>, <strong id="mapClickY">—</strong>
            </div>
            <div class="map-legend">
              <span class="legend-item"><span class="legend-dot printer-dot"></span>Printer</span>
              <span class="legend-item"><span class="legend-dot active-loc"></span>Active</span>
              <span class="legend-item"><span class="legend-dot queued"></span>Queued</span>
              <span class="legend-item"><span class="legend-dot idle"></span>Idle</span>
              <span class="legend-item"><span class="legend-dot free"></span>Free</span>
              <span class="legend-item"><span class="legend-dot wall"></span>Wall</span>
            </div>
          </div>
        </div>
      </div>

      <!-- Sidebar: locations -->
      <div class="card map-sidebar">
        <div class="card-header">
          <div class="card-title">Print Locations</div>
        </div>
        <div class="card-body" id="mapLocList"></div>
      </div>
    </div>
  `;

  const el = {
    canvas: $("#mapCanvasLarge"),
    posX: $("#mapPosX"),
    posY: $("#mapPosY"),
    posTh: $("#mapPosTh"),
    locList: $("#mapLocList"),
    clickCoord: $("#mapClickCoord"),
    clickX: $("#mapClickX"),
    clickY: $("#mapClickY"),
  };

  function updatePosition() {
    el.posX.textContent = S.printerPos.x.toFixed(2);
    el.posY.textContent = S.printerPos.y.toFixed(2);
    el.posTh.textContent = (S.printerPos.theta * 180 / Math.PI).toFixed(1);
  }

  function renderLocations() {
    el.locList.innerHTML = "";
    if (!S.locations.length) {
      el.locList.innerHTML = '<div class="empty-state"><p>No locations configured</p></div>';
      return;
    }
    S.locations.forEach((loc, idx) => {
      const queueLen = loc.pending_jobs ? loc.pending_jobs.length : 0;
      const isActive = idx === S.activeLocationId;
      const isSelected = idx === S.selectedLocation;

      let cls = "location-card";
      if (isActive) cls += " active-print";
      else if (isSelected) cls += " selected";

      let badge = "";
      if (isActive) badge = '<span class="loc-badge active">Active</span>';
      else if (queueLen > 0) badge = '<span class="loc-badge queued">' + queueLen + ' queued</span>';

      const card = document.createElement("div");
      card.className = cls;
      card.innerHTML = `
        <div class="loc-top">
          <div class="location-name">${PrintFlow.esc(loc.name)}</div>
          ${badge}
        </div>
        <div class="location-desc">${PrintFlow.esc(loc.description)}</div>
        <div class="location-coords">
          x: ${loc.location.x_cord.toFixed(2)}  y: ${loc.location.y_cord.toFixed(2)}
        </div>
      `;
      card.addEventListener("click", () => {
        S.selectedLocation = idx;
        renderLocations();
        drawMap();
      });
      el.locList.appendChild(card);
    });
  }

    let lastMapTransform = null;
  function drawMap() {
    lastMapTransform = PrintFlow.drawMapOnCanvas(el.canvas, "large");
  }

  // Click on map → show world coordinates
  el.canvas.addEventListener("click", (e) => {
    if (!lastMapTransform) return;
    const rect = el.canvas.getBoundingClientRect();
    const cssX = e.clientX - rect.left;
    const cssY = e.clientY - rect.top;
    const t = lastMapTransform;
    const worldX = (cssX - t.offX) / t.scale + t.minX;
    const worldY = (rect.height - t.offY - cssY) / t.scale + t.minY;
    el.clickX.textContent = worldX.toFixed(2);
    el.clickY.textContent = worldY.toFixed(2);
    el.clickCoord.style.display = "";
  });

  // Listeners
  function onPos() { updatePosition(); drawMap(); }
  function onState() { drawMap(); renderLocations(); }
  function onLoc() { renderLocations(); drawMap(); }
  function onMap() { drawMap(); }

  PrintFlow.on("positionUpdate", onPos);
  PrintFlow.on("stateChange", onState);
  PrintFlow.on("locationsUpdate", onLoc);
  PrintFlow.on("mapUpdate", onMap);

  // Initial render
  updatePosition();
  renderLocations();
  drawMap();

  // Animate while active
  let animFrame = null;
  function tick() {
    drawMap();
    if (S.printerState === "moving" || S.printerState === "printing") {
      animFrame = requestAnimationFrame(tick);
    } else {
      animFrame = null;
    }
  }

  PrintFlow.on("stateChange", (s) => {
    if ((s === "moving" || s === "printing") && !animFrame) {
      animFrame = requestAnimationFrame(tick);
    }
  });

  window.addEventListener("resize", drawMap);
});
