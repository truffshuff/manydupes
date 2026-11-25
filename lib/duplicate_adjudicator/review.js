(() => {
  const review = document.querySelector("[data-review-namespace]");
  if (!review) return;

  const namespace = `manyfold-duplicate-review:v1:${review.dataset.reviewNamespace}:`;
  const keyFor = (digest) => namespace + digest;
  const decisionLabels = { prefer: "Preference saved", keep: "Keep all saved", later: "Review later" };
  const refreshers = new WeakMap();

  function readDecision(digest) {
    try {
      const raw = localStorage.getItem(keyFor(digest));
      return raw ? JSON.parse(raw) : null;
    } catch {
      return null;
    }
  }

  function updateQueue() {
    for (const row of review.querySelectorAll("[data-review-digest]")) {
      const decision = readDecision(row.dataset.reviewDigest);
      const status = row.querySelector("[data-queue-status]");
      const fingerprint = row.querySelector("[data-comparison]")?.dataset.fingerprint;
      const label = Object.hasOwn(decisionLabels, decision?.type) ? decisionLabels[decision.type] : "";
      status.textContent = decision && fingerprint && decision.fingerprint !== fingerprint ? "Review again" : label;
      status.hidden = !status.textContent;
    }
  }

  function initializeComparison(comparison) {
    const panel = comparison.querySelector("[data-decision-panel]");
    const { groupDigest: digest, fingerprint } = comparison.dataset;
    const preferred = panel.querySelector("[data-preferred-copy]");
    const form = panel.querySelector("[data-decision-form]");
    const status = panel.querySelector("[data-decision-status]");
    const clear = panel.querySelector("[data-clear-decision]");

    function refresh() {
      const decision = readDecision(digest);
      clear.hidden = !decision;

      if (!decision) {
        preferred.value = "";
        status.textContent = "No decision saved.";
        return;
      }

      if (decision.fingerprint !== fingerprint) {
        preferred.value = "";
        status.textContent = "The indexed copies have changed. Review this group again.";
        return;
      }

      preferred.value = decision.type === "prefer" ? decision.copy : "";
      const label = preferred.selectedOptions[0]?.textContent;
      if (decision.type === "prefer") {
        status.textContent = label ? `Preferred copy saved. ${label}` : "A preferred copy from another page is saved.";
      } else {
        status.textContent = decision.type === "keep" ? "Keep all copies saved." : "Marked for later review.";
      }
    }

    function save(type, copy = null) {
      try {
        localStorage.setItem(keyFor(digest), JSON.stringify({ type, copy, fingerprint }));
        refresh();
        updateQueue();
      } catch {
        status.textContent = "This browser could not save your decision.";
      }
    }

    form.addEventListener("submit", (event) => {
      event.preventDefault();
      if (preferred.value) {
        save("prefer", preferred.value);
      } else {
        status.textContent = "Choose the copy you want to prefer.";
        preferred.focus();
      }
    });
    for (const button of panel.querySelectorAll("[data-decision]")) {
      button.addEventListener("click", () => save(button.dataset.decision));
    }
    clear.addEventListener("click", () => {
      try {
        localStorage.removeItem(keyFor(digest));
        refresh();
        updateQueue();
      } catch {
        status.textContent = "This browser could not clear your decision.";
      }
    });

    for (const preview of comparison.querySelectorAll("[data-preview]")) {
      preview.addEventListener("toggle", () => {
        const template = preview.querySelector("template");
        if (!preview.open || !template) return;
        const frame = template.content.firstElementChild.cloneNode(true);
        frame.src = frame.dataset.previewUrl;
        template.replaceWith(frame);
      });
    }

    panel.hidden = false;
    refreshers.set(comparison, refresh);
    refresh();
  }

  async function loadComparison(row, destination, form = null, submitter = null) {
    if (row.dataset.loading) return;
    const url = new URL(destination, location.href);
    if (url.origin !== location.origin) return;
    url.searchParams.set("inline", "1");

    const content = row.querySelector("[data-group-content]");
    const hadComparison = Boolean(content.firstElementChild);
    const status = row.querySelector("[data-load-status]");
    const retry = row.querySelector("[data-retry]");
    const method = form?.method.toUpperCase() || "GET";
    let body;
    if (form) {
      const data = new FormData(form, submitter || undefined);
      const fields = new URLSearchParams(data);
      if (method === "GET") {
        for (const [key, value] of fields) url.searchParams.set(key, value);
      } else {
        body = fields;
      }
    }

    row.dataset.loading = "1";
    content.setAttribute("aria-busy", "true");
    status.textContent = hadComparison ? "Updating comparison…" : "Loading comparison…";
    status.hidden = false;
    retry.hidden = true;

    try {
      const response = await fetch(url, { method, body, credentials: "same-origin" });
      if (response.status === 409) {
        content.replaceChildren();
        status.textContent = "The indexed copies changed. Reload this comparison to review them again.";
        retry.hidden = false;
        return;
      }
      if (!response.ok || response.redirected) throw new Error("The comparison did not load.");

      const doc = new DOMParser().parseFromString(await response.text(), "text/html");
      const comparison = doc.querySelector("[data-comparison]");
      if (comparison?.dataset.groupDigest !== row.dataset.reviewDigest) throw new Error("Unexpected comparison response.");

      content.replaceChildren(comparison);
      initializeComparison(comparison);
      updateQueue();
      status.hidden = true;
      if (hadComparison && row.open) {
        (comparison.querySelector("[data-action-result]") || comparison).focus({ preventScroll: true });
      }
    } catch {
      status.textContent = "Could not load the comparison. Retry or open it on its own page.";
      retry.hidden = false;
    } finally {
      delete row.dataset.loading;
      content.removeAttribute("aria-busy");
    }
  }

  for (const row of review.querySelectorAll("[data-review-digest]")) {
    const open = () => {
      if (row.open && !row.querySelector("[data-comparison]")) loadComparison(row, row.dataset.groupUrl);
    };
    row.addEventListener("toggle", open);
    row.querySelector("[data-retry]").addEventListener("click", () => loadComparison(row, row.dataset.groupUrl));
    open();
  }

  review.addEventListener("submit", (event) => {
    const form = event.target;
    const row = form.closest("[data-review-digest]");
    if (!row || !form.matches("[data-inline-form]")) return;
    event.preventDefault();
    loadComparison(row, form.action, form, event.submitter);
  });

  review.addEventListener("click", (event) => {
    const link = event.target.closest("[data-inline-link]");
    const row = link?.closest("[data-review-digest]");
    if (!row || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    loadComparison(row, link.href);
  });

  for (const comparison of review.querySelectorAll("[data-comparison]")) initializeComparison(comparison);

  function refresh() {
    updateQueue();
    for (const comparison of review.querySelectorAll("[data-comparison]")) refreshers.get(comparison)?.();
  }

  refresh();
  window.addEventListener("pageshow", refresh);
  window.addEventListener("storage", (event) => {
    if (event.key === null || event.key.startsWith(namespace)) refresh();
  });
})();
