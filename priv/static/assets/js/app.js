let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");

// Fun thank-you toast when a user up-votes an answer. The server pushes a
// "vote_thanks" event, which LiveView re-dispatches on window as phx:vote_thanks.
const VOTE_THANKS = [
  ["🎉", "You're a legend! Thanks!"],
  ["🙌", "Knowledge leveled up!"],
  ["🚀", "Answer boosted!"],
  ["🦸", "You made this better!"],
  ["✨", "High five! Much appreciated."],
  ["🎲", "Thanks, you rule!"],
  ["🌟", "Gold star for you!"],
];
function showToast(emoji, msg) {
  document.querySelectorAll(".vote-toast").forEach((t) => t.remove());
  const toast = document.createElement("div");
  toast.className = "vote-toast";
  const e = document.createElement("span");
  e.className = "vote-toast__emoji";
  e.textContent = emoji;
  const t = document.createElement("span");
  t.textContent = msg;
  toast.appendChild(e);
  toast.appendChild(t);
  document.body.appendChild(toast);
  setTimeout(() => toast.remove(), 2700);
}
function showVoteThanks(e) {
  // Server sends {emoji, msg} when a persona voice has its own in-character
  // thank-you; empty payload means use the generic pool.
  const d = (e && e.detail) || {};
  if (d.emoji && d.msg) {
    showToast(d.emoji, d.msg);
    return;
  }
  const [emoji, msg] = VOTE_THANKS[Math.floor(Math.random() * VOTE_THANKS.length)];
  showToast(emoji, msg);
}
window.addEventListener("phx:vote_thanks", showVoteThanks);

// Make open <details class="card-menu"> dropdowns behave like a modal: a click
// anywhere outside the open menu closes it and is swallowed (it does NOT also
// activate whatever is underneath), so the next click interacts normally.
//
// A full-screen backdrop element can't work here because the menu lives inside
// .chat-messages (z-index:1), a stacking context the popup can't escape — a
// body-level backdrop would always paint over it. Instead we swallow the
// outside click directly in the capture phase, before it reaches its target or
// LiveView's delegated handler.
(function () {
  let owner = null;

  function insideOpenMenu(target) {
    if (!owner) return false;
    const pop = owner.querySelector(".card-menu__pop");
    const sum = owner.querySelector("summary");
    return (pop && pop.contains(target)) || (sum && sum.contains(target));
  }

  function swallowOutside(e) {
    if (!owner || insideOpenMenu(e.target)) return;
    e.preventDefault();
    e.stopPropagation();
    if (e.stopImmediatePropagation) e.stopImmediatePropagation();
    owner.open = false; // fires toggle -> owner = null
  }
  // Capture on window: runs before the target and before LiveView's listeners.
  window.addEventListener("click", swallowOutside, true);

  // toggle doesn't bubble; capture phase still reaches a document listener.
  document.addEventListener(
    "toggle",
    (e) => {
      const det = e.target;
      if (!(det instanceof HTMLDetailsElement) || !det.classList.contains("card-menu")) {
        return;
      }
      if (det.open) {
        document.querySelectorAll("details.card-menu[open]").forEach((d) => {
          if (d !== det) d.open = false;
        });
        owner = det;
      } else if (owner === det) {
        owner = null;
      }
    },
    true
  );
})();

let Hooks = {};
// Persists the selected game-list view to localStorage when the server
// pushes "save_view". Restored on connect via the LiveSocket params above.
Hooks.ViewPref = {
  mounted() {
    this.handleEvent("save_view", ({view}) => {
      localStorage.setItem("rm:gamelist:view", view);
    });
    // Remember how many rows were loaded so the list can be restored to the
    // same depth (and scroll offset) when the user comes back to it.
    this.handleEvent("save_count", ({count}) => {
      localStorage.setItem("rm:gamelist:count", count);
    });
    // Search/filter/view changes reset the list, so the saved spot is stale.
    this.handleEvent("reset_list_pos", () => {
      localStorage.removeItem("rm:gamelist:count");
      localStorage.removeItem("rm:gamelist:scroll");
    });
  }
};
Hooks.FlashAutoHide = {
  mounted() {
    let duration = parseInt(this.el.dataset.flashDuration) || 4000;
    this._hide = () => {
      this.el.style.transition = "opacity 300ms ease-out";
      this.el.style.opacity = "0";
      setTimeout(() => { this.el.remove(); }, 300);
    };
    this._timer = setTimeout(this._hide, duration);
  },
  updated() {
    clearTimeout(this._timer);
    this.el.style.opacity = "1";
    let duration = parseInt(this.el.dataset.flashDuration) || 4000;
    this._timer = setTimeout(this._hide, duration);
  },
  destroyed() {
    clearTimeout(this._timer);
  }
};

Hooks.ExternalLink = {
  mounted() {
    this.el.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      window.open(this.el.href, "_blank", "noopener");
    });
  }
};

Hooks.ChatScroll = {
  mounted() {
    document.documentElement.style.overflow = "hidden";
    document.body.style.overflow = "hidden";
    // Don't auto-scroll on page load — leave the view at the top. Scrolling only
    // happens on later updates (a new answer arriving) and the scroll_bottom event.
    this.answerCount = this.countAnswers();
    this.handleEvent("scroll_bottom", () => this.scrollToBottom());
  },
  updated() {
    // updated() fires on every LiveView patch — voting, toggling the sidebar,
    // etc. — not just when a new answer arrives. Only scroll when the number of
    // assistant messages actually grew, otherwise unrelated interactions yank
    // the page around.
    const count = this.countAnswers();
    if (count > this.answerCount) {
      this.scrollToLatestAnswer();
    }
    this.answerCount = count;
  },
  destroyed() {
    document.documentElement.style.overflow = "";
    document.body.style.overflow = "";
  },
  countAnswers() {
    return this.el.querySelectorAll(".chat-msg:not(.chat-msg-user)").length;
  },
  scrollToLatestAnswer() {
    const el = this.el;
    requestAnimationFrame(() => {
      // Find the last assistant message and scroll it to the top of the viewport
      const messages = el.querySelectorAll(".chat-msg:not(.chat-msg-user)");
      const last = messages[messages.length - 1];
      if (last) {
        last.scrollIntoView({ behavior: "smooth", block: "start" });
      }
    });
  },
  scrollToBottom() {
    const el = this.el;
    requestAnimationFrame(() => {
      el.scrollTop = el.scrollHeight;
    });
  }
};

// On touch devices autofocus pops the keyboard and scrolls the page to the
// input, so pages appear to load "scrolled down" — desktop only.
const coarsePointer = window.matchMedia("(pointer: coarse)").matches;

