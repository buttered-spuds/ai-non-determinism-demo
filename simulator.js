// simulator.js
// UI logic for the AI Nondeterminism Simulator

(function () {
  "use strict";

  // ─── State ──────────────────────────────────────────────────────────────────
  let mainHistory = [];       // All outputs shown in the main demo grid
  let hallucinationLog = [];  // All hallucination outputs shown

  // ─── Helpers ────────────────────────────────────────────────────────────────

  /** Return a pool (low / medium / high) based on the slider value 0–100 */
  function getPool(sliderValue) {
    if (sliderValue <= 33) return RESPONSES.main.low;
    if (sliderValue <= 66) return RESPONSES.main.medium;
    return RESPONSES.main.high;
  }

  /** Pick a random item from an array */
  function randomFrom(arr) {
    return arr[Math.floor(Math.random() * arr.length)];
  }

  /** Similarity badge HTML */
  function similarityBadge(similarity) {
    const map = {
      equivalent: { emoji: "🟢", label: "Semantically equivalent", cls: "badge-green" },
      similar:    { emoji: "🟡", label: "Similar but different phrasing", cls: "badge-yellow" },
      divergent:  { emoji: "🔴", label: "Significantly different", cls: "badge-red" },
    };
    const s = map[similarity] || map.similar;
    return `<span class="badge ${s.cls}" title="${s.label}">${s.emoji} ${s.label}</span>`;
  }

  /** Build an output card element */
  function buildCard(item, index, total) {
    const card = document.createElement("div");
    card.className = "output-card";
    card.style.animationDelay = `${index * 60}ms`;
    card.innerHTML = `
      <div class="card-header">
        <span class="card-label">Output ${index + 1}${total > 1 ? ` of ${total}` : ""}</span>
        ${similarityBadge(item.similarity)}
      </div>
      <blockquote class="card-text">"${item.text}"</blockquote>
    `;
    return card;
  }

  /** Build a hallucination card element */
  function buildHallucinationCard(item, index) {
    const labelMap = {
      correct:       { cls: "h-correct",    icon: "✅", text: "Correct" },
      "wrong-detail":{ cls: "h-wrong",      icon: "⚠️", text: "Subtly wrong" },
      misleading:    { cls: "h-misleading", icon: "🟠", text: "Misleading" },
      "wrong-concept":{ cls: "h-wrong",     icon: "❌", text: "Wrong concept" },
    };
    const l = labelMap[item.label] || labelMap.correct;
    const noteHtml = item.note
      ? `<p class="h-note"><strong>Note:</strong> ${item.note}</p>`
      : "";
    const card = document.createElement("div");
    card.className = `h-card ${l.cls}`;
    card.style.animationDelay = `${index * 80}ms`;
    card.innerHTML = `
      <div class="card-header">
        <span class="card-label">Attempt ${index + 1}</span>
        <span class="badge ${l.cls}-badge">${l.icon} ${l.text}</span>
      </div>
      <blockquote class="card-text">"${item.text}"</blockquote>
      ${noteHtml}
    `;
    return card;
  }

  /** Render all cards in mainHistory into the grid */
  function renderMainGrid() {
    const grid = document.getElementById("output-grid");
    grid.innerHTML = "";
    if (mainHistory.length === 0) {
      grid.innerHTML = `<p class="placeholder-text">Hit <strong>Run Prompt</strong> to see the AI respond…</p>`;
      return;
    }
    mainHistory.forEach((item, i) => {
      grid.appendChild(buildCard(item, i, mainHistory.length));
    });
    // Scroll grid into view smoothly
    grid.scrollIntoView({ behavior: "smooth", block: "nearest" });
  }

  /** Render all hallucination cards */
  function renderHallucinationGrid() {
    const grid = document.getElementById("hallucination-grid");
    grid.innerHTML = "";
    if (hallucinationLog.length === 0) {
      grid.innerHTML = `<p class="placeholder-text">Hit <strong>Ask the AI</strong> to see responses…</p>`;
      return;
    }
    hallucinationLog.forEach((item, i) => {
      grid.appendChild(buildHallucinationCard(item, i));
    });
    grid.scrollIntoView({ behavior: "smooth", block: "nearest" });
  }

  /** Update the temperature label */
  function updateTempLabel(value) {
    const pct = parseInt(value, 10);
    let label = "🥶 Deterministic";
    if (pct > 66) label = "🔥 Creative";
    else if (pct > 33) label = "😐 Balanced";
    document.getElementById("temp-label").textContent = label;
    document.getElementById("temp-value").textContent = (pct / 100).toFixed(2);
  }

  // ─── Event wiring ────────────────────────────────────────────────────────────

  function init() {
    // Temperature slider
    const slider = document.getElementById("temperature-slider");
    slider.addEventListener("input", () => updateTempLabel(slider.value));
    updateTempLabel(slider.value);

    // Run once
    document.getElementById("btn-run-once").addEventListener("click", () => {
      const pool = getPool(parseInt(slider.value, 10));
      mainHistory = [randomFrom(pool)];
      renderMainGrid();
    });

    // Run 10 times
    document.getElementById("btn-run-ten").addEventListener("click", () => {
      const pool = getPool(parseInt(slider.value, 10));
      mainHistory = Array.from({ length: 10 }, () => randomFrom(pool));
      renderMainGrid();
    });

    // Clear main
    document.getElementById("btn-clear-main").addEventListener("click", () => {
      mainHistory = [];
      renderMainGrid();
    });

    // Hallucination demo
    document.getElementById("btn-hallucination").addEventListener("click", () => {
      const pool = RESPONSES.hallucination.responses;
      const item = randomFrom(pool);
      hallucinationLog.unshift(item); // newest first
      renderHallucinationGrid();
    });

    // Clear hallucination
    document.getElementById("btn-clear-hallucination").addEventListener("click", () => {
      hallucinationLog = [];
      renderHallucinationGrid();
    });

    // Traditional vs AI toggle
    document.querySelectorAll(".toggle-btn").forEach((btn) => {
      btn.addEventListener("click", () => {
        document.querySelectorAll(".toggle-btn").forEach((b) => b.classList.remove("active"));
        btn.classList.add("active");
        const target = btn.dataset.target;
        document.querySelectorAll(".test-panel").forEach((p) => {
          p.classList.toggle("hidden", p.id !== target);
        });
      });
    });

    // Cheat sheet accordion
    document.querySelectorAll(".cheat-toggle").forEach((btn) => {
      btn.addEventListener("click", () => {
        const body = btn.nextElementSibling;
        const isOpen = !body.classList.contains("hidden");
        body.classList.toggle("hidden", isOpen);
        btn.querySelector(".chevron").textContent = isOpen ? "▸" : "▾";
        btn.setAttribute("aria-expanded", String(!isOpen));
      });
    });

    // Initial placeholder renders
    renderMainGrid();
    renderHallucinationGrid();
  }

  document.addEventListener("DOMContentLoaded", init);
})();
