// print.js — Upload, file staging, job submission, tracker

PrintFlow.registerPage("print", (container) => {
  const S = PrintFlow.state;
  const $ = PrintFlow.$;
  let isUploading = false;



  container.innerHTML = `
    <div class="page-grid print-grid">
      <div style="display:flex;flex-direction:column;gap:20px">
        <!-- Upload -->
        <div class="card">
          <div class="card-header">
            <div class="card-title">Upload Files</div>
          </div>
          <div class="card-body">
            <div class="upload-zone" id="printUpload">
              <svg class="upload-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
                <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>
                <polyline points="17 8 12 3 7 8"/>
                <line x1="12" y1="3" x2="12" y2="15"/>
              </svg>
              <div class="upload-title">Drop files here or click to upload</div>
              <div class="upload-sub">PDF, JPG, PNG, TXT</div>
              <input type="file" class="upload-input" id="printUploadInput" multiple accept=".pdf,.jpg,.jpeg,.png,.txt">
            </div>
          </div>
        </div>

        <!-- Staged Files -->
        <div class="card" id="stagedCard" style="display:none">
          <div class="card-header">
            <div class="card-title">Staged Files</div>
          </div>
          <div class="card-body">
            <div id="stagedList"></div>
          </div>
        </div>

        <!-- Submit -->
        <div class="card" id="submitCard" style="display:none">
          <div class="submit-row">
            <div class="submit-info">
              <div class="submit-count"><strong id="subCount">0</strong> file(s)</div>
              <div class="submit-dest">to <strong id="subDest">--</strong></div>
            </div>
            <div style="display:flex;gap:10px;align-items:center">
              <div class="file-priority" style="position:relative">
                <select class="priority-select" id="bulkPriority">
                  <option value="Low">Low</option>
                  <option value="Medium" selected>Medium</option>
                  <option value="High">High</option>
                  <option value="Critical">Critical</option>
                </select>
              </div>
              <button class="btn-submit" id="subBtn" disabled>
                <span id="subBtnText">Submit Jobs</span>
                <span id="subBtnLoad" style="display:none">Submitting...</span>
              </button>
            </div>
          </div>
        </div>
      </div>

      <!-- Right: Destination + Tracker -->
      <div style="display:flex;flex-direction:column;gap:20px">
        <!-- Destination list -->
        <div class="card">
          <div class="card-header">
            <div class="card-title">Destination</div>
          </div>
          <div class="card-body">
            <div id="destList"></div>
            <div id="destInfo" style="margin-top:12px;font-size:0.72rem;color:var(--text-muted)"></div>
          </div>
        </div>

        <!-- Tracker -->
        <div class="card" id="trackerCard" style="display:none">
          <div class="card-header">
            <div class="card-title">Print Tracker</div>
          </div>
          <div class="card-body">
            <div id="trackerList"></div>
          </div>
        </div>
      </div>
    </div>
  `;

  const el = {
    uploadZone: $("#printUpload"),
    uploadInput: $("#printUploadInput"),
    stagedCard: $("#stagedCard"),
    stagedList: $("#stagedList"),
    destList: $("#destList"),
    destInfo: $("#destInfo"),
    submitCard: $("#submitCard"),
    subCount: $("#subCount"),
    subDest: $("#subDest"),
    subBtn: $("#subBtn"),
    subBtnText: $("#subBtnText"),
    subBtnLoad: $("#subBtnLoad"),
    bulkPriority: $("#bulkPriority"),
    trackerCard: $("#trackerCard"),
    trackerList: $("#trackerList"),
  };

  // ─── Destination list ───
  function renderDestList() {
    el.destList.innerHTML = "";
    if (!S.locations.length) {
      el.destList.innerHTML = '<div class="empty-state"><p>No locations available</p></div>';
      return;
    }
    S.locations.forEach((loc, idx) => {
      const isSelected = idx === S.selectedLocation;
      const queueLen = loc.pending_jobs ? loc.pending_jobs.length : 0;
      const div = document.createElement("div");
      div.className = "dest-item" + (isSelected ? " selected" : "");
      const qBadge = queueLen > 0 ? '<span class="dest-queue-badge">' + queueLen + ' jobs</span>' : '';
      div.innerHTML = '<div class="dest-item-left">' +
        '<div class="dest-item-name">' + PrintFlow.esc(loc.name) + '</div>' +
        '<div class="dest-item-desc">' + PrintFlow.esc(loc.description) + '</div>' +
        '<div class="dest-item-coords">x: ' + loc.location.x_cord.toFixed(2) + '  y: ' + loc.location.y_cord.toFixed(2) + '</div>' +
        '</div>' +
        '<div class="dest-item-right">' + qBadge + '</div>';
      div.addEventListener("click", () => {
        S.selectedLocation = (S.selectedLocation === idx) ? null : idx;
        renderDestList();
        updateSubmit();
      });
      el.destList.appendChild(div);
    });
  }

  PrintFlow.on("locationsUpdate", renderDestList);

  // ─── Upload ───
  el.uploadZone.addEventListener("click", () => el.uploadInput.click());

  el.uploadZone.addEventListener("dragover", (e) => {
    e.preventDefault();
    el.uploadZone.classList.add("dragover");
  });

  el.uploadZone.addEventListener("dragleave", () => {
    el.uploadZone.classList.remove("dragover");
  });

  el.uploadZone.addEventListener("drop", (e) => {
    e.preventDefault();
    el.uploadZone.classList.remove("dragover");
    handleFiles(e.dataTransfer.files);
  });

  el.uploadInput.addEventListener("change", () => {
    handleFiles(el.uploadInput.files);
    el.uploadInput.value = "";
  });

  async function handleFiles(fileListInput) {
    if (isUploading) return;
    const files = Array.from(fileListInput);
    if (!files.length) return;
    isUploading = true;
    el.uploadZone.style.pointerEvents = "none";
    el.uploadZone.style.opacity = "0.5";

    for (const file of files) {
      try {
        const ext = file.name.split(".").pop().toLowerCase();
        const formData = new FormData();
        formData.append("file", file);
        const res = await fetch("/api/upload", { method: "POST", body: formData });
        if (!res.ok) {
          PrintFlow.toast("Upload failed: " + (await res.text()), "error");
          continue;
        }
        const data = await res.json();
        S.stagedFiles.push({
          stored_name: data.stored_name,
          original_name: file.name,
          file_size: data.file_size,
          ext,
        });
        PrintFlow.toast("Uploaded: " + file.name, "success");
      } catch (e) {
        PrintFlow.toast("Upload error: " + e.message, "error");
      }
    }

    isUploading = false;
    el.uploadZone.style.pointerEvents = "";
    el.uploadZone.style.opacity = "";
    renderStaged();
    updateSubmit();
  }

  // ─── Staged files ───
  function renderStaged() {
    el.stagedCard.style.display = S.stagedFiles.length ? "" : "none";
    el.stagedList.innerHTML = "";
    S.stagedFiles.forEach((f, idx) => {
      const div = document.createElement("div");
      div.className = "file-item";
      div.innerHTML = `
        <div class="file-ext ${f.ext}">${PrintFlow.esc(f.ext)}</div>
        <div class="file-info">
          <div class="file-name">${PrintFlow.esc(f.original_name)}</div>
          <div class="file-meta">${PrintFlow.formatBytes(f.file_size)}</div>
        </div>
        <button class="file-remove" data-idx="${idx}">&times;</button>
      `;
      el.stagedList.appendChild(div);
    });

    el.stagedList.querySelectorAll(".file-remove").forEach((btn) => {
      btn.addEventListener("click", () => {
        S.stagedFiles.splice(parseInt(btn.dataset.idx), 1);
        renderStaged();
        updateSubmit();
      });
    });
  }

  // ─── Submit ───
  function updateSubmit() {
    const hasFiles = S.stagedFiles.length > 0;
    const hasLoc = S.selectedLocation !== null;
    el.submitCard.style.display = hasFiles ? "" : "none";
    el.subBtn.disabled = !(hasFiles && hasLoc);
    el.subCount.textContent = S.stagedFiles.length;
    el.subDest.textContent = hasLoc ? S.locations[S.selectedLocation].name : "--";
    el.destInfo.textContent = hasLoc ? S.locations[S.selectedLocation].description : "";
  }

  el.subBtn.addEventListener("click", async () => {
    if (S.selectedLocation === null || !S.stagedFiles.length) return;
    const locName = S.locations[S.selectedLocation].name;
    const priority = el.bulkPriority.value;

    el.subBtn.disabled = true;
    el.subBtnText.style.display = "none";
    el.subBtnLoad.style.display = "";

    try {
      const tasks = S.stagedFiles.map((f) => ({
        stored_name: f.stored_name,
        priority,
      }));

      const res = await fetch("/api/jobs", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ location_id: S.selectedLocation, tasks }),
      });

      if (!res.ok) {
        PrintFlow.toast("Submit failed: " + (await res.text()), "error");
        return;
      }

      const data = await res.json();
      const totalEst = data.reduce((s, j) => s + j.est_time_sec, 0);
      PrintFlow.toast(data.length + " job(s) submitted ~ " + totalEst + "s estimated", "success");

      S.stagedFiles.forEach((f) => {
        PrintFlow.addTrackedJob(f.stored_name, f.original_name, f.ext, locName);
      });

      S.stagedFiles = [];
      renderStaged();
      updateSubmit();
      PrintFlow.loadLocations();
    } catch (e) {
      PrintFlow.toast("Submit error: " + e.message, "error");
    } finally {
      el.subBtn.disabled = false;
      el.subBtnText.style.display = "";
      el.subBtnLoad.style.display = "none";
      updateSubmit();
    }
  });

  // ─── Tracker ───
  const TRACKER_ICONS = {
    queued: '<svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><circle cx="8" cy="8" r="6"/><polyline points="8 4.5 8 8 11 10"/></svg>',
    printing: '<svg class="tracker-spinner" width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M8 2a6 6 0 0 1 6 6" stroke-linecap="round"/><circle cx="8" cy="8" r="6" opacity="0.2"/></svg>',
    done: '<svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3.5 8.5 6.5 11.5 12.5 4.5"/></svg>',
    failed: '<svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><line x1="4" y1="4" x2="12" y2="12"/><line x1="12" y1="4" x2="4" y2="12"/></svg>',
  };
  const TRACKER_LABELS = { queued: "Queued", printing: "Printing...", done: "Complete", failed: "Failed" };

  function renderTracker() {
    el.trackerCard.style.display = S.trackedJobs.length ? "" : "none";
    el.trackerList.innerHTML = "";
    S.trackedJobs.forEach((job) => {
      const div = document.createElement("div");
      div.className = "tracker-item s-" + job.status;
      div.innerHTML = `
        <div class="file-ext ${job.ext}">${PrintFlow.esc(job.ext)}</div>
        <div class="tracker-file">
          <div class="tracker-name">${PrintFlow.esc(job.original_name)}</div>
          <div class="tracker-dest">${PrintFlow.esc(job.location_name)}</div>
        </div>
        <div class="tracker-status">
          ${TRACKER_ICONS[job.status]}
          <span>${TRACKER_LABELS[job.status]}</span>
        </div>
      `;
      el.trackerList.appendChild(div);
    });
  }

  PrintFlow.on("trackerUpdate", renderTracker);

  // Initial render
  renderDestList();
  renderStaged();
  renderTracker();
  updateSubmit();
});