Hooks.FocusInput = {
  mounted() {
    if (coarsePointer) return;
    requestAnimationFrame(() => this.el.focus({ preventScroll: true }));
  }
};

// Static `autofocus` attributes (login form, game search) fire during parse,
// before any hook runs. This script is deferred, so undo them right here.
if (coarsePointer) {
  const el = document.activeElement;
  if (el && el.matches("input, textarea, select")) el.blur();
  window.scrollTo(0, 0);
}

Hooks.KeyboardSubmit = {
  mounted() {
    this._handler = (e) => {
      if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
        e.preventDefault();
        this.el.dispatchEvent(new Event("submit", { bubbles: true }));
      }
    };
    this.el.addEventListener("keydown", this._handler);
  },
  destroyed() {
    this.el.removeEventListener("keydown", this._handler);
  }
};

Hooks.Refocus = {
  mounted() {
    // Restore saved search from localStorage
    const saved = localStorage.getItem("game-search") || "";
    this.el.value = saved;
    this.pushEvent("restore_search", { value: saved });
    // preventScroll: .main-content is now a scroll container; a plain focus()
    // scrolls it to the input, jolting the controls down after first paint.
    if (!coarsePointer) this.el.focus({ preventScroll: true });
    // Save on each input change
    this._saveHandler = () => {
      localStorage.setItem("game-search", this.el.value);
    };
    this.el.addEventListener("input", this._saveHandler);
    this.handleEvent("refocus", () => {
      this.el.value = "";
      localStorage.removeItem("game-search");
      requestAnimationFrame(() => this.el.focus());
    });
    this.handleEvent("clear_and_refocus", () => {
      this.el.value = "";
      localStorage.removeItem("game-search");
      requestAnimationFrame(() => this.el.focus());
    });
  },
  destroyed() {
    this.el.removeEventListener("input", this._saveHandler);
  }
};

Hooks.GameListScroll = {
  mounted() {
    this.handleEvent("scroll_to_game", ({idx}) => {
      const card = document.getElementById("game-card-" + idx);
      if (card) {
        card.scrollIntoView({behavior: "smooth", block: "nearest"});
      }
    });

    // Restore the saved spot: ask the server to load back to the same row
    // depth, then land on the saved scroll offset once those rows render.
    const savedCount = parseInt(localStorage.getItem("rm:gamelist:count")) || 0;
    const savedScroll = parseInt(localStorage.getItem("rm:gamelist:scroll")) || 0;
    if (savedCount > 20) {
      this.pushEvent("restore_list_pos", {count: savedCount}, () => {
        requestAnimationFrame(() => window.scrollTo(0, savedScroll));
      });
    } else if (savedScroll > 0) {
      requestAnimationFrame(() => window.scrollTo(0, savedScroll));
    }

    // Persist scroll offset (debounced) so a return visit lands here.
    this._scrollHandler = () => {
      clearTimeout(this._scrollTimer);
      this._scrollTimer = setTimeout(() => {
        localStorage.setItem("rm:gamelist:scroll", window.scrollY);
      }, 150);
    };
    window.addEventListener("scroll", this._scrollHandler, {passive: true});

    this._keyHandler = (e) => {
      // Escape in search input: clear and refocus
      if (e.key === "Escape") {
        const searchInput = document.getElementById("game-search");
        if (searchInput && document.activeElement === searchInput) {
          searchInput.value = "";
          searchInput.focus();
          this.pushEvent("clear_search", {});
          e.preventDefault();
          return;
        }
      }

      // Down arrow from search input: select first game
      if (e.key === "ArrowDown") {
        const searchInput = document.getElementById("game-search");
        if (searchInput && document.activeElement === searchInput) {
          searchInput.blur();
          this.pushEvent("key_nav", {key: "ArrowDown"});
          e.preventDefault();
          return;
        }
      }

      // Up arrow on first game: refocus search with text selected
      if (e.key === "ArrowUp") {
        const firstCard = document.getElementById("game-card-0");
        if (firstCard && firstCard.style.outline) {
          const searchInput = document.getElementById("game-search");
          if (searchInput) {
            searchInput.focus();
            searchInput.select();
            this.pushEvent("key_nav", {key: "unselect"});
            e.preventDefault();
            return;
          }
        }
      }

      // Don't intercept when typing in an input
      if (e.target.tagName === "INPUT" || e.target.tagName === "TEXTAREA" || e.target.isContentEditable) {
        return;
      }

      const keys = ["ArrowDown", "ArrowUp", "Enter", "e", "E"];
      if (keys.includes(e.key)) {
        e.preventDefault();
        this.pushEvent("key_nav", {key: e.key});
      }
    };
    window.addEventListener("keydown", this._keyHandler);
  },
  destroyed() {
    window.removeEventListener("keydown", this._keyHandler);
    window.removeEventListener("scroll", this._scrollHandler);
    clearTimeout(this._scrollTimer);
  }
};

Hooks.ScrollToMessage = {
  mounted() {
    this.el.addEventListener("click", () => {
      const targetId = this.el.getAttribute("data-target");
      const target = document.getElementById(targetId);
      if (target) {
        target.scrollIntoView({ behavior: "smooth", block: "start" });
        // Brief highlight
        target.style.transition = "background 0.3s";
        target.style.background = "var(--bg-subtle)";
        setTimeout(() => { target.style.background = ""; }, 1500);
      }
    });
  }
};

