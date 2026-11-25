(() => {
  const review = document.querySelector("[data-review-namespace]");
  if (!review) return;

  const namespace = `manyfold-duplicate-review:v1:${review.dataset.reviewNamespace}:`;
  const keyFor = (digest) => namespace + digest;

  function readDecision(digest) {
    try {
      const raw = localStorage.getItem(keyFor(digest));
      return raw ? JSON.parse(raw) : null;
    } catch {
      return null;
    }
  }

  function updateQueue() {
    const labels = { prefer: "Preference saved", keep: "Keep all saved", later: "Review later" };
    for (const row of review.querySelectorAll("[data-review-digest]")) {
      const decision = readDecision(row.dataset.reviewDigest);
      const status = row.querySelector("[data-queue-status]");
      status.textContent = Object.hasOwn(labels, decision?.type) ? labels[decision.type] : "Open for review";
    }
  }

  function setupDecision() {
    const panel = review.querySelector("[data-decision-panel]");
    if (!panel) return () => {};

    const digest = review.dataset.groupDigest;
    const fingerprint = review.dataset.fingerprint;
    const preferred = panel.querySelector("#da-preferred");
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
        if (label) {
          status.textContent = `Preferred copy saved. ${label}`;
        } else {
          status.textContent = "A preferred copy from another page is saved.";
        }
      } else {
        status.textContent = decision.type === "keep" ? "Keep all copies saved." : "Marked for later review.";
      }
    }

    function save(type, copy = null) {
      try {
        localStorage.setItem(keyFor(digest), JSON.stringify({ type, copy, fingerprint }));
        refresh();
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
      } catch {
        status.textContent = "This browser could not clear your decision.";
      }
    });

    panel.hidden = false;
    return refresh;
  }

  for (const preview of review.querySelectorAll("[data-preview]")) {
    preview.addEventListener("toggle", () => {
      const template = preview.querySelector("template");
      if (!preview.open || !template) return;
      const frame = template.content.firstElementChild.cloneNode(true);
      frame.src = frame.dataset.previewUrl;
      template.replaceWith(frame);
    });
  }

  const refreshDecision = setupDecision();
  function refresh() {
    updateQueue();
    refreshDecision();
  }

  refresh();
  window.addEventListener("pageshow", refresh);
  window.addEventListener("storage", (event) => {
    if (event.key === null || event.key.startsWith(namespace)) refresh();
  });
})();
