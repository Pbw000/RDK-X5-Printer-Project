// dashboard.js — Dashboard page

PrintFlow.registerPage("dashboard", (container) => {
  const S = PrintFlow.state;
  const $ = PrintFlow.$;

  container.innerHTML = `
    <div class="page-grid dash-grid">
      <!-- Status Card -->
      <div class="card full-width">
        <div class="card-header">
          <div class="card-title">Printer Status</div>
          <div class="conn-indicator">
            <div class="conn-dot" id="dashConnDot"></div>
            <span id="dashConnText"></span>
          </div>
        </div>
        <div class="status-bar" id="statusBar">
          <div class="status-ring">
            <svg viewBox="0 0 44 44">
              <circle class="ring-track" cx="22" cy="22" r="18"/>
              <circle class="ring-fill" id="dashRing" cx="22" cy="22" r="18"/>
            </svg>
            <div class="status-ring-icon" id="dashRingIcon">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <polyline points="6 9 6 2 18 2 18 9"/>
                <path d="M6 18H4a2 2 0 0 1-2-2v-5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2h-2"/>
                <rect x="6" y="14" width="12" height="8"/>
              </svg>
            </div>
          </div>
          <div class="status-info">
            <div class="status-label" id="dashLabel"></div>
            <div class="status-detail" id="dashDetail"></div>
          </div>
          <div class="batch-section" id="dashBatch" style="display:none">
            <div class="batch-header">
              <span class="batch-label" id="dashBatchName"></span>
              <span class="batch-count" id="dashBatchCount"></span>
            </div>
            <div class="progress-track">
              <div class="progress-fill" id="dashProgress"></div>
            </div>
          </div>
          <div class="moving-badge" id="dashMoving" style="display:none">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><line x1="5" y1="12" x2="19" y2="12"/><polyline points="12 5 19 12 12 19"/></svg>
            <span id="dashMovingTarget"></span>
          </div>
        </div>
      </div>

      <!-- Mini Map -->
      <div class="card">
        <div class="card-header">
          <div class="card-title">Location Map</div>
          <div class="map-coord">
            <strong id="dashPosX">0.00</strong>, <strong id="dashPosY">0.00</strong>
          </div>
        </div>
        <div class="card-body mini-map-container">
          <canvas id="mapCanvasMini"></canvas>
        </div>
      </div>

      <!-- Events -->
      <div class="card">
        <div class="card-header">
          <div class="card-title">Live Activity</div>
        </div>
        <div class="card-body">
          <div class="events-feed" id="dashEvents"></div>
        </div>
      </div>
    </div>
  `;

  const el = {
    connDot: $("#dashConnDot"),
    connText: $("#dashConnText"),
    ring: $("#dashRing"),
    ringIcon: $("#dashRingIcon"),
    label: $("#dashLabel"),
    detail: $("#dashDetail"),
    batch: $("#dashBatch"),
    batchName: $("#dashBatchName"),
    batchCount: $("#dashBatchCount"),
    progress: $("#dashProgress"),
    moving: $("#dashMoving"),
    movingTarget: $("#dashMovingTarget"),
    posX: $("#dashPosX"),
    posY: $("#dashPosY"),
    eventsFeed: $("#dashEvents"),
    canvas: $("#mapCanvasMini"),
  };

  function updateStatus() {
    const s = S.printerState;
    const cls = "s-" + s;

    el.ring.setAttribute("class", "ring-fill " + cls);
    el.ringIcon.className = "status-ring-icon " + cls;
    el.label.className = "status-label " + cls;
    el.label.textContent = PrintFlow.STATE_NAMES[s] || s;
    el.detail.textContent = S.printerDetail || "";

    el.connDot.className = "conn-dot" + (S.connected ? " online" : " error");
    el.connText.textContent = S.connected ? "Online" : "Offline";

    // Batch
    if (s === "printing" && S.currentBatch) {
      el.batch.style.display = "";
      el.batchName.textContent = S.currentBatch.name;
      el.batchCount.textContent = S.currentBatch.completed + "/" + S.currentBatch.total;
      el.progress.style.width = (S.currentBatch.total > 0 ? (S.currentBatch.completed / S.currentBatch.total * 100) : 0) + "%";
    } else {
      el.batch.style.display = "none";
    }

    el.moving.style.display = s === "moving" ? "" : "none";
    if (s === "moving") {
      el.movingTarget.textContent = S.printerDetail;
    }
  }

  function updatePosition() {
    el.posX.textContent = S.printerPos.x.toFixed(2);
    el.posY.textContent = S.printerPos.y.toFixed(2);
  }

  function renderEvents() {
    el.eventsFeed.innerHTML = "";
    S.events.slice(0, 30).forEach((ev) => {
      const div = document.createElement("div");
      div.className = "event-item";
      div.innerHTML = `
        <span class="event-time">${PrintFlow.esc(ev.time)}</span>
        <span class="event-dot ${ev.icon}"></span>
        <span class="event-msg">${PrintFlow.esc(ev.msg)}</span>
      `;
      el.eventsFeed.appendChild(div);
    });
  }

  function drawMiniMap() {
    PrintFlow.drawMapOnCanvas(el.canvas, "mini");
  }

  // Event listeners
  function onState() { updateStatus(); drawMiniMap(); }
  function onPos() { updatePosition(); drawMiniMap(); }
  function onEvt() { renderEvents(); }
  function onMap() { drawMiniMap(); }
  function onLoc() { drawMiniMap(); }

  PrintFlow.on("stateChange", onState);
  PrintFlow.on("positionUpdate", onPos);
  PrintFlow.on("event", onEvt);
  PrintFlow.on("mapUpdate", onMap);
  PrintFlow.on("locationsUpdate", onLoc);

  // Cleanup on navigate away
  window.addEventListener("hashchange", function cleanup() {
    PrintFlow.on = PrintFlow.on; // noop, listeners persist but page elements are gone
    window.removeEventListener("hashchange", cleanup);
  }, { once: true });

  // Initial render
  updateStatus();
  updatePosition();
  renderEvents();
  drawMiniMap();

  // Animate map while moving/printing
  let animFrame = null;
  function tick() {
    drawMiniMap();
    if (S.printerState === "moving" || S.printerState === "printing") {
      animFrame = requestAnimationFrame(tick);
    } else {
      animFrame = null;
    }
  }

  function startAnim() {
    if (!animFrame) animFrame = requestAnimationFrame(tick);
  }

  PrintFlow.on("stateChange", (s) => {
    if (s === "moving" || s === "printing") startAnim();
  });

  window.addEventListener("resize", drawMiniMap);
});