Hooks.ShareCard = {
  // Renders the Q&A on a canvas and downloads it as a PNG — a card you can
  // drop straight into the group chat. All client-side: data-share-* attrs
  // carry the (plain text) content; colors come from the current theme vars.
  mounted() {
    this.el.addEventListener("click", () => this.download());
  },
  cssVar(name, fallback) {
    const v = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
    return v || fallback;
  },
  wrap(ctx, text, maxWidth) {
    const words = (text || "").split(/\s+/);
    const lines = [];
    let line = "";
    for (const w of words) {
      const probe = line ? line + " " + w : w;
      if (ctx.measureText(probe).width > maxWidth && line) {
        lines.push(line);
        line = w;
      } else {
        line = probe;
      }
    }
    if (line) lines.push(line);
    return lines;
  },
  download() {
    const d = this.el.dataset;
    const W = 1000;
    const pad = 56;
    const canvas = document.createElement("canvas");
    const ctx = canvas.getContext("2d");

    const bg = this.cssVar("--bg-surface", "#ffffff");
    const text = this.cssVar("--text", "#1a1a1a");
    const muted = this.cssVar("--text-muted", "#777777");
    const accent = this.cssVar("--accent", "#3b6ea5");

    // Measure pass: wrap at final fonts to compute the height.
    ctx.font = "600 30px system-ui, sans-serif";
    const qLines = this.wrap(ctx, d.shareQuestion, W - pad * 2);
    ctx.font = "400 26px system-ui, sans-serif";
    const aLines = this.wrap(ctx, d.shareAnswer, W - pad * 2).slice(0, 24);

    const qH = qLines.length * 40;
    const aH = aLines.length * 36;
    const H = pad + 34 + 24 + qH + 20 + aH + 28 + 60 + pad / 2;

    canvas.width = W;
    canvas.height = H;

    ctx.fillStyle = bg;
    ctx.fillRect(0, 0, W, H);
    ctx.fillStyle = accent;
    ctx.fillRect(0, 0, W, 10);

    let y = pad;
    ctx.fillStyle = accent;
    ctx.font = "700 22px system-ui, sans-serif";
    ctx.fillText((d.shareGame || "").toUpperCase(), pad, y);
    y += 24 + 34;

    ctx.fillStyle = text;
    ctx.font = "600 30px system-ui, sans-serif";
    for (const line of qLines) {
      ctx.fillText(line, pad, y);
      y += 40;
    }
    y += 20;

    ctx.fillStyle = text;
    ctx.font = "400 26px system-ui, sans-serif";
    for (const line of aLines) {
      ctx.fillText(line, pad, y);
      y += 36;
    }
    y += 28;

    ctx.fillStyle = muted;
    ctx.font = "500 20px system-ui, sans-serif";
    const cite = d.sharePage ? `📖 Rulebook p.${d.sharePage} · ` : "";
    ctx.fillText(
      `${cite}RuleMaven — AI-answered, rulebook-cited. Double-check important rulings.`,
      pad,
      y
    );

    const a = document.createElement("a");
    const slug = (d.shareGame || "answer").toLowerCase().replace(/[^a-z0-9]+/g, "-");
    a.download = `rulemaven-${slug}.png`;
    a.href = canvas.toDataURL("image/png");
    a.click();
  }
};

Hooks.ClipboardCopy = {
  mounted() {
    this.el.addEventListener("click", async () => {
      const text = this.el.getAttribute("data-clipboard-text");
      if (!text) return;
      const ok = await this.copy(text);
      this.feedback(ok);
    });
  },
  async copy(text) {
    try {
      if (navigator.clipboard && window.isSecureContext) {
        await navigator.clipboard.writeText(text);
        return true;
      }
    } catch (e) {
      /* fall through to execCommand */
    }
    // Fallback for older browsers / non-HTTPS
    try {
      const ta = document.createElement("textarea");
      ta.value = text;
      ta.style.position = "fixed";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.select();
      const ok = document.execCommand("copy");
      document.body.removeChild(ta);
      return ok;
    } catch (e) {
      return false;
    }
  },
  feedback(ok) {
    const orig = this.el.innerHTML;
    this.el.classList.add(ok ? "card-menu__item--ok" : "card-menu__item--err");
    this.el.innerHTML = ok ? "✓ Copied!" : "✕ Copy failed";
    if (window.showToast) showToast(ok ? "📋" : "⚠️", ok ? "Copied to clipboard!" : "Couldn't copy");
    setTimeout(() => {
      this.el.innerHTML = orig;
      this.el.classList.remove("card-menu__item--ok", "card-menu__item--err");
    }, 1500);
  }
};

// Voice dictation for the ask box. Click to speak; the transcript fills the
// target input and (on a final result) submits the form hands-free. Uses the
// browser Web Speech API; the button hides itself where it's unsupported.
Hooks.VoiceDictation = {
  mounted() {
    const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
    if (!SR) {
      this.el.style.display = "none";
      return;
    }

    const targetId = this.el.getAttribute("data-target");
    const autoSubmit = this.el.getAttribute("data-autosubmit") === "true";
    const idleHTML = this.el.innerHTML;

    this.listening = false;
    this.rec = new SR();
    this.rec.lang = navigator.language || "en-US";
    this.rec.interimResults = true;
    this.rec.continuous = false;

    const input = () => document.getElementById(targetId);

    const stop = () => {
      this.listening = false;
      this.el.innerHTML = idleHTML;
      this.el.style.color = "var(--text-muted)";
    };

    this.rec.onresult = (e) => {
      const transcript = Array.from(e.results)
        .map((r) => r[0].transcript)
        .join("")
        .trim();
      const el = input();
      if (el) {
        el.value = transcript;
        el.dispatchEvent(new Event("input", { bubbles: true }));
      }
      if (e.results[e.results.length - 1].isFinal && autoSubmit && transcript !== "") {
        const form = el && el.closest("form");
        if (form) form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
      }
    };

    this.rec.onerror = stop;
    this.rec.onend = stop;

    this._click = () => {
      if (this.listening) {
        this.rec.stop();
        stop();
        return;
      }
      const el = input();
      if (el && el.disabled) return;
      try {
        this.rec.start();
        this.listening = true;
        this.el.innerHTML = "🎙️";
        this.el.style.color = "var(--accent)";
        if (el) el.focus();
      } catch (_e) {
        stop();
      }
    };

    this.el.addEventListener("click", this._click);
  },
  destroyed() {
    if (this.rec) {
      try { this.rec.abort(); } catch (_e) {}
    }
    if (this._click) this.el.removeEventListener("click", this._click);
  }
};

// Persists setup-checklist checked items per-browser (per game) in localStorage.
// On connect, restores the saved set to the server; thereafter the server pushes
// "save_checklist" on every toggle/clear so storage stays in sync.
Hooks.ChecklistStore = {
  key() {
    return "rm:checklist:" + this.el.dataset.gameId;
  },
  mounted() {
    let saved = [];
    try {
      saved = JSON.parse(localStorage.getItem(this.key()) || "[]");
    } catch (_e) {
      saved = [];
    }
    if (Array.isArray(saved) && saved.length > 0) {
      this.pushEvent("checklist_restore", { keys: saved });
    }
    this.handleEvent("save_checklist", ({ game_id, keys }) => {
      // Ignore pushes for a different game's checklist.
      if (String(game_id) !== String(this.el.dataset.gameId)) return;
      if (keys && keys.length > 0) {
        localStorage.setItem(this.key(), JSON.stringify(keys));
      } else {
        localStorage.removeItem(this.key());
      }
    });
  }
};

