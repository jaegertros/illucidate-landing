import {
  computeDerivedSeries,
  computeWellFeatures,
  rankFeaturesByComparison,
  computeDetectionScore,
  computeZStats,
  metricValue
} from "./analysis.js";
import {
  renderSeriesChart,
  renderFeatureChart,
  renderPlateHeatmap
} from "./charts.js";

const CONTROL_GROUP = "Control";
const METRIC_LABELS = {
  od600: "OD600",
  luminescence: "Luminescence (RLU)",
  ratio: "RLU/OD600"
};

const GROUP_COLOR_PALETTE = ["#4fc3b8", "#4d9fd1", "#f3cf73", "#ef8f8f", "#b2a3ff", "#8be48d"];

const dom = {
  metricButtons: Array.from(document.querySelectorAll("[data-metric]")),
  groupControls: document.getElementById("group-controls"),
  targetSelect: document.getElementById("target-group"),
  timeSlider: document.getElementById("time-slider"),
  timeValue: document.getElementById("time-value"),
  seriesChart: document.getElementById("series-chart"),
  featureChart: document.getElementById("feature-chart"),
  heatmapChart: document.getElementById("heatmap-chart")
};

const app = {
  data: null,
  featureRows: [],
  groups: [],
  colorByGroup: new Map(),
  state: {
    metric: "od600",
    visibleGroups: new Set(),
    targetGroup: null,
    timeIndex: 0
  }
};

function setMetricButtonState(metric) {
  for (const button of dom.metricButtons) {
    const isActive = button.dataset.metric === metric;
    button.classList.toggle("is-active", isActive);
    button.setAttribute("aria-checked", String(isActive));
  }
}

function rowIndexFromWell(well) {
  if (!well || typeof well !== "string") {
    return 0;
  }
  const rowChar = well[0].toUpperCase();
  return Math.max(0, Math.min(7, rowChar.charCodeAt(0) - 65));
}

function colIndexFromWell(well) {
  if (!well || typeof well !== "string") {
    return 0;
  }
  const col = Number.parseInt(well.slice(1), 10);
  if (!Number.isFinite(col)) {
    return 0;
  }
  return Math.max(0, Math.min(11, col - 1));
}

function renderGroupControls() {
  dom.groupControls.replaceChildren();
  const fragment = document.createDocumentFragment();
  for (const group of app.groups) {
    const id = `group-${group.toLowerCase().replace(/\s+/g, "-")}`;

    const label = document.createElement("label");
    label.className = "group-option";
    label.setAttribute("for", id);

    const checkbox = document.createElement("input");
    checkbox.type = "checkbox";
    checkbox.id = id;
    checkbox.value = group;
    checkbox.checked = app.state.visibleGroups.has(group);
    checkbox.addEventListener("change", () => {
      if (checkbox.checked) {
        app.state.visibleGroups.add(group);
      } else {
        app.state.visibleGroups.delete(group);
      }
      syncTargetOptions();
      renderAll();
    });

    const swatch = document.createElement("span");
    swatch.setAttribute("aria-hidden", "true");
    swatch.style.width = "8px";
    swatch.style.height = "8px";
    swatch.style.borderRadius = "999px";
    swatch.style.display = "inline-block";
    swatch.style.background = app.colorByGroup.get(group) || "#aac0c9";

    const text = document.createElement("span");
    text.textContent = group;

    label.append(checkbox, swatch, text);
    fragment.appendChild(label);
  }
  dom.groupControls.appendChild(fragment);
}

