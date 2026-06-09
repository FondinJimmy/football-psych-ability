/* Reads model results live from Supabase and renders metrics, charts and
   two interactive widgets (a what-if predictor and a position filter). */
(function () {
  const cfg = window.SUPABASE_CONFIG;
  const status = document.getElementById("status");

  // Repo link if hosted on github pages (owner.github.io/repo)
  const repoLink = document.getElementById("repo-link");
  const host = location.hostname.match(/^([^.]+)\.github\.io$/);
  if (host) {
    const repo = location.pathname.split("/").filter(Boolean)[0] || "";
    repoLink.href = `https://github.com/${host[1]}/${repo}`;
  } else {
    repoLink.href = "https://github.com/FondinJimmy/football-psych-ability";
  }

  if (!cfg || cfg.url.includes("YOURPROJECT")) {
    status.textContent = "Supabase config not set yet (copy config.example.js to config.js).";
    return;
  }

  const headers = { apikey: cfg.anonKey, Authorization: "Bearer " + cfg.anonKey };
  const api = (path) => fetch(cfg.url + "/rest/v1/" + path, { headers }).then((r) => r.json());

  // module-level state for the interactive scatter
  let allPreds = [];
  let scatterChart = null;

  Promise.all([
    api(`model_results?select=*`),
    api(`model_coefficients?run_id=eq.ols_v1&select=variable,estimate,importance`),
    api(`model_predictions?run_id=eq.ols_v1&select=actual,predicted,player_position&limit=4000`),
    api(`position_results?run_id=eq.ols_v1&select=position_group,n_obs,r_square&order=r_square.desc`),
  ])
    .then(([results, coefs, preds, positions]) => {
      const ols = results.find((r) => r.run_id === "ols_v1");
      const tree = results.find((r) => r.run_id === "tree_v1");
      if (!ols) {
        status.textContent = "No model results in Supabase yet. Run sas/model.sas to populate them.";
        return;
      }
      status.textContent = `Models fitted on ${ols.n_obs} players. Live from Supabase.`;
      renderCards(ols);
      renderCompare(ols, tree);
      renderCoef(coefs.filter((c) => c.importance != null));
      renderPredictor(coefs);
      allPreds = preds || [];
      renderScatter("ALL");
      document.getElementById("posFilter").addEventListener("change", (e) => renderScatter(e.target.value));
      renderPositions(positions);
      renderInterp(ols, tree, coefs, positions);
    })
    .catch((e) => { status.textContent = "Could not load results: " + e.message; });

  function renderCards(r) {
    const cards = [
      { lbl: "R² (OLS)", val: fmt(r.r_square) },
      { lbl: "Adj. R²", val: fmt(r.adj_r_square) },
      { lbl: "RMSE", val: fmt(r.rmse) },
      { lbl: "Players", val: r.n_obs },
    ];
    document.getElementById("metric-cards").innerHTML = cards
      .map((c) => `<div class="card"><div class="val">${c.val}</div><div class="lbl">${c.lbl}</div></div>`)
      .join("");
  }

  function renderCompare(ols, tree) {
    const rows = [{ name: "Linear regression (OLS)", r2: ols.r_square, c: "#4aa3ff" }];
    if (tree) rows.push({ name: "Decision tree", r2: tree.r_square, c: "#39d98a" });
    new Chart(document.getElementById("compareChart"), {
      type: "bar",
      data: { labels: rows.map((r) => r.name),
        datasets: [{ data: rows.map((r) => Number(r.r2)), backgroundColor: rows.map((r) => r.c) }] },
      options: { indexAxis: "y", plugins: { legend: { display: false },
        tooltip: { callbacks: { label: (x) => "R² = " + fmt(x.raw) } } },
        scales: { x: { min: 0, max: 1, ...axis() }, y: axis() } },
    });
  }

  function renderCoef(coefs) {
    if (!coefs.length) return;
    coefs.sort((a, b) => Number(b.importance) - Number(a.importance));
    const data = coefs.map((c) => Number(c.importance));
    new Chart(document.getElementById("coefChart"), {
      type: "bar",
      data: { labels: coefs.map((c) => pretty(c.variable)),
        datasets: [{ data, backgroundColor: data.map((v) => (v >= 0 ? "#39d98a" : "#ff6b6b")) }] },
      options: { indexAxis: "y", plugins: { legend: { display: false } }, scales: gridScales() },
    });
  }

  // ---- Interactive what-if predictor -------------------------------------
  function renderPredictor(coefs) {
    const intercept = Number((coefs.find((c) => c.variable.toLowerCase() === "intercept") || {}).estimate || 0);
    const terms = coefs.filter((c) => c.variable.toLowerCase() !== "intercept");
    const el = document.getElementById("predictor");

    const sliders = terms.map((c) => {
      const id = "s_" + c.variable;
      return `<div class="slider-row">
        <label for="${id}">${pretty(c.variable)}</label>
        <input type="range" id="${id}" min="0" max="99" value="60" data-est="${c.estimate}" />
        <output id="${id}_v">60</output>
      </div>`;
    }).join("");

    el.innerHTML = sliders +
      `<div class="predict-out">Predicted overall: <span id="predValue">--</span></div>`;

    function recompute() {
      let pred = intercept;
      terms.forEach((c) => {
        const s = document.getElementById("s_" + c.variable);
        document.getElementById("s_" + c.variable + "_v").textContent = s.value;
        pred += Number(s.dataset.est) * Number(s.value);
      });
      pred = Math.max(1, Math.min(99, pred));
      document.getElementById("predValue").textContent = pred.toFixed(1);
    }
    el.querySelectorAll("input[type=range]").forEach((s) => s.addEventListener("input", recompute));
    recompute();
  }

  // ---- Position-filtered scatter -----------------------------------------
  function renderScatter(group) {
    const rows = group === "ALL" ? allPreds : allPreds.filter((p) => p.player_position === group);
    const pts = rows.map((p) => ({ x: Number(p.actual), y: Number(p.predicted) }));
    if (!pts.length) return;
    const lo = Math.min(...pts.map((p) => p.x)) - 2;
    const hi = Math.max(...pts.map((p) => p.x)) + 2;
    const data = {
      datasets: [
        { label: "Players", data: pts, backgroundColor: "rgba(74,163,255,.35)", pointRadius: 2 },
        { label: "Perfect", type: "line", data: [{ x: lo, y: lo }, { x: hi, y: hi }],
          borderColor: "#ffcf6b", borderDash: [6, 6], pointRadius: 0, borderWidth: 1.5 },
      ],
    };
    if (scatterChart) { scatterChart.data = data; scatterChart.update(); return; }
    scatterChart = new Chart(document.getElementById("scatterChart"), {
      type: "scatter", data,
      options: { animation: false, plugins: { legend: { labels: { color: "#9fb0c0" } } },
        scales: {
          x: { title: { display: true, text: "Actual overall", color: "#9fb0c0" }, ...axis() },
          y: { title: { display: true, text: "Predicted overall", color: "#9fb0c0" }, ...axis() },
        } },
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
      `The profile predicts <strong>${(names[best.position_group] || best.position_group).toLowerCase()}</strong> ` +
      `best (R² = ${fmt(best.r_square)}) and <strong>${(names[worst.position_group] || worst.position_group).toLowerCase()}</strong> ` +
      `worst (R² = ${fmt(worst.r_square)}) — goalkeeping ability leans on a skill set these outfield-oriented mental traits capture least.`;
  }

  function renderInterp(ols, tree, coefs, positions) {
    const pct = Math.round(Number(ols.r_square) * 100);
    const top = coefs
      .filter((c) => c.importance != null)
      .sort((a, b) => Math.abs(b.importance) - Math.abs(a.importance))[0];
    const treeBit = tree
      ? ` A decision tree pushes that to ${Math.round(Number(tree.r_square) * 100)}% by capturing nonlinear patterns,`
      : "";
    document.getElementById("interp-text").innerHTML =
      `The psychological/mentality profile explains <strong>${pct}%</strong> of the ` +
      `variation in overall ability with a simple linear model (R² = ${fmt(ols.r_square)}).${treeBit} ` +
      `the strongest single driver being <strong>${top ? pretty(top.variable) : "reactions"}</strong>. ` +
      `The unexplained remainder reflects physique, technique and factors no mentality score captures.`;
  }

  const fmt = (v) => (v == null ? "—" : Number(v).toFixed(3));
  const pretty = (s) => s.replace(/^mentality_|^movement_/, "").replace(/_/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
  const axis = () => ({ ticks: { color: "#9fb0c0" }, grid: { color: "#26313d" } });
  const gridScales = () => ({ x: axis(), y: axis() });
})();