// Overview nudge: one-click opt-in to the game's own palette. Applies the
// light/dark game variant matching the viewer's CURRENT look (sampled from the
// live background luminance, so it fits whatever base theme is active), exactly
// like the header theme picker (localStorage themeGameMatch + data-theme).
// Shows only while no game variant is active — it hides when one is applied and
// reappears if the picker is switched back to Off, driven by the shared
// `rm:gametheme` event the root layout dispatches.
Hooks.GameThemeHint = {
  isGame(v) {
    return v === "game-light" || v === "game-dark";
  },
  sync(match) {
    this.el.hidden = this.isGame(match);
  },
  mounted() {
    var self = this;
    this.sync(localStorage.getItem("themeGameMatch"));
    this._onMatch = function(e) {
      self.sync(e && e.detail ? e.detail.match : localStorage.getItem("themeGameMatch"));
    };
    window.addEventListener("rm:gametheme", this._onMatch);
    this.el.addEventListener("click", function() {
      var variant = "game-light";
      try {
        var bg = getComputedStyle(document.body).backgroundColor;
        var m = bg.match(/\d+/g);
        if (m && m.length >= 3) {
          var lum = 0.299 * (+m[0]) + 0.587 * (+m[1]) + 0.114 * (+m[2]);
          if (lum < 128) variant = "game-dark";
        }
      } catch (_e) {}
      localStorage.setItem("themeGameMatch", variant);
      document.documentElement.setAttribute("data-theme", variant);
      var sel = document.getElementById("theme-select");
      if (sel) sel.value = variant;
      window.dispatchEvent(new CustomEvent("rm:gametheme", { detail: { match: variant } }));
    });
  },
  destroyed() {
    if (this._onMatch) window.removeEventListener("rm:gametheme", this._onMatch);
  }
};

// Prepare-page pipeline: each step with a result gets a collapsible body
// (collapsed by default). The set of expanded step ids persists per game in
// localStorage and is re-applied on every LiveView patch, so the frequent
// job-event re-renders never reset what the admin has open. Toggling is purely
// client-side — no server round-trip. "Expand all" flips between all/none.
Hooks.PrepareCollapse = {
  key() {
    return "rm:prepare_open:" + this.el.dataset.game;
  },
  load() {
    try {
      let v = JSON.parse(localStorage.getItem(this.key()) || "[]");
      return new Set(Array.isArray(v) ? v.map(String) : []);
    } catch (_e) {
      return new Set();
    }
  },
  save() {
    localStorage.setItem(this.key(), JSON.stringify([...this.expanded]));
  },
  stepIds() {
    return [...this.el.querySelectorAll("[data-prepare-step]")].map(
      (r) => r.dataset.prepareStep
    );
  },
  apply() {
    this.el.querySelectorAll("[data-prepare-step]").forEach((row) => {
      if (this.expanded.has(row.dataset.prepareStep)) {
        row.setAttribute("data-open", "");
      } else {
        row.removeAttribute("data-open");
      }
    });
    let btn = this.el.querySelector("[data-prepare-all]");
    if (btn) {
      let ids = this.stepIds();
      let allOpen = ids.length > 0 && ids.every((id) => this.expanded.has(id));
      btn.textContent = allOpen ? "Collapse all" : "Expand all";
      btn.dataset.prepareAll = allOpen ? "collapse" : "expand";
    }
  },
  mounted() {
    this.expanded = this.load();
    // Forget saved ids whose step no longer has a result to show.
    let live = new Set(this.stepIds());
    this.expanded.forEach((id) => {
      if (!live.has(id)) this.expanded.delete(id);
    });
    // Fully-prepared game (server flags it): nothing left to act on, so land
    // collapsed instead of restoring whatever was open last visit. In-memory
    // only — expanding (which saves) works normally from here.
    if ("allDone" in this.el.dataset) this.expanded = new Set();
    // Auto-expand the next actionable step (server flags it). In-memory only —
    // not saved — so the user's stored preferences stay theirs; collapsing it
    // works normally, and the next visit expands whatever is next by then.
    let next = this.el.querySelector("[data-prepare-next]");
    if (next) this.expanded.add(next.dataset.prepareStep);
    this.el.addEventListener("click", (e) => {
      let allBtn = e.target.closest("[data-prepare-all]");
      if (allBtn) {
        let ids = this.stepIds();
        let allOpen = ids.length > 0 && ids.every((id) => this.expanded.has(id));
        this.expanded = allOpen ? new Set() : new Set(ids);
        this.save();
        this.apply();
        return;
      }
      // Don't toggle when the click landed on an action link in the header.
      if (e.target.closest("a")) return;
      let head = e.target.closest("[data-prepare-head]");
      if (!head) return;
      let row = head.closest("[data-prepare-step]");
      if (!row) return;
      let id = row.dataset.prepareStep;
      if (this.expanded.has(id)) this.expanded.delete(id);
      else this.expanded.add(id);
      this.save();
      this.apply();
    });
    this.apply();
  },
  updated() {
    this.apply();
  }
};

Hooks.VoiceDefault = {
  key: "rm:default_voice",
  mounted() {
    let saved = "";
    try {
      saved = localStorage.getItem(this.key) || "";
    } catch (_e) {
      saved = "";
    }
    if (saved) {
      this.pushEvent("default_voice_restore", { voice: saved });
    }
    this.handleEvent("save_default_voice", ({ voice }) => {
      if (voice && voice !== "neutral") {
        localStorage.setItem(this.key, voice);
      } else {
        localStorage.removeItem(this.key);
      }
    });
  }
};

// Filters persona cards in the picker modal by label/description text. Purely
// client-side so typing never round-trips; the input is phx-update="ignore".
Hooks.PersonaFilter = {
  mounted() {
    const input = this.el.querySelector("[data-persona-filter-input]");
    if (!input) return;
    const apply = () => {
      const q = input.value.trim().toLowerCase();
      this.el.querySelectorAll(".persona-card").forEach((card) => {
        const hit = !q || (card.dataset.search || "").includes(q);
        card.style.display = hit ? "" : "none";
      });
      // Hide a section heading when every card under it (up to the next
      // heading) is filtered out.
      this.el.querySelectorAll(".persona-modal__section").forEach((sec) => {
        let anyVisible = false;
        let n = sec.nextElementSibling;
        while (n && !n.classList.contains("persona-modal__section")) {
          if (n.classList.contains("persona-card") && n.style.display !== "none") {
            anyVisible = true;
          }
          n = n.nextElementSibling;
        }
        sec.style.display = anyVisible ? "" : "none";
      });
    };
    input.addEventListener("input", apply);
    // Don't autofocus on touch — it pops the keyboard (see mobile conventions).
    if (!window.matchMedia("(pointer: coarse)").matches) input.focus();
  }
};

