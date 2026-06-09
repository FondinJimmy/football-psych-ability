/* Reads model results live from Supabase and renders metrics + charts. */
(function () {
  const cfg = window.SUPABASE_CONFIG;
  const status = document.getElementById("status");
  const RUN_ID = "ols_v1";

  // Set repo link if hosted on github pages (owner.github.io/repo)
  const repoLink = document.getElementById("repo-link");
  const m = location.hostname.match(/^([^.]+)\.github\.io$/);
  if (m) {
    const repo = location.pathname.split("/").filter(Boolean)[0] || "";
    repoLink.href = `https://github.com/${m[1]}/${repo}`;
  } else {
    repoLink.href = "https://github.com/";
  }

  if (!cfg || cfg.url.includes("YOURPROJECT")) {
    status.textContent =
      "Supabase config not set yet (copy config.example.js to config.js).";
    return;
  }

  const headers = { apikey: cfg.anonKey, Authorization: "Bearer " + cfg.anonKey };
  const api = (path) => fetch(cfg.url + "/rest/v1/" + path, { headers }).then((r) => r.json());

  Promise.all([
    api(`model_results?run_id=eq.${RUN_ID}`),
    api(`model_coefficients?run_id=eq.${RUN_ID}&order=importance.desc`),
    api(`model_predictions?run_id=eq.${RUN_ID}&limit=2000`),
  ])
    .then(([results, coefs, preds]) => {
      if (!results || !results.length) {
        status.textContent =
          "No model results in Supabase yet. Run sas/model.sas to populate them.";
        return;
      }
      const r = results[0];
      status.textContent = `Model: ${r.model_name} — fitted on ${r.n_obs} players.`;
      renderCards(r);
      renderCoef(coefs);
      renderScatter(preds);
      renderInterp(r, coefs);
    })
    .catch((e) => {
      status.textContent = "Could not load results: " + e.message;
    });

  function renderCards(r) {
    const cards = [
      { lbl: "R²", val: fmt(r.r_square) },
      { lbl: "Adj. R²", val: fmt(r.adj_r_square) },
      { lbl: "RMSE", val: fmt(r.rmse) },
      { lbl: "Players", val: r.n_obs },
    ];
    document.getElementById("metric-cards").innerHTML = cards
      .map((c) => `<div class="card"><div class="val">${c.val}</div><div class="lbl">${c.lbl}</div></div>`)
      .join("");
  }

  function renderCoef(coefs) {
    if (!coefs || !coefs.length) return;
    const labels = coefs.map((c) => pretty(c.variable));
    const data = coefs.map((c) => Number(c.importance));
    new Chart(document.getElementById("coefChart"), {
      type: "bar",
      data: {
        labels,
        datasets: [{
          label: "Coefficient",
          data,
          backgroundColor: data.map((v) => (v >= 0 ? "#39d98a" : "#ff6b6b")),
        }],
      },
      options: {
        indexAxis: "y",
        plugins: { legend: { display: false } },
        scales: gridScales(),
      },
    });
  }

  function renderScatter(preds) {
    if (!preds || !preds.length) return;
    const pts = preds.map((p) => ({ x: Number(p.actual), y: Number(p.predicted) }));
    const lo = Math.min(...pts.map((p) => p.x)) - 2;
    const hi = Math.max(...pts.map((p) => p.x)) + 2;
    new Chart(document.getElementById("scatterChart"), {
      type: "scatter",
      data: {
        datasets: [
          { label: "Players", data: pts, backgroundColor: "rgba(74,163,255,.35)", pointRadius: 2 },
          { label: "Perfect", type: "line", data: [{ x: lo, y: lo }, { x: hi, y: hi }],
            borderColor: "#ffcf6b", borderDash: [6, 6], pointRadius: 0, borderWidth: 1.5 },
        ],
      },
      options: {
        plugins: { legend: { labels: { color: "#9fb0c0" } } },
        scales: {
          x: { title: { display: true, text: "Actual overall", color: "#9fb0c0" }, ...axis() },
          y: { title: { display: true, text: "Predicted overall", color: "#9fb0c0" }, ...axis() },
        },
      },
    });
  }

  function renderInterp(r, coefs) {
    const pct = Math.round(Number(r.r_square) * 100);
    const top = coefs && coefs.length ? pretty(coefs[0].variable) : "the mentality profile";
    document.getElementById("interp-text").innerHTML =
      `The psychological/mentality profile explains <strong>${pct}%</strong> of the ` +
      `variation in overall ability (R² = ${fmt(r.r_square)}). The strongest single ` +
      `driver in the model is <strong>${top}</strong>. The remaining ${100 - pct}% reflects ` +
      `physique, technique and factors no mentality score captures.`;
  }

  const fmt = (v) => (v == null ? "—" : Number(v).toFixed(3));
  const pretty = (s) => s.replace(/^mentality_|^movement_/, "").replace(/_/g, " ")
    .replace(/\b\w/g, (c) => c.toUpperCase());
  const axis = () => ({ ticks: { color: "#9fb0c0" }, grid: { color: "#26313d" } });
  const gridScales = () => ({ x: axis(), y: axis() });
})();