function syncTargetOptions() {
  const visibleTargets = app.groups.filter(
    (group) => group !== CONTROL_GROUP && app.state.visibleGroups.has(group)
  );

  dom.targetSelect.replaceChildren();

  if (!visibleTargets.length) {
    const option = document.createElement("option");
    option.value = "";
    option.textContent = "No target available";
    dom.targetSelect.appendChild(option);
    dom.targetSelect.disabled = true;
    app.state.targetGroup = null;
    return;
  }

  dom.targetSelect.disabled = false;
  for (const group of visibleTargets) {
    const option = document.createElement("option");
    option.value = group;
    option.textContent = group;
    dom.targetSelect.appendChild(option);
  }

  if (!visibleTargets.includes(app.state.targetGroup)) {
    app.state.targetGroup = visibleTargets[0];
  }
  dom.targetSelect.value = app.state.targetGroup;
}

function updateTimeLabel() {
  const rawSeconds = app.data?.time?.[app.state.timeIndex] ?? 0;
  const hours = rawSeconds / 3600;
  dom.timeValue.textContent = `${hours.toFixed(2)} h`;
}

function buildHeatmapModel() {
  const activeWells = app.data.wells.filter((well) => app.state.visibleGroups.has(well.group));
  const zStats = computeZStats(activeWells, app.state.metric, app.state.timeIndex);

  const cells = app.data.wells.map((well) => {
    const active = app.state.visibleGroups.has(well.group);
    const score = active
      ? computeDetectionScore(well, app.state.metric, app.state.timeIndex, zStats)
      : NaN;
    return {
      well: well.well,
      group: well.group,
      row: rowIndexFromWell(well.well),
      col: colIndexFromWell(well.well),
      active,
      value: metricValue(well, app.state.metric, app.state.timeIndex),
      score
    };
  });

  const timeLabel = `${((app.data.time[app.state.timeIndex] || 0) / 3600).toFixed(2)} h`;
  return {
    cells,
    metricLabel: METRIC_LABELS[app.state.metric],
    timeLabel
  };
}

function buildSeriesModel() {
  const visibleWells = app.data.wells.filter((well) => app.state.visibleGroups.has(well.group));
  return {
    timeHours: app.data.time.map((seconds) => seconds / 3600),
    data: computeDerivedSeries(visibleWells, app.state.metric),
    colorByGroup: app.colorByGroup,
    metricLabel: METRIC_LABELS[app.state.metric]
  };
}

function buildRanking() {
  if (!app.state.targetGroup) {
    return [];
  }
  if (!app.state.visibleGroups.has(CONTROL_GROUP) || !app.state.visibleGroups.has(app.state.targetGroup)) {
    return [];
  }

  const visibleFeatureRows = app.featureRows.filter((row) => app.state.visibleGroups.has(row.group));
  return rankFeaturesByComparison(visibleFeatureRows, CONTROL_GROUP, app.state.targetGroup);
}

function renderAll() {
  if (!app.data) {
    return;
  }
  updateTimeLabel();
  setMetricButtonState(app.state.metric);

  const seriesModel = buildSeriesModel();
  const ranking = buildRanking();
  const heatmapModel = buildHeatmapModel();
  const hiddenGroupsCount = app.groups.filter((group) => !app.state.visibleGroups.has(group)).length;

  try {
    renderSeriesChart(dom.seriesChart, seriesModel, { focusGroup: app.state.targetGroup });
  } catch (error) {
    dom.seriesChart.innerHTML = `<p class="empty-state">Series chart error: ${error.message}</p>`;
  }

  try {
    renderFeatureChart(dom.featureChart, ranking, { targetGroup: app.state.targetGroup });
  } catch (error) {
    dom.featureChart.innerHTML = `<p class="empty-state">Feature chart error: ${error.message}</p>`;
  }

  try {
    renderPlateHeatmap(dom.heatmapChart, heatmapModel, { hiddenGroupsCount });
  } catch (error) {
    dom.heatmapChart.innerHTML = `<p class="empty-state">Heatmap error: ${error.message}</p>`;
  }
}