Hooks.TurnTimer = {
  // Fully client-side turn timer: no server roundtrips, survives LiveView
  // patches because all state lives on the hook. data-seconds holds the
  // per-game suggested pace; preset buttons swap the duration.
  mounted() {
    this.duration = parseInt(this.el.dataset.seconds || "60", 10);
    this.remaining = this.duration;
    this.interval = null;
    this.display = this.el.querySelector("[data-timer-display]");
    this.render();

    this.el.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-timer-action]");
      if (!btn) return;
      const action = btn.dataset.timerAction;
      if (action === "startpause") this.startPause(btn);
      if (action === "reset") this.reset();
      if (action === "preset") {
        this.duration = parseInt(btn.dataset.seconds, 10);
        this.reset();
        this.el.querySelectorAll("[data-timer-action='preset']").forEach((b) => {
          b.style.borderColor = b === btn ? "var(--accent)" : "var(--border)";
          b.style.color = b === btn ? "var(--accent)" : "var(--text-muted)";
        });
      }
    });
  },
  destroyed() {
    if (this.interval) clearInterval(this.interval);
  },
  startPause(btn) {
    if (this.interval) {
      clearInterval(this.interval);
      this.interval = null;
      btn.textContent = "▶ Start";
      return;
    }
    if (this.remaining <= 0) this.remaining = this.duration;
    btn.textContent = "⏸ Pause";
    this.interval = setInterval(() => {
      this.remaining -= 1;
      this.render();
      if (this.remaining <= 0) {
        clearInterval(this.interval);
        this.interval = null;
        btn.textContent = "▶ Start";
        this.beep();
      }
    }, 1000);
  },
  reset() {
    if (this.interval) clearInterval(this.interval);
    this.interval = null;
    this.remaining = this.duration;
    const btn = this.el.querySelector("[data-timer-action='startpause']");
    if (btn) btn.textContent = "▶ Start";
    this.render();
  },
  render() {
    if (!this.display) return;
    const m = Math.floor(Math.max(this.remaining, 0) / 60);
    const s = Math.max(this.remaining, 0) % 60;
    this.display.textContent = `${m}:${String(s).padStart(2, "0")}`;
    this.display.style.color = this.remaining <= 10 ? "var(--red, #c0392b)" : "var(--text)";
  },
  beep() {
    try {
      const ctx = new (window.AudioContext || window.webkitAudioContext)();
      const osc = ctx.createOscillator();
      const gain = ctx.createGain();
      osc.connect(gain);
      gain.connect(ctx.destination);
      osc.frequency.value = 880;
      gain.gain.setValueAtTime(0.2, ctx.currentTime);
      gain.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + 0.6);
      osc.start();
      osc.stop(ctx.currentTime + 0.6);
    } catch (_e) {
      // No audio available — the red 0:00 is signal enough.
    }
  }
};

Hooks.VoiceLoader = {
  // Real pipeline stages (broadcast by the server as the ask progresses) map
  // to progress bands. Within a band the bar eases asymptotically toward the
  // band's cap — visible motion without claiming more progress than the
  // pipeline has actually made — and a stage change jumps it to at least the
  // new band's floor. Monotonic: it never moves backwards.
  stages: {
    understanding: [5, 20], // question normalize + embed + cache checks
    searching: [20, 35], // rulebook chunk retrieval
    answering: [35, 88], // the answer LLM call (longest wait)
    checking: [88, 97], // grounding check / citations / verdict
    voicing: [88, 97] // persona restyle of a finished answer
  },
  band() {
    return this.stages[this.el.dataset.stage] || this.stages.understanding;
  },
  mounted() {
    let phrases;
    try {
      phrases = JSON.parse(this.el.dataset.phrases || "[]");
    } catch (_e) {
      phrases = [];
    }
    if (!phrases.length) phrases = ["Reticulating splines…"];

    const phraseEl = this.el.querySelector(".voice-loader__phrase");
    const fillEl = this.el.querySelector(".voice-loader__fill");
    let last = -1;
    this._pct = this.band()[0];

    const pickPhrase = () => {
      let i = Math.floor(Math.random() * phrases.length);
      if (phrases.length > 1 && i === last) i = (i + 1) % phrases.length;
      last = i;
      if (phraseEl) phraseEl.textContent = phrases[i];
      // Longer phrases linger longer so they can actually be read.
      const delay = Math.min(700 + phrases[i].length * 30, 2600);
      this._phraseTimer = setTimeout(pickPhrase, delay);
    };

    const stepBar = () => {
      // Ease toward the current stage's cap; parks just short of it until
      // the next stage broadcast arrives.
      const cap = this.band()[1];
      if (this._pct < cap) this._pct += (cap - this._pct) * 0.05;
      if (fillEl) fillEl.style.width = this._pct.toFixed(1) + "%";
    };

    // The element is phx-update="ignore", so watch the stage attribute
    // directly — LiveView still syncs attributes on ignored elements.
    this._stageObs = new MutationObserver(() => {
      this._pct = Math.max(this._pct, this.band()[0]);
      stepBar();
    });
    this._stageObs.observe(this.el, { attributes: true, attributeFilter: ["data-stage"] });

    pickPhrase();
    stepBar();
    this._barTimer = setInterval(stepBar, 200);
  },
  destroyed() {
    clearTimeout(this._phraseTimer);
    clearInterval(this._barTimer);
    if (this._stageObs) this._stageObs.disconnect();
  }
};

// Admin background-job panel: persist the open/closed state across refreshes.
// Restores it on connect (pushes "restore"); the toggle is server-side, so we
// mirror the resulting data-open attribute back into localStorage on update.
Hooks.JobPanel = {
  key: "rm:jobpanel_open",
  // Publish the (fixed) panel's height as a CSS var so .app-shell can reserve
  // space for it: .main-content squishes above the panel and scrolls internally,
  // instead of the whole window scrolling — docked like Chrome DevTools.
  syncPad() {
    document.documentElement.style.setProperty("--jobpanel-h", this.el.offsetHeight + "px");
  },
  mounted() {
    this.syncPad();
    this._onResize = () => this.syncPad();
    window.addEventListener("resize", this._onResize);

    let open = false;
    try {
      open = localStorage.getItem(this.key) === "1";
    } catch (_e) {
      open = false;
    }
    if (open) {
      this.pushEvent("restore", { open: true });
    }
  },
  updated() {
    this.syncPad();
    try {
      if (this.el.dataset.open === "true") {
        localStorage.setItem(this.key, "1");
      } else {
        localStorage.removeItem(this.key);
      }
    } catch (_e) {}
  },
  destroyed() {
    window.removeEventListener("resize", this._onResize);
    document.documentElement.style.removeProperty("--jobpanel-h");
  }
};

