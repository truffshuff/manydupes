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
    if (!state) return { total: 0, acknowledged: 0, browserCopies: new Set() };

    const saved = savedReview(element);
    const browserCopies = saved
      ? new Set(saved.fingerprint === fingerprint ? state.unwarned.filter((id) => saved.copies.includes(id)) : [])
      : browserAcknowledgments(digest, fingerprint, state.unwarned);
    return {
      total: state.total,
      acknowledged: state.acknowledged + browserCopies.size,
      browserCopies
    };
  }

  function savedReview(element) {
    return JSON.parse(element.dataset.savedReview || "null");
  }

  function reviewDecision(element, digest) {
    const state = savedReview(element);
    if (!state) return readDecision(digest);
    return state.decision ? { ...state.decision, fingerprint: state.fingerprint } : null;
  }

  async function importBrowserReviews() {
    const importedKey = namespace + "imported";
    try {
      if (localStorage.getItem(importedKey)) return;
      const byDigest = new Map();
      const obtain = (digest, fingerprint) => {
        const key = digest + fingerprint;
        if (!byDigest.has(key)) byDigest.set(key, { digest, fingerprint, copies: [] });
        return byDigest.get(key);
      };
      for (const key of Object.keys(localStorage)) {
        if (!key.startsWith(namespace)) continue;
        const parts = key.slice(namespace.length).split(":");
        if (/^[0-9a-f]{128}$/.test(parts[0])) {
          const decision = readDecision(parts[0]);
          if (decision?.fingerprint) obtain(parts[0], decision.fingerprint).decision = decision;
        } else if (parts[0] === "copies" && /^[0-9a-f]{128}$/.test(parts[1]) && parts[2]) {
          const fingerprint = localStorage.getItem(key);
          if (fingerprint) obtain(parts[1], fingerprint).copies.push(parts[2]);
        }
      }
      const entries = Array.from(byDigest.values());
      for (let offset = 0; offset < entries.length; offset += 50) {
        const response = await fetch(review.dataset.importUrl, {
          method: "POST",
          credentials: "same-origin",
          headers: { Accept: "text/html", "X-CSRF-Token": review.dataset.importCsrf },
          body: new URLSearchParams({ reviews: JSON.stringify(entries.slice(offset, offset + 50)) })
        });
        if (!response.ok || response.redirected) return;
      }
      localStorage.setItem(importedKey, "1");
    } catch {
      // Local review decisions remain available if the import cannot finish.
    }
  }

  function refreshCopyReviews(comparison, digest, fingerprint) {
    const progress = copyProgress(comparison, digest, fingerprint);
    const row = comparison.closest("[data-review-digest]");
    const linked = comparison.dataset.linkComplete ||
      (row?.dataset.fingerprint === fingerprint ? row.dataset.linkComplete : null);
    comparison.querySelector("[data-copy-acknowledgment-count]").textContent = linked === "true"
      ? "All copies linked" : `${progress.acknowledged} of ${progress.total} copies acknowledged`;
    for (const card of comparison.querySelectorAll('[data-copy-id][data-warning-state=""]')) {
      const acknowledged = progress.browserCopies.has(card.dataset.copyId);
      card.querySelector("[data-copy-warning-status]").textContent =
        acknowledged ? "Copy acknowledged" : "No Manyfold warning";
      const acknowledge = card.querySelector('[data-copy-warning-action="acknowledge"]');
      const reopen = card.querySelector('[data-copy-warning-action="reopen"]');
      if (acknowledge) acknowledge.hidden = acknowledged;
      if (reopen) reopen.hidden = !acknowledged;
    }
  }

  function updateQueueRow(row) {
    const comparison = row.querySelector("[data-comparison]");
    const decision = reviewDecision(comparison || row, row.dataset.reviewDigest);
    const fingerprint = comparison?.dataset.fingerprint || row.dataset.fingerprint;
    const progress = copyProgress(comparison || row, row.dataset.reviewDigest, fingerprint);
    const acknowledgmentLabel = progress.total > 1 && progress.acknowledged === progress.total ? "All copies acknowledged" : "";
    if (comparison && row.dataset.fingerprint !== fingerprint) {
      row.dataset.fingerprint = fingerprint;
      row.dataset.linkComplete = "false";
    }
    if (comparison) {
      row.dataset.reviewLabel = comparison.dataset.reviewLabel;
      if (comparison.dataset.linkComplete !== undefined) row.dataset.linkComplete = comparison.dataset.linkComplete;
    }
    const serverLabel = row.dataset.linkComplete === "true" ? "All copies linked"
      : row.dataset.reviewLabel || acknowledgmentLabel;
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
        url.searchParams.set("after", queue.lastElementChild.dataset.queueCursor);
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
        if (!batch || (batch.dataset.nextAfter && batch.dataset.nextAfter === nextAfter)) {
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
    const status = panel?.querySelector("[data-decision-status]");
    const clear = panel?.querySelector("[data-clear-decision]");

    function refresh() {
      refreshCopyReviews(comparison, digest, fingerprint);
      if (!panel) return;
      const decision = reviewDecision(comparison, digest);
      clear.hidden = !decision;

      const label = decision?.fingerprint === fingerprint
        ? { keep: "Keeping all copies.", reviewed: "Marked reviewed.", later: "Marked for later review." }[decision.type]
        : decision ? "The indexed copies changed. Review this group again." : "";
      status.textContent = label || "";
      status.hidden = !label;
    }

    for (const preview of comparison.querySelectorAll("[data-preview]")) {
      preview.addEventListener("toggle", () => {
        const template = preview.querySelector("template");
        if (!preview.open || !template) return;
        const frame = template.content.firstElementChild.cloneNode(true);
        frame.src = frame.dataset.previewUrl;
        template.replaceWith(frame);
      });
    }

    const plan = comparison.querySelector("[data-link-plan]");
    const targets = Array.from(plan?.querySelectorAll('input[name="targets[]"]') || []);
    if (targets.length) {
      const apply = plan.querySelector('button[name="confirm"]');
      const updatePlan = () => { apply.disabled = !targets.some((target) => target.checked); };
      plan.addEventListener("change", updatePlan);
      updatePlan();
    }

    refreshers.set(comparison, refresh);
    refresh();
  }

  async function loadComparison(row, destination, { form, submitter, scrollToResult = false } = {}) {
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
      if (method === "POST") await reviewImport;
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
        (comparison.querySelector("[data-action-result]") || comparison).focus({ preventScroll: !scrollToResult });
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

  const reviewImport = importBrowserReviews();
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
    loadComparison(row, form.action, { form, submitter: event.submitter,
      scrollToResult: form.hasAttribute("data-scroll-to-result") });
  });

  review.addEventListener("click", (event) => {
    const link = event.target.closest("[data-inline-link]");
    const row = link?.closest("[data-review-digest]");
    if (!row || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    loadComparison(row, link.href, { scrollToResult: link.hasAttribute("data-scroll-to-pair") });
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
