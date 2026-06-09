/* Reads model results live from Supabase and renders the psychology vs technique
   vs physique analysis, plus an interactive what-if predictor and position filter. */
(function () {
  const cfg = window.SUPABASE_CONFIG;
  const status = document.getElementById("status");
  const COLORS = { psychological: "#39d98a", technical: "#4aa3ff", physical: "#ffb347" };

  const repoLink = document.getElementById("repo-link");
  const hostm = location.hostname.match(/^([^.]+)\.github\.io$/);
  repoLink.href = hostm
    ? `https://github.com/${hostm[1]}/${(location.pathname.split("/").filter(Boolean)[0] || "")}`
    : "https://github.com/FondinJimmy/football-psych-ability";

  if (!cfg || cfg.url.includes("YOURPROJECT")) {
    status.textContent = "Supabase config not set yet (copy config.example.js to config.js).";
    return;
  }
  const headers = { apikey: cfg.anonKey, Authorization: "Bearer " + cfg.anonKey };
  const api = (p) => fetch(cfg.url + "/rest/v1/" + p, { headers }).then((r) => r.json());

  let allPreds = [], scatterChart = null;

  Promise.all([
    api(`model_results?select=*`),
    api(`model_coefficients?run_id=eq.full_v2&select=variable,group,estimate,importance,p_value`),
    api(`model_predictions?run_id=eq.full_v2&select=actual,predicted,player_position&limit=4000`),
    api(`position_results?run_id=eq.full_v2&select=position_group,n_obs,r_square&order=r_square.desc`),
  ])
    .then(([results, coefs, preds, positions]) => {
      const byId = Object.fromEntries(results.map((r) => [r.run_id, r]));
      const full = byId.full_v2;
      if (!full) { status.textContent = "No full-model results yet. Run sas/model.sas."; return; }
      status.textContent = `Full model fitted on ${full.n_obs} players. Live from Supabase.`;
      renderCards(full);
      renderGroups(byId);
      renderCoef(coefs.filter((c) => c.importance != null));
      renderPredictor(coefs);
      allPreds = preds || [];
      renderScatter("ALL");
      document.getElementById("posFilter").addEventListener("change", (e) => renderScatter(e.target.value));
      renderPositions(positions);
      renderInterp(byId, coefs, positions);
    })
    .catch((e) => { status.textContent = "Could not load results: " + e.message; });

  function renderCards(r) {
    const cards = [
      { lbl: "R² (full)", val: fmt(r.r_square) },
      { lbl: "Adj. R²", val: fmt(r.adj_r_square) },
      { lbl: "RMSE", val: fmt(r.rmse) },
      { lbl: "Predictors", val: 29 },
    ];
    document.getElementById("metric-cards").innerHTML = cards
      .map((c) => `<div class="card"><div class="val">${c.val}</div><div class="lbl">${c.lbl}</div></div>`).join("");
  }

  function renderGroups(byId) {
    const rows = [
      { name: "Psychological only", id: "psych_v2", c: COLORS.psychological },
      { name: "Technical only", id: "tech_v2", c: COLORS.technical },
      { name: "Physical only", id: "phys_v2", c: COLORS.physical },
      { name: "All groups (full)", id: "full_v2", c: "#cdd7e1" },
      { name: "Decision tree", id: "fulltree_v2", c: "#8b95a1" },
    ].filter((r) => byId[r.id]);
    new Chart(document.getElementById("groupChart"), {
      type: "bar",
      data: { labels: rows.map((r) => r.name),
        datasets: [{ data: rows.map((r) => Number(byId[r.id].r_square)), backgroundColor: rows.map((r) => r.c) }] },
      options: { indexAxis: "y", plugins: { legend: { display: false },
        tooltip: { callbacks: { label: (x) => "R² = " + fmt(x.raw) } } },
        scales: { x: { min: 0, max: 1, ...axis() }, y: axis() } },
    });
    const g = (id) => Math.round(Number(byId[id].r_square) * 100);
    document.getElementById("group-text").innerHTML =
      `Alone, the psychological group explains <strong>${g("psych_v2")}%</strong> of ability, ` +
      `technique <strong>${g("tech_v2")}%</strong> and physique <strong>${g("phys_v2")}%</strong>. ` +
      `All 29 together reach <strong>${g("full_v2")}%</strong> — only a little above psychology alone, ` +
      `because the groups overlap heavily.`;
  }

  function renderCoef(coefs) {
    if (!coefs.length) return;
    coefs.sort((a, b) => Math.abs(b.importance) - Math.abs(a.importance));
    new Chart(document.getElementById("coefChart"), {
      type: "bar",
      data: { labels: coefs.map((c) => pretty(c.variable)),
        datasets: [{ data: coefs.map((c) => Number(c.importance)),
          backgroundColor: coefs.map((c) => COLORS[c.group] || "#888") }] },
      options: { indexAxis: "y", plugins: { legend: { display: false },
        tooltip: { callbacks: { label: (x) => "β = " + x.raw.toFixed(3) } } },
        scales: gridScales() },
    });
  }

  function renderPredictor(coefs) {
    const intercept = Number((coefs.find((c) => c.variable.toLowerCase() === "intercept") || {}).estimate || 0);
    const terms = coefs.filter((c) => c.variable.toLowerCase() !== "intercept");
    const order = ["psychological", "technical", "physical"];
    const el = document.getElementById("predictor");
    let html = "";
    order.forEach((grp) => {
      const items = terms.filter((c) => c.group === grp);
      if (!items.length) return;
      html += `<h4 class="g-${grp.slice(0,4)} pred-head">${grp[0].toUpperCase() + grp.slice(1)}</h4>`;
      html += items.map((c) => {
        const id = "s_" + c.variable;
        return `<div class="slider-row"><label for="${id}">${pretty(c.variable)}</label>
          <input type="range" id="${id}" min="0" max="99" value="60" data-est="${c.estimate}" />
          <output id="${id}_v">60</output></div>`;
      }).join("");
    });
    html += `<div class="predict-out">Predicted overall: <span id="predValue">--</span></div>`;
    el.innerHTML = html;

    function recompute() {
      let pred = intercept;
      terms.forEach((c) => {
        const s = document.getElementById("s_" + c.variable);
        document.getElementById("s_" + c.variable + "_v").textContent = s.value;
        pred += Number(s.dataset.est) * Number(s.value);
      });
      document.getElementById("predValue").textContent = Math.max(1, Math.min(99, pred)).toFixed(1);
    }
    el.querySelectorAll("input[type=range]").forEach((s) => s.addEventListener("input", recompute));
    recompute();
  }

  function renderScatter(group) {
    const rows = group === "ALL" ? allPreds : allPreds.filter((p) => p.player_position === group);
    const pts = rows.map((p) => ({ x: Number(p.actual), y: Number(p.predicted) }));
    if (!pts.length) return;
    const lo = Math.min(...pts.map((p) => p.x)) - 2, hi = Math.max(...pts.map((p) => p.x)) + 2;
    const data = { datasets: [
      { label: "Players", data: pts, backgroundColor: "rgba(74,163,255,.35)", pointRadius: 2 },
      { label: "Perfect", type: "line", data: [{ x: lo, y: lo }, { x: hi, y: hi }],
        borderColor: "#ffcf6b", borderDash: [6, 6], pointRadius: 0, borderWidth: 1.5 } ] };
    if (scatterChart) { scatterChart.data = data; scatterChart.update(); return; }
    scatterChart = new Chart(document.getElementById("scatterChart"), {
      type: "scatter", data,
      options: { animation: false, plugins: { legend: { labels: { color: "#9fb0c0" } } },
        scales: { x: { title: { display: true, text: "Actual overall", color: "#9fb0c0" }, ...axis() },
                  y: { title: { display: true, text: "Predicted overall", color: "#9fb0c0" }, ...axis() } } },
    });
  }

  function renderPositions(positions) {
    if (!positions || !positions.length) return;
    const names = { GK: "Goalkeepers", DEF: "Defenders", MID: "Midfielders", FWD: "Forwards" };
    new Chart(document.getElementById("positionChart"), {
      type: "bar",
      data: { labels: positions.map((p) => names[p.position_group] || p.position_group),
        datasets: [{ data: positions.map((p) => Number(p.r_square)), backgroundColor: "#4aa3ff" }] },
      options: { plugins: { legend: { display: false },
        tooltip: { callbacks: { label: (x) => "R² = " + fmt(x.raw) } } },
        scales: { y: { min: 0, max: 1, ...axis() }, x: axis() } },
    });
    const best = positions[0], worst = positions[positions.length - 1];
    document.getElementById("position-text").innerHTML =
      `With all attributes the model fits every position well — best for ` +
      `<strong>${(names[best.position_group] || "").toLowerCase()}</strong> (R² = ${fmt(best.r_square)}) ` +
      `and lowest for <strong>${(names[worst.position_group] || "").toLowerCase()}</strong> (R² = ${fmt(worst.r_square)}).`;
  }

  function renderInterp(byId, coefs, positions) {
    const pct = (id) => Math.round(Number(byId[id].r_square) * 100);
    const top = coefs.filter((c) => c.importance != null)
      .sort((a, b) => Math.abs(b.importance) - Math.abs(a.importance))[0];
    document.getElementById("interp-text").innerHTML =
      `Standalone, the psychological group explains <strong>${pct("psych_v2")}%</strong> of ability — ` +
      `more than technique (${pct("tech_v2")}%) or physique (${pct("phys_v2")}%). Combining all 29 attributes ` +
      `reaches <strong>${pct("full_v2")}%</strong>, and the single most valuable variable across the board is ` +
      `<strong>${top ? pretty(top.variable) : "reactions"}</strong>.`;
  }

  const fmt = (v) => (v == null ? "—" : Number(v).toFixed(3));
  const pretty = (s) => s.replace(/^(mentality|movement|attacking|skill|power|defending)_/, "")
    .replace(/_/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
  const axis = () => ({ ticks: { color: "#9fb0c0" }, grid: { color: "#26313d" } });
  const gridScales = () => ({ x: axis(), y: axis() });
})();