// Keyboard paging for the rulebook reader, shared by the inline source editors
// and the expanded modal. ← / h previous page, → / l next, f opens the expanded
// reader (inline only). Ignored while typing in a field so editing isn't
// hijacked. Window-level, but each instance only acts when it's the active
// reader: the modal always wins while open; otherwise the inline source under
// the mouse or holding focus.
Hooks.ReaderKeys = {
  mounted() {
    const isModal = this.el.id === "reader-modal";
    this._isModal = isModal;

    // Reset the reader's content area to the top when it opens. Keyed by source
    // id in updated() so switching source (j/k) also resets, but paging within a
    // source does not. Done from this hook (guaranteed to run) rather than a
    // server push, which wasn't reliably moving the scroll.
    if (isModal) {
      this._lastReader = this.el.dataset.readerId;
      this._scrollReaderTop();
      // Lock the page behind the reader so the wheel doesn't scroll the edit
      // form (visible through the translucent overlay) when the modal content
      // itself doesn't scroll.
      this._prevBodyOverflow = document.body.style.overflow;
      document.body.style.overflow = "hidden";
    }

    this._handler = (e) => {
      if (e.ctrlKey || e.metaKey || e.altKey) return;
      const t = e.target;
      if (t && (t.isContentEditable ||
                t.tagName === "INPUT" ||
                t.tagName === "TEXTAREA" ||
                t.tagName === "SELECT")) return;

      const id = this.el.dataset.readerId;
      const modalOpen = !!document.getElementById("reader-modal");

      if (e.key === "f") {
        e.preventDefault();
        if (isModal) {
          this.pushEvent("close_source", {});
        } else if (!modalOpen && (this._active() || this._sole())) {
          // f opens the reader for the hovered/focused source — or, when this is
          // the only source on the page, with no hover needed.
          this.pushEvent("expand_source", {id});
        }
        return;
      }

      // j / k switch the rulebook source (vim-style: h/l page, j/k source). In
      // the modal it cycles the open source; inline it cycles the Manage-tab
      // selection. Inline still needs this source to be the active one.
      if (e.key === "j" || e.key === "k") {
        const delta = e.key === "j" ? "1" : "-1";
        if (isModal) {
          e.preventDefault();
          this.pushEvent("cycle_source", {delta});
        } else if (!modalOpen && (this._active() || this._sole())) {
          e.preventDefault();
          this.pushEvent("cycle_inline_source", {delta});
        }
        return;
      }

      // Paging keys still require the source to be the active one (hover/focus or
      // the modal), so they don't hijack page scrolling from across the form.
      if (!this._active()) return;

      if (e.key === "ArrowLeft" || e.key === "h") {
        e.preventDefault();
        this.pushEvent("source_page_step", {id, delta: "-1"});
      } else if (e.key === "ArrowRight" || e.key === "l") {
        e.preventDefault();
        this.pushEvent("source_page_step", {id, delta: "1"});
      }
    };
    window.addEventListener("keydown", this._handler);
  },
  updated() {
    // Source switched (j/k) — reset to top. Page changes keep the same source id,
    // so they don't trigger a reset.
    if (this._isModal && this.el.dataset.readerId !== this._lastReader) {
      this._lastReader = this.el.dataset.readerId;
      this._scrollReaderTop();
    }
  },
  // Scroll the reader's content area to the top. Uses scrollIntoView on the top
  // child so it moves whatever element is actually scrollable, and never touches
  // the textarea's own internal scroll. Retried against late layout.
  _scrollReaderTop() {
    const go = () => {
      const sc = document.getElementById("reader-scroll");
      if (!sc) return;
      sc.scrollTop = 0;
      const first = sc.firstElementChild;
      if (first && first.scrollIntoView) {
        first.scrollIntoView({block: "start", inline: "nearest"});
      }
    };
    requestAnimationFrame(go);
    requestAnimationFrame(() => requestAnimationFrame(go));
    setTimeout(go, 90);
    setTimeout(go, 300);
  },
  // The modal owns the keys while open; otherwise the hovered/focused inline
  // source does. Stops every inline instance from paging at once.
  _active() {
    if (this.el.id === "reader-modal") return true;
    if (document.getElementById("reader-modal")) return false;
    return this.el.matches(":hover") || this.el.contains(document.activeElement);
  },
  // True when this inline source is the only one on the page — so f can open it
  // without requiring the mouse to be over it.
  _sole() {
    const inline = Array.from(document.querySelectorAll("[data-reader-id]"))
      .filter((el) => el.id !== "reader-modal");
    return inline.length === 1 && inline[0] === this.el;
  },
  destroyed() {
    window.removeEventListener("keydown", this._handler);
    if (this._isModal) document.body.style.overflow = this._prevBodyOverflow || "";
  }
};

Hooks.InfiniteScroll = {
  mounted() {
    this.observer = new IntersectionObserver(([entry]) => {
      if (entry.isIntersecting) {
        this.pushEvent("load_more", {});
      }
    });
    this.observer.observe(this.el);
  },
  destroyed() {
    this.observer.disconnect();
  }
};