function exposeDebugSnapshot() {
  const anchorWell = app.data.wells.find((well) => well.group === CONTROL_GROUP) || app.data.wells[0];
  const anchorFeatures = computeWellFeatures(anchorWell, app.data.time);
  const ranking = rankFeaturesByComparison(app.featureRows, CONTROL_GROUP, app.state.targetGroup || app.groups[1] || CONTROL_GROUP);

  const snapshot = {
    baseline_mean: anchorFeatures.baseline_mean,
    early_slope: anchorFeatures.early_slope,
    time_to_1p2x: anchorFeatures.time_to_1p2x,
    top_features: ranking.slice(0, 5).map((entry) => entry.feature)
  };

  globalThis.__illucidateTest = {
    snapshot,
    assert() {
      const fresh = computeWellFeatures(anchorWell, app.data.time);
      const ok =
        Math.abs(fresh.baseline_mean - snapshot.baseline_mean) < 1e-12 &&
        Math.abs(fresh.early_slope - snapshot.early_slope) < 1e-12 &&
        fresh.time_to_1p2x === snapshot.time_to_1p2x;
      return {
        pass: ok,
        snapshot,
        fresh: {
          baseline_mean: fresh.baseline_mean,
          early_slope: fresh.early_slope,
          time_to_1p2x: fresh.time_to_1p2x
        }
      };
    }
  };
}

function bindEvents() {
  for (const button of dom.metricButtons) {
    button.addEventListener("click", () => {
      app.state.metric = button.dataset.metric;
      renderAll();
    });
  }

  dom.targetSelect.addEventListener("change", () => {
    app.state.targetGroup = dom.targetSelect.value || null;
    renderAll();
  });

  dom.timeSlider.addEventListener("input", () => {
    app.state.timeIndex = Number.parseInt(dom.timeSlider.value, 10) || 0;
    renderAll();
  });

  let resizeTimer = null;
  window.addEventListener("resize", () => {
    if (resizeTimer) {
      window.clearTimeout(resizeTimer);
    }
    resizeTimer = window.setTimeout(renderAll, 140);
  });
}

function validateDatasetSchema(dataset) {
  if (!dataset || !Array.isArray(dataset.time) || !Array.isArray(dataset.wells)) {
    throw new Error("Invalid dataset schema: expected { time: number[], wells: [] }");
  }
  if (!dataset.wells.length) {
    throw new Error("Dataset contains no wells.");
  }
}

async function bootstrap() {
  try {
    const response = await fetch("data/demo-dataset.json");
    if (!response.ok) {
      throw new Error(`Failed to load demo data (${response.status})`);
    }
    const dataset = await response.json();
    validateDatasetSchema(dataset);

    app.data = dataset;
    app.groups = dataset.meta?.groups || Array.from(new Set(dataset.wells.map((well) => well.group)));
    app.groups.forEach((group, index) => app.colorByGroup.set(group, GROUP_COLOR_PALETTE[index % GROUP_COLOR_PALETTE.length]));
    app.state.visibleGroups = new Set(app.groups);
    app.state.targetGroup = app.groups.find((group) => group !== CONTROL_GROUP) || null;
    app.state.timeIndex = Math.min(6, Math.max(dataset.time.length - 1, 0));
    app.featureRows = app.data.wells.map((well) => computeWellFeatures(well, app.data.time));

    renderGroupControls();
    syncTargetOptions();
    dom.timeSlider.max = String(Math.max(dataset.time.length - 1, 0));
    dom.timeSlider.value = String(app.state.timeIndex);
    bindEvents();
    exposeDebugSnapshot();
    renderAll();

    requestAnimationFrame(() => {
      document.body.classList.add("is-ready");
    });
  } catch (error) {
    const message = `Unable to initialize dashboard: ${error.message}`;
    dom.seriesChart.innerHTML = `<p class="empty-state">${message}</p>`;
    dom.featureChart.innerHTML = `<p class="empty-state">${message}</p>`;
    dom.heatmapChart.innerHTML = `<p class="empty-state">${message}</p>`;
    document.body.classList.add("is-ready");
    console.error(error);
  }
}

bootstrap();
