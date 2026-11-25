(() => {
  const review = document.querySelector("[data-review-namespace]");
  if (!review) return;

  const namespace = `manyfold-duplicate-review:v1:${review.dataset.reviewNamespace}:`;
  const keyFor = (digest) => namespace + digest;
  const copyKeyFor = (digest, copy) => `${namespace}copies:${digest}:${copy}`;
  const decisionLabels = { prefer: "Preference saved", keep: "Keep all saved", reviewed: "Reviewed", later: "Review later" };
  const refreshers = new WeakMap();

  const queue = review.querySelector("[data-review-queue]");
  const refillUrl = queue?.dataset.refillUrl;
  const pageSize = Number(queue?.dataset.pageSize);
  const nextPage = review.querySelector("[data-queue-next]");
  const queueLoading = review.querySelector("[data-queue-loading]");
  const queueError = review.querySelector("[data-queue-error]");
  const queueEmpty = review.querySelector("[data-queue-empty]");
  let nextAfter = queue?.dataset.nextAfter;
  let bufferedRows = [];
  let fillingQueue = false;
  let queueFailed = false;

  function readDecision(digest) {
    try {
      const raw = localStorage.getItem(keyFor(digest));
      return raw ? JSON.parse(raw) : null;
    } catch {
      return null;
    }
  }

  function browserAcknowledgments(digest, fingerprint, copies) {
    try {
      return new Set(copies.filter((copy) => localStorage.getItem(copyKeyFor(digest, copy)) === fingerprint));
    } catch {
      return new Set();
    }
  }

  function copyProgress(element, digest, fingerprint) {
    const state = JSON.parse(element.dataset.copyProgress || "null");
    if (!state) return { total: 0, acknowledged: 0, canAcknowledge: false, browserCopies: new Set() };

    const browserCopies = browserAcknowledgments(digest, fingerprint, state.unwarned);
    return {
      total: state.total,
      acknowledged: state.acknowledged + browserCopies.size,
      canAcknowledge: state.open > 0 || browserCopies.size < state.unwarned.length,
      browserCopies
    };
  }

  function applyWarningReceipt(comparison, digest, fingerprint) {
    if (!comparison.dataset.warningReceipt) return;

    const receipt = JSON.parse(comparison.dataset.warningReceipt);
    try {
      for (const copy of receipt.copies) {
        const key = copyKeyFor(digest, copy);
        if (receipt.action === "acknowledge") localStorage.setItem(key, fingerprint);
        else localStorage.removeItem(key);
      }

      const decision = readDecision(digest);
      if (decision?.fingerprint !== fingerprint) return;
      if (receipt.action === "acknowledge" && decision.type === "later") {
        const progress = copyProgress(comparison, digest, fingerprint);
        if (progress.acknowledged === progress.total) localStorage.removeItem(keyFor(digest));
      } else if (receipt.action === "reopen" && ["keep", "reviewed"].includes(decision.type)) {
        if (decision.copy) {
          localStorage.setItem(keyFor(digest), JSON.stringify({ ...decision, type: "prefer" }));
        } else {
          localStorage.removeItem(keyFor(digest));
        }
      }
    } catch {
      const feedback = comparison.querySelector("[data-copy-review-error]");
      feedback.textContent = "This browser could not save acknowledgments for copies without a Manyfold warning.";
      feedback.hidden = false;
    }
  }

  function refreshCopyReviews(comparison, digest, fingerprint) {
    const progress = copyProgress(comparison, digest, fingerprint);
    comparison.querySelector("[data-copy-acknowledgment-count]").textContent =
      `${progress.acknowledged} of ${progress.total} copies acknowledged`;
    const acknowledgeAll = comparison.querySelector('[data-group-copy-action="acknowledge"]');
    const reopenGroup = comparison.querySelector('[data-group-copy-action="reopen"]');
    if (acknowledgeAll) acknowledgeAll.hidden = !progress.canAcknowledge;
    if (reopenGroup) reopenGroup.hidden = progress.acknowledged === 0;

    for (const card of comparison.querySelectorAll('[data-copy-id][data-warning-state=""]')) {
      const acknowledged = progress.browserCopies.has(card.dataset.copyId);
      card.querySelector("[data-copy-warning-status]").textContent =
        acknowledged ? "Copy acknowledged in this browser" : "No Manyfold warning";
      const acknowledge = card.querySelector('[data-copy-warning-action="acknowledge"]');
      const reopen = card.querySelector('[data-copy-warning-action="reopen"]');
      if (acknowledge) acknowledge.hidden = acknowledged;
      if (reopen) reopen.hidden = !acknowledged;
    }
  }

  function updateQueueRow(row) {
    const decision = readDecision(row.dataset.reviewDigest);
    const comparison = row.querySelector("[data-comparison]");
    const fingerprint = comparison?.dataset.fingerprint || row.dataset.fingerprint;
    const progress = copyProgress(comparison || row, row.dataset.reviewDigest, fingerprint);
    const acknowledgmentLabel = progress.total > 1 && progress.acknowledged === progress.total ? "All copies acknowledged" : "";
    const serverLabel = (comparison?.dataset.reviewLabel ?? row.dataset.reviewLabel) || acknowledgmentLabel;
    const kind = decision?.fingerprint === fingerprint ? decision?.type : null;
    const localLabel = Object.hasOwn(decisionLabels, kind) ? decisionLabels[kind] : "";
    const complete = kind !== "later" && (serverLabel || kind === "keep" || kind === "reviewed");
    const status = row.querySelector("[data-queue-status]");
    status.textContent = kind === "later" ? localLabel : serverLabel || localLabel || (decision ? "Review again" : "");
    status.hidden = !status.textContent;
    row.querySelector("[data-open-label]").textContent = complete ? "Open comparison" : "Open for review";
    row.hidden = Boolean(refillUrl) && Boolean(complete) && !row.open;
  }

  function updateQueue() {
    if (!queue) return;

    for (const row of [...queue.children]) {
      updateQueueRow(row);
      if (row.hidden) row.remove();
    }
    if (!refillUrl) return;

    while (bufferedRows.length > 0) {
      const row = bufferedRows[0];
      updateQueueRow(row);
      if (!row.hidden && queue.childElementCount >= pageSize) break;

      bufferedRows.shift();
      if (!row.hidden) {
        initializeQueueRow(row);
        queue.append(row);
      }
    }

    if (nextPage) {
      nextPage.hidden = bufferedRows.length === 0;
      if (!nextPage.hidden) {
        const url = new URL(queue.dataset.pageUrl, location.href);
        url.searchParams.set("after", queue.lastElementChild.dataset.reviewDigest);
        nextPage.href = url.href;
      }
    }

    const moreToCheck = Boolean(nextAfter) && bufferedRows.length === 0;
    queueEmpty.hidden = queue.childElementCount > 0 || moreToCheck || queueFailed;
    queueLoading.hidden = !moreToCheck || queueFailed || queue.childElementCount >= pageSize;
    queueError.hidden = !queueFailed;
    if (moreToCheck && !fillingQueue && !queueFailed) refillQueue();
  }

  async function refillQueue() {
    fillingQueue = true;
    try {
      while (nextAfter && bufferedRows.length === 0) {
        const url = new URL(refillUrl, location.href);
        url.searchParams.set("after", nextAfter);
        const response = await fetch(url, { credentials: "same-origin", headers: { Accept: "text/html" } });
        if (!response.ok || response.redirected) throw new Error("Invalid queue response.");

        const doc = new DOMParser().parseFromString(await response.text(), "text/html");
        const batch = doc.querySelector("[data-queue-refill]");
        if (!batch || (batch.dataset.nextAfter && batch.dataset.nextAfter <= nextAfter)) {
          throw new Error("Queue cursor did not advance.");
        }

        bufferedRows = [...batch.children];
        nextAfter = batch.dataset.nextAfter;
        updateQueue();
      }
    } catch {
      queueFailed = true;
    } finally {
      fillingQueue = false;
      updateQueue();
    }
  }

  function initializeComparison(comparison) {
    const panel = comparison.querySelector("[data-decision-panel]");
    const { groupDigest: digest, fingerprint } = comparison.dataset;
    applyWarningReceipt(comparison, digest, fingerprint);
    const preferred = panel.querySelector("[data-preferred-copy]");
    const form = panel.querySelector("[data-decision-form]");
    const status = panel.querySelector("[data-decision-status]");
    const clear = panel.querySelector("[data-clear-decision]");

    function refresh() {
      refreshCopyReviews(comparison, digest, fingerprint);
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

      preferred.value = decision.copy || "";
      const label = preferred.selectedOptions[0]?.textContent;
      if (decision.type === "prefer") {
        status.textContent = label ? `Preferred copy saved. ${label}` : "A preferred copy from another page is saved.";
      } else if (decision.type === "reviewed") {
        status.textContent = label && decision.copy ? `Marked reviewed. Preferred copy: ${label}` : "Marked reviewed.";
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
      button.addEventListener("click", () => {
        const prior = readDecision(digest);
        const copy = button.dataset.decision === "reviewed" && prior?.fingerprint === fingerprint ? prior.copy : null;
        save(button.dataset.decision, copy);
      });
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

  async function loadComparison(row, destination, { form, submitter, scrollToPair = false } = {}) {
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
      const response = await fetch(url, {
        method,
        body,
        credentials: "same-origin",
        headers: { Accept: "text/html" }
      });
      if (response.status === 409) {
        content.replaceChildren();
        status.textContent = "The indexed copies changed. Reload this comparison to review them again.";
        retry.hidden = false;
        return;
      }
      if (!response.ok || response.redirected) {
        status.textContent = response.redirected
          ? "Manyfold redirected the request. Reload the queue and sign in if prompted."
          : `Manyfold returned HTTP ${response.status}. Retry or open the comparison on its own page.`;
        retry.hidden = false;
        return;
      }

      const doc = new DOMParser().parseFromString(await response.text(), "text/html");
      const comparison = doc.querySelector("[data-comparison]");
      if (comparison?.dataset.groupDigest !== row.dataset.reviewDigest) throw new Error("Unexpected comparison response.");

      content.replaceChildren(comparison);
      initializeComparison(comparison);
      updateQueue();
      status.hidden = true;
      if (hadComparison && row.open) {
        (comparison.querySelector("[data-action-result]") || comparison).focus({ preventScroll: !scrollToPair });
      }
    } catch {
      status.textContent = "Could not load the comparison. Retry or open it on its own page.";
      retry.hidden = false;
    } finally {
      delete row.dataset.loading;
      content.removeAttribute("aria-busy");
    }
  }

  function initializeQueueRow(row) {
    const open = () => {
      if (row.open) {
        if (!row.querySelector("[data-comparison]")) loadComparison(row, row.dataset.groupUrl);
        return;
      }

      const hadFocus = row.contains(document.activeElement);
      updateQueue();
      if (row.hidden && hadFocus) {
        const next = review.querySelector("[data-review-digest]:not([hidden]) > summary");
        (next || review.querySelector(".da-review-views [aria-current]"))?.focus();
      }
    };
    row.addEventListener("toggle", open);
    row.querySelector("[data-retry]").addEventListener("click", () => loadComparison(row, row.dataset.groupUrl));
    if (row.open) open();
  }

  for (const row of queue?.children || []) initializeQueueRow(row);
  review.querySelector("[data-queue-retry]")?.addEventListener("click", () => {
    queueFailed = false;
    updateQueue();
  });

  review.addEventListener("submit", (event) => {
    const form = event.target;
    const row = form.closest("[data-review-digest]");
    if (!row || !form.matches("[data-inline-form]")) return;
    event.preventDefault();
    loadComparison(row, form.action, { form, submitter: event.submitter });
  });

  review.addEventListener("click", (event) => {
    const link = event.target.closest("[data-inline-link]");
    const row = link?.closest("[data-review-digest]");
    if (!row || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    loadComparison(row, link.href, { scrollToPair: link.hasAttribute("data-scroll-to-pair") });
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