// Spotlight onboarding tour. Each tour-hosting page renders one element with
// phx-hook="Tour" and data-tour-page="<id>" (plus optional space-separated
// extra ids in data-tour-also — e.g. the game page also hosts the "answer"
// tour). The server pushes "tour:start"
// with {id, steps: [{sel, title, body}]} (see RuleMavenWeb.Tours): steps
// highlight the element matching `sel`, a null `sel` renders a centered card,
// and steps whose element isn't on the page are skipped. Ends (Done, ✕, Esc)
// push "tour_done" so the tour stops auto-starting for this user.
Hooks.Tour = {
  hostsTour(id) {
    if (id === this.el.dataset.tourPage) return true;
    return (this.el.dataset.tourAlso || "").split(" ").includes(id);
  },
  mounted() {
    this.handleEvent("tour:start", ({id, steps}) => this.start(id, steps));
    // Replay requested from the user dropdown while on this page.
    this._onReplay = (e) => {
      if (this.hostsTour(e.detail.id)) {
        this.pushEvent("tour_replay", {id: e.detail.id});
      }
    };
    window.addEventListener("rm:tour:start", this._onReplay);
    // Replay requested from a page without this tour lands here via
    // localStorage (e.g. "game" tour picked on /settings → open a game).
    const pending = localStorage.getItem("rm:pending-tour");
    if (pending && this.hostsTour(pending)) {
      localStorage.removeItem("rm:pending-tour");
      this.pushEvent("tour_replay", {id: pending});
    } else if (["game", "answer"].includes(pending) && this.el.dataset.tourPage === "games") {
      showToast("👇", "Open a game to start the tour");
    } else if (this.el.dataset.tourAutostart) {
      // First visit: the server rendered data-tour-autostart. Fetch the tour
      // over a normal event round-trip — a server push_event at mount time
      // can be lost when the client retries the join, so we pull instead.
      this.pushEvent("tour_replay", {id: this.el.dataset.tourAutostart});
    }
  },
  destroyed() {
    window.removeEventListener("rm:tour:start", this._onReplay);
    this.end(false);
  },
  start(id, steps) {
    this.end(false);
    this.tourId = id;
    this.steps = steps;
    this.idx = -1;
    this.build();
    this.move(1);
  },
  build() {
    const wrap = document.createElement("div");
    wrap.className = "tour";
    wrap.innerHTML =
      '<div class="tour-spot"></div>' +
      '<div class="tour-card" role="dialog" aria-modal="true">' +
      '<button type="button" class="tour-x" aria-label="Skip tour">✕</button>' +
      '<div class="tour-title"></div>' +
      '<div class="tour-body"></div>' +
      '<div class="tour-foot">' +
      '<span class="tour-progress"></span>' +
      '<span class="tour-btns">' +
      '<button type="button" class="tour-back">Back</button>' +
      '<button type="button" class="tour-next">Next</button>' +
      "</span></div></div>";
    document.body.appendChild(wrap);
    this.ui = wrap;
    wrap.querySelector(".tour-x").addEventListener("click", () => this.end(true));
    wrap.querySelector(".tour-back").addEventListener("click", () => this.move(-1));
    wrap.querySelector(".tour-next").addEventListener("click", () => this.move(1));
    // Click on the dimmed backdrop advances, like Next.
    wrap.addEventListener("click", (e) => {
      if (e.target === wrap) this.move(1);
    });
    this._onKey = (e) => {
      if (e.key === "Escape") {
        e.stopPropagation();
        this.end(true);
      } else if (e.key === "ArrowRight" || e.key === "Enter") {
        this.move(1);
      } else if (e.key === "ArrowLeft") {
        this.move(-1);
      }
    };
    window.addEventListener("keydown", this._onKey, true);
    this._onMove = () => this.position();
    window.addEventListener("resize", this._onMove);
    window.addEventListener("scroll", this._onMove, true);
  },
  // Present on this page = highlightable now (or a centered sel:null card).
  // Requires a rendered box, not just a DOM match — controls hidden by
  // responsive CSS (e.g. #game-theme-select on mobile) must skip, or the
  // spotlight lands on nothing.
  present(step) {
    if (!step.sel) return true;
    const el = document.querySelector(step.sel);
    return !!el && el.getClientRects().length > 0;
  },
  // Advance `dir` steps, skipping steps whose target isn't on the page.
  move(dir) {
    let i = this.idx + dir;
    while (i >= 0 && i < this.steps.length && !this.present(this.steps[i])) i += dir;
    if (i < 0) return;
    if (i >= this.steps.length) {
      this.end(true);
      return;
    }
    this.idx = i;
    this.show();
  },
  show() {
    const s = this.steps[this.idx];
    this.target = s.sel ? document.querySelector(s.sel) : null;
    this.ui.querySelector(".tour-title").textContent = s.title;
    this.ui.querySelector(".tour-body").textContent = s.body;
    const presentSteps = this.steps.filter((st) => this.present(st));
    this.ui.querySelector(".tour-progress").textContent =
      presentSteps.indexOf(s) + 1 + " / " + presentSteps.length;
    const hasPrev = this.steps.slice(0, this.idx).some((st) => this.present(st));
    const hasNext = this.steps.slice(this.idx + 1).some((st) => this.present(st));
    this.ui.querySelector(".tour-back").style.visibility = hasPrev ? "visible" : "hidden";
    this.ui.querySelector(".tour-next").textContent = hasNext ? "Next" : "Done";
    if (this.target) {
      // Targets taller than the viewport (e.g. the setup checklist) center on
      // their middle when block:"center", hiding their header — align tall
      // targets to the top instead.
      const tall = this.target.getBoundingClientRect().height > window.innerHeight * 0.7;
      this.target.scrollIntoView({block: tall ? "start" : "center"});
    }
    this.position();
  },
  position() {
    if (!this.ui) return;
    const spot = this.ui.querySelector(".tour-spot");
    const card = this.ui.querySelector(".tour-card");
    const pad = 6;
    if (this.target && document.contains(this.target)) {
      const raw = this.target.getBoundingClientRect();
      const cw = Math.min(340, window.innerWidth - 24);
      card.style.width = cw + "px";
      card.style.transform = "none";
      const ch = card.offsetHeight || 160;
      // Clamp the spotlight to the viewport: targets taller than the screen
      // (e.g. the setup checklist) would spill the highlight off both edges
      // and leave the card nowhere to go. When clamping the bottom, also
      // reserve room under the spot so the card fits below it.
      const rTop = Math.max(raw.top, 12);
      let rBottom = Math.min(raw.bottom, window.innerHeight - 12);
      if (raw.bottom > window.innerHeight - 12) {
        rBottom = Math.max(rTop + 60, window.innerHeight - ch - 36);
      }
      const r = {top: rTop, bottom: rBottom, left: raw.left, width: raw.width, height: rBottom - rTop};
      spot.style.top = r.top - pad + "px";
      spot.style.left = r.left - pad + "px";
      spot.style.width = r.width + pad * 2 + "px";
      spot.style.height = r.height + pad * 2 + "px";
      // Below the target if it fits, else above; clamped into the viewport.
      let top = r.bottom + pad + 12;
      if (top + ch > window.innerHeight - 12) top = Math.max(12, r.top - pad - 12 - ch);
      card.style.top = top + "px";
      card.style.left = Math.min(Math.max(12, r.left), window.innerWidth - cw - 12) + "px";
    } else {
      // Centered card; the zero-size spot keeps the full-screen dim.
      spot.style.top = "50%";
      spot.style.left = "50%";
      spot.style.width = "0";
      spot.style.height = "0";
      card.style.width = Math.min(360, window.innerWidth - 24) + "px";
      card.style.top = "50%";
      card.style.left = "50%";
      card.style.transform = "translate(-50%, -50%)";
    }
  },
  end(notify) {
    if (this._onKey) {
      window.removeEventListener("keydown", this._onKey, true);
      this._onKey = null;
    }
    if (this._onMove) {
      window.removeEventListener("resize", this._onMove);
      window.removeEventListener("scroll", this._onMove, true);
      this._onMove = null;
    }
    if (this.ui) {
      this.ui.remove();
      this.ui = null;
    }
    if (notify && this.tourId) this.pushEvent("tour_done", {id: this.tourId});
    this.tourId = null;
  }
};

