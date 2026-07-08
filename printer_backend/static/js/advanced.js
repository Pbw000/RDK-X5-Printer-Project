// advanced.js — Advanced page: map point picker & JSON config generator

PrintFlow.registerPage("advanced", (container) => {
  const S = PrintFlow.state;
  const $ = PrintFlow.$;

  // Page-local state
  let selectedPoints = []; // [{ x, y }]
  let lastMapTransform = null;

  container.innerHTML = `
    <div class="advanced-page-layout">
      <!-- Map -->
      <div class="card advanced-map-card">
        <div class="card-header">
          <div class="card-title">Select Points on Map</div>
          <div class="advanced-header-actions">
            <span class="point-count-badge" id="advPointCount">0 points selected</span>
            <button class="btn btn-sm btn-outline" id="advClearBtn">Clear All</button>
            <button class="btn btn-sm btn-primary" id="advDoneBtn">Complete</button>
          </div>
        </div>
        <div class="card-body">
          <canvas id="advMapCanvas"></canvas>
          <div class="map-toolbar">
            <div class="map-coord">
              Position: <strong id="advPosX">0.00</strong>, <strong id="advPosY">0.00</strong>
              &nbsp;|&nbsp;
              <strong id="advPosTh">0.0</strong>°
            </div>
            <div class="map-coord" id="advClickCoord" style="display:none">
              Clicked: <strong id="advClickX">—</strong>, <strong id="advClickY">—</strong>
            </div>
            <div class="map-legend">
              <span class="legend-item"><span class="legend-dot printer-dot"></span>Printer</span>
              <span class="legend-item"><span class="legend-dot adv-pick-dot"></span>Picked</span>
              <span class="legend-item"><span class="legend-dot wall"></span>Wall</span>
            </div>
          </div>
        </div>
      </div>

      <!-- JSON Output -->
      <div class="card advanced-json-card" id="advJsonPanel" style="display:none">
        <div class="card-header">
          <div class="card-title">Generated JSON Config</div>
          <button class="btn btn-sm btn-outline" id="advCopyBtn">Copy</button>
        </div>
        <div class="card-body">
          <textarea id="advJsonText" class="json-textarea" spellcheck="false"></textarea>
        </div>
      </div>
    </div>
  `;

  const el = {
    canvas: $("#advMapCanvas"),
    posX: $("#advPosX"),
    posY: $("#advPosY"),
    posTh: $("#advPosTh"),
    clickCoord: $("#advClickCoord"),
    clickX: $("#advClickX"),
    clickY: $("#advClickY"),
    pointCount: $("#advPointCount"),
    clearBtn: $("#advClearBtn"),
    doneBtn: $("#advDoneBtn"),
    jsonPanel: $("#advJsonPanel"),
    jsonText: $("#advJsonText"),
    copyBtn: $("#advCopyBtn"),
  };

  function updatePosition() {
    el.posX.textContent = S.printerPos.x.toFixed(2);
    el.posY.textContent = S.printerPos.y.toFixed(2);
    el.posTh.textContent = (S.printerPos.theta * 180 / Math.PI).toFixed(1);
  }

  function updatePointCount() {
    el.pointCount.textContent = selectedPoints.length + " point" + (selectedPoints.length !== 1 ? "s" : "") + " selected";
  }

  function drawMap() {
    lastMapTransform = PrintFlow.drawMapOnCanvas(el.canvas, "large");
    // Draw picked points on top
    if (!lastMapTransform) return;
    const ctx = el.canvas.getContext("2d");
    const dpr = window.devicePixelRatio || 1;
    ctx.save();
    ctx.scale(dpr, dpr);

    const t = lastMapTransform;
    selectedPoints.forEach((pt, idx) => {
      const x = t.tx(pt.x);
      const y = t.ty(pt.y);

      // Numbered marker
      ctx.beginPath();
      ctx.arc(x, y, 10, 0, Math.PI * 2);
      ctx.fillStyle = "#e8a634";
      ctx.fill();
      ctx.strokeStyle = "#fff";
      ctx.lineWidth = 2;
      ctx.stroke();

      ctx.fillStyle = "#1a1816";
      ctx.font = 'bold 10px "DM Mono", monospace';
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.fillText(String(idx + 1), x, y);
      ctx.textBaseline = "alphabetic";

      // Label below
      ctx.fillStyle = "#1a1816";
      ctx.font = '10px "DM Mono", monospace';
      ctx.textAlign = "center";
      ctx.fillText("Point " + (idx + 1), x, y + 22);
    });

    // Draw lines connecting points in order
    if (selectedPoints.length > 1) {
      ctx.strokeStyle = "rgba(232, 166, 52, 0.5)";
      ctx.lineWidth = 2;
      ctx.setLineDash([4, 4]);
      ctx.beginPath();
      ctx.moveTo(t.tx(selectedPoints[0].x), t.ty(selectedPoints[0].y));
      for (let i = 1; i < selectedPoints.length; i++) {
        ctx.lineTo(t.tx(selectedPoints[i].x), t.ty(selectedPoints[i].y));
      }
      ctx.stroke();
      ctx.setLineDash([]);
    }

    ctx.restore();
  }

  function generateJson() {
    const destinations = selectedPoints.map((pt, idx) => ({
      name: "Point " + (idx + 1),
      description: "Description for point " + (idx + 1),
      location: {
        x_cord: parseFloat(pt.x.toFixed(2)),
        y_cord: parseFloat(pt.y.toFixed(2)),
      },
    }));
    return JSON.stringify({ destinations }, null, 4);
  }

  // ── Click on map → add point ──
  el.canvas.addEventListener("click", (e) => {
    if (!lastMapTransform) return;
    const rect = el.canvas.getBoundingClientRect();
    const cssX = e.clientX - rect.left;
    const cssY = e.clientY - rect.top;
    const t = lastMapTransform;
    const worldX = (cssX - t.offX) / t.scale + t.minX;
    const worldY = (rect.height - t.offY - cssY) / t.scale + t.minY;

    selectedPoints.push({ x: worldX, y: worldY });
    updatePointCount();
    drawMap();

    el.clickX.textContent = worldX.toFixed(2);
    el.clickY.textContent = worldY.toFixed(2);
    el.clickCoord.style.display = "";
  });

  // ── Clear all points ──
  el.clearBtn.addEventListener("click", () => {
    selectedPoints = [];
    updatePointCount();
    el.jsonPanel.style.display = "none";
    drawMap();
  });

  // ── Done button → generate JSON ──
  el.doneBtn.addEventListener("click", () => {
    if (selectedPoints.length === 0) {
      PrintFlow.toast("Please select at least one point on the map", "error");
      return;
    }
    const json = generateJson();
    el.jsonText.value = json;
    el.jsonPanel.style.display = "";
    PrintFlow.toast("JSON config generated", "success");
  });

  // ── Copy JSON ──
  el.copyBtn.addEventListener("click", () => {
    navigator.clipboard.writeText(el.jsonText.value).then(() => {
      PrintFlow.toast("Copied to clipboard", "success");
    }).catch(() => {
      PrintFlow.toast("Failed to copy", "error");
    });
  });

  // ── Listeners ──
  function onPos() { updatePosition(); drawMap(); }
  function onMap() { drawMap(); }

  PrintFlow.on("positionUpdate", onPos);
  PrintFlow.on("mapUpdate", onMap);

  // Initial render
  updatePosition();
  updatePointCount();
  drawMap();

  window.addEventListener("resize", drawMap);
});