// User-dropdown "replay tour" links (data-tour-replay="<id>"). If the current
// page hosts that tour, start it in place; otherwise remember it and go home —
// the "games" tour then starts on landing, the "game" tour on the next game
// page opened (with a toast pointing the user at the list).
document.addEventListener("click", (e) => {
  const a = e.target.closest("[data-tour-replay]");
  if (!a) return;
  e.preventDefault();
  const id = a.dataset.tourReplay;
  const details = a.closest("details");
  if (details) details.removeAttribute("open");
  if (
    document.querySelector('[data-tour-page="' + id + '"], [data-tour-also~="' + id + '"]')
  ) {
    window.dispatchEvent(new CustomEvent("rm:tour:start", {detail: {id}}));
  } else {
    localStorage.setItem("rm:pending-tour", id);
    window.location.href = "/";
  }
});

let liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
  params: () => ({
    _csrf_token: csrfToken,
    // Remembered game-list view (playable/mine/all) so it survives reloads.
    list_view: localStorage.getItem("rm:gamelist:view") || "",
    // Remembered game-edit tab per game ({gameId: tab}) so a refresh reopens it.
    edit_tab: localStorage.getItem("rm:edit:tab") || "",
    // Remembered rulebook reader page per source ({gameId: {srcId: page}}).
    reader_pages: localStorage.getItem("rm:reader:pages") || "",
    // Remembered default persona voice, so the server knows it at first render
    // and never flashes the plain answer before the restore round-trips.
    default_voice: localStorage.getItem("rm:default_voice") || ""
  }),
  hooks: Hooks
});

// Merge a value into a {gameId: ...} JSON blob in localStorage. Tolerates a
// corrupt/missing blob by starting fresh.
function mergeGameBlob(key, gameId, value) {
  let blob = {};
  try {
    blob = JSON.parse(localStorage.getItem(key) || "{}") || {};
  } catch (_) {
    blob = {};
  }
  blob[gameId] = value;
  localStorage.setItem(key, JSON.stringify(blob));
}

// Persist the game-edit tab per game so a refresh reopens the last one.
window.addEventListener("phx:save_edit_tab", (e) => {
  mergeGameBlob("rm:edit:tab", e.detail.game_id, e.detail.tab);
});

// Persist the rulebook reader page per source, nested under the game id.
window.addEventListener("phx:save_reader_page", (e) => {
  let blob = {};
  try {
    blob = JSON.parse(localStorage.getItem("rm:reader:pages") || "{}") || {};
  } catch (_) {
    blob = {};
  }
  const g = blob[e.detail.game_id] || {};
  g[e.detail.source_id] = e.detail.page;
  blob[e.detail.game_id] = g;
  localStorage.setItem("rm:reader:pages", JSON.stringify(blob));
});

// Keep --header-height in sync with the real sticky-header height so fixed/
// sticky layouts (Q&A page, game-list controls) sit flush beneath it with no
// gap. CSS ships a sensible fallback; this refines it to the measured value.
function syncHeaderHeight() {
  const header = document.querySelector(".header");
  if (header) {
    document.documentElement.style.setProperty("--header-height", header.offsetHeight + "px");
  }
  // Offset the whole sticky stack (header + any sticky list controls) so
  // scrollIntoView / scroll restore land cards below it instead of clipping
  // the top row under the bar.
  const headerH = header ? header.offsetHeight : 0;
  const controls = document.querySelector(".list-controls");
  const controlsH = controls ? controls.offsetHeight : 0;
  document.documentElement.style.scrollPaddingTop = (headerH + controlsH) + "px";
}
window.addEventListener("resize", syncHeaderHeight);
window.addEventListener("phx:page-loading-stop", syncHeaderHeight);
window.addEventListener("DOMContentLoaded", syncHeaderHeight);
syncHeaderHeight();

// Track first successful WebSocket connection on the LiveView root element.
// Classes phx-connected/phx-loading/phx-error are set on [data-phx-main], not body.
let mainEl = document.querySelector("[data-phx-main]");
if (mainEl) {
  let observer = new MutationObserver(() => {
    if (mainEl.classList.contains("phx-connected")) {
      mainEl.classList.add("phx-was-connected");
      observer.disconnect();
    }
  });
  observer.observe(mainEl, {attributes: true, attributeFilter: ["class"]});
}

// Only connect the LiveSocket when there are LiveView elements on the page.
// Connecting unconditionally on every page (e.g. /login) creates a WebSocket
// whose connect_info session is captured at connect-time. When the browser
// later navigates to a page with a LiveView, the same socket is reused with
// the stale session, causing on_mount to see the wrong auth state.
//
// Match [data-phx-session] too, not just [data-phx-main]: the admin job panel
// is an independent live_render embedded in the root layout, so on dead
// (controller) pages it is the only LiveView and carries [data-phx-session]
// without [data-phx-main]. Without this it rendered statically but never
// connected, so its phx-click (expand/select) did nothing.
if (document.querySelector("[data-phx-main], [data-phx-session]")) {
  liveSocket.connect();
}

if ("serviceWorker" in navigator) {
  window.addEventListener("load", function() {
    navigator.serviceWorker.register("/sw.js").then(function(reg) {
      setInterval(function() { reg.update(); }, 60000);
    });
  });

  let refreshing = false;
  navigator.serviceWorker.addEventListener("controllerchange", function() {
    if (refreshing) return;
    refreshing = true;
    window.location.reload();
  });

  // Close all <details> dropdowns on LiveView page transition
  window.addEventListener("phx:page-loading-stop", () => {
    document.querySelectorAll("details[open]").forEach(el => el.removeAttribute("open"));
  });
  // Also close on back-forward cache restore
  window.addEventListener("pageshow", (e) => {
    if (e.persisted) {
      document.querySelectorAll("details[open]").forEach(el => el.removeAttribute("open"));
    }
  });

  // Close <details> on Escape key
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") {
      document.querySelectorAll("details[open]").forEach(el => el.removeAttribute("open"));
    }
  });

  // Close <details> on click outside
  document.addEventListener("click", (e) => {
    document.querySelectorAll("details[open]").forEach(el => {
      if (!el.contains(e.target)) {
        el.removeAttribute("open");
      }
    });
  });
}

// Hamburger drawer toggle
(function() {
  var btn = document.getElementById('hamburger-btn');
  var drawer = document.getElementById('drawer');
  var overlay = document.getElementById('drawer-overlay');
  var closeBtn = document.getElementById('drawer-close');
  if (!btn || !drawer || !overlay) return;

  function open() { drawer.classList.add('open'); overlay.classList.add('open'); }
  function close() { drawer.classList.remove('open'); overlay.classList.remove('open'); }

  btn.addEventListener('click', open);
  closeBtn.addEventListener('click', close);
  overlay.addEventListener('click', close);

  // Close on Escape
  document.addEventListener('keydown', function(e) {
    if (e.key === 'Escape' && drawer.classList.contains('open')) close();
  });
})();
